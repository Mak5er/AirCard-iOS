import Foundation
import UIKit
import AirliftFFI

// MARK: - Wallet flash integration

extension AppViewModel {
    /// Flash selected Wallet card skins while preserving and verifying provider-issued
    /// artwork before the first modification. Existing immutable backups are reused.
    func flashCardsPreservingOriginalArtwork() {
        guard canFlashCards else { return }
        let selected = cards.filter { $0.isSelected && ($0.customImage != nil || $0.customImageData != nil) }
        guard !selected.isEmpty else { return }

        cardFlashPhase = .running
        cardFlashProgress = 0
        cardFlashLog.removeAll()
        errorMessage = nil

        if !vpnUp {
            cardFlashLog.append("⚠️ Notice: Loopback VPN not detected, attempting direct loopback (127.0.0.1)...")
        }

        let pairingPath = PairingController.pairingFilePath()

        Task.detached { [weak self] in
            guard let self else { return }
            let total = Double(selected.count)
            var successCount = 0

            for (i, card) in selected.enumerated() {
                let cleanId = CardItem.cleanCardId(card.id) ?? card.id
                let safeCardId = cleanId
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: "+", with: "-")

                await MainActor.run {
                    self.cardFlashLog.append("[\(i + 1)/\(selected.count)] Flashing card \(cleanId.prefix(12))…")
                    self.cardFlashLog.append("  1/3 Protect original → 2/3 Write skin → 3/3 Refresh cache")
                    self.cardFlashProgress = Double(i) / total
                    WalletCardOperationStore.shared.set(.backingUp("1/3 Verifying original backup…"), for: cleanId)
                }

                let sourceImg: UIImage? = {
                    if let data = card.customImageData, let image = UIImage(data: data) {
                        return image
                    }
                    let path = Self.cardImagePath(for: cleanId)
                    if let data = try? Data(contentsOf: path), let image = UIImage(data: data) {
                        return image
                    }
                    return card.customImage
                }()

                guard let sourceImg else {
                    await MainActor.run {
                        self.cardFlashLog.append("  ⚠️ No image for card \(cleanId.prefix(8))")
                        self.cardFlashProgress = Double(i + 1) / total
                        WalletCardOperationStore.shared.set(.failed("No custom image selected"), for: cleanId)
                    }
                    continue
                }

                let allSkins = ImageEngine.prepareAllCardSkins(from: sourceImg)
                guard !allSkins.isEmpty else {
                    await MainActor.run {
                        self.cardFlashLog.append("  ⚠️ Failed to generate card skins")
                        self.cardFlashProgress = Double(i + 1) / total
                        WalletCardOperationStore.shared.set(.failed("Skin generation failed"), for: cleanId)
                    }
                    continue
                }

                let backupPreparation = await Self.ensureOriginalArtworkBackup(
                    cardId: cleanId,
                    pairingPath: pairingPath,
                    log: { line in
                        DispatchQueue.main.async {
                            AppViewModel.shared?.cardFlashLog.append(line)
                        }
                    }
                )

                guard backupPreparation.isReady else {
                    await MainActor.run {
                        self.cardFlashLog.append("  ❌ Original artwork could not be safely preserved; this card was not modified.")
                        self.cardFlashProgress = Double(i + 1) / total
                        WalletCardOperationStore.shared.set(.failed("Original backup failed — card unchanged"), for: cleanId)
                    }
                    continue
                }

                let verifiedBackup = Self.validateOriginalArtworkBackup(for: cleanId)
                guard case .valid(let manifest) = verifiedBackup else {
                    await MainActor.run {
                        self.cardFlashLog.append("  ❌ Backup integrity check failed before write: \(verifiedBackup.message)")
                        self.cardFlashProgress = Double(i + 1) / total
                        WalletCardOperationStore.shared.set(.failed("Backup integrity check failed"), for: cleanId)
                    }
                    continue
                }

                await MainActor.run {
                    self.cardFlashLog.append("  ✅ 1/3 Original verified: \(manifest.files.count) file\(manifest.files.count == 1 ? "" : "s")")
                    WalletCardOperationStore.shared.set(.writing("2/3 Writing custom skin…"), for: cleanId)
                }

                let stageCardDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("airlift_card_\(safeCardId)_\(UUID().uuidString)")

                do {
                    try FileManager.default.createDirectory(at: stageCardDir, withIntermediateDirectories: true)
                    for (name, data) in allSkins {
                        try data.write(to: stageCardDir.appendingPathComponent(name))
                    }
                } catch {
                    await MainActor.run {
                        self.cardFlashLog.append("  ❌ Could not stage card skins: \(error.localizedDescription)")
                        self.cardFlashProgress = Double(i + 1) / total
                        WalletCardOperationStore.shared.set(.failed("Skin staging failed"), for: cleanId)
                    }
                    continue
                }

                let pkpassTarget = "/var/mobile/Library/Passes/Cards/\(cleanId).pkpass"
                await MainActor.run {
                    self.cardFlashLog.append("  ⚡ Injecting skins into \(cleanId.prefix(10)).pkpass…")
                }

                let writeResult: (ok: Bool, error: String?) = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        var outError: UnsafeMutablePointer<CChar>? = nil
                        let rc = pairingPath.withCString { pairC in
                            stageCardDir.path.withCString { sourceC in
                                pkpassTarget.withCString { targetC in
                                    al_exploit_write_dir(
                                        pairC,
                                        sourceC,
                                        targetC,
                                        { _, msg in
                                            guard let msg else { return }
                                            let line = String(cString: msg)
                                            DispatchQueue.main.async {
                                                AppViewModel.shared?.cardFlashLog.append("    " + line)
                                            }
                                        },
                                        nil,
                                        &outError
                                    )
                                }
                            }
                        }
                        let error = outError.flatMap { String(validatingUTF8: $0) }
                        if let pointer = outError { al_string_free(pointer) }
                        continuation.resume(returning: (rc == 0, error))
                    }
                }

                try? FileManager.default.removeItem(at: stageCardDir)

                guard writeResult.ok else {
                    await MainActor.run {
                        self.cardFlashLog.append("  ❌ Failed to write card skins: \(writeResult.error ?? "exploit error")")
                        self.cardFlashLog.append("  ↩️ Restoring verified original artwork after failed skin write…")
                    }

                    // A failed directory write may have partially replaced the pass even
                    // though provider originals were already restored after backup. Always
                    // roll back from the verified immutable original set here.
                    let rollback = await Self.restoreOriginalArtworkBackupFiles(
                        cardId: cleanId,
                        pairingPath: pairingPath,
                        log: { line in
                            DispatchQueue.main.async {
                                AppViewModel.shared?.cardFlashLog.append("    " + line)
                            }
                        }
                    )
                    if rollback.ok {
                        await Self.invalidateWalletCardCaches(cardId: cleanId, pairingPath: pairingPath)
                        await MainActor.run {
                            self.cardFlashLog.append("  ✅ Original artwork restored after failed custom write")
                        }
                    } else {
                        await MainActor.run {
                            self.cardFlashLog.append("  ❌ Original-artwork rollback failed: \(rollback.error ?? "unknown write error")")
                        }
                    }

                    await MainActor.run {
                        self.cardFlashProgress = Double(i + 1) / total
                        WalletCardOperationStore.shared.set(.failed("Custom write failed"), for: cleanId)
                        self.objectWillChange.send()
                    }
                    continue
                }

                await MainActor.run {
                    self.cardFlashLog.append("  ✅ 2/3 Custom skin written (\(allSkins.count) files)")
                    self.cardFlashLog.append("  🧹 3/3 Invalidating pass cache…")
                    WalletCardOperationStore.shared.set(.refreshing("3/3 Refreshing Wallet cache…"), for: cleanId)
                }

                await Self.invalidateWalletCardCaches(cardId: cleanId, pairingPath: pairingPath)

                successCount += 1
                await MainActor.run {
                    self.cardFlashLog.append("  ✅ 3/3 Pass cache invalidated")
                    self.cardFlashLog.append("  ✅ Transaction complete: original protected → skin written → cache refreshed")
                    self.cardFlashProgress = Double(i + 1) / total
                    WalletCardOperationStore.shared.set(.ready("Skin applied · original protected ✅"), for: cleanId)
                    self.objectWillChange.send()
                }
            }

            await MainActor.run {
                if successCount > 0 {
                    self.cardFlashPhase = .done(ok: true)
                    self.cardFlashProgress = 1.0
                    self.cardFlashLog.append("🎉 \(successCount)/\(selected.count) card(s) flashed! Force-close Wallet app to see changes.")
                    self.successAlertMessage = "Skins successfully applied to \(successCount) card(s)!\n\nEach modified card passed the original-backup protection step first. Force-close and reopen Wallet to see your new designs."
                    self.showSuccessAlert = true
                } else {
                    self.cardFlashPhase = .done(ok: false)
                    self.cardFlashLog.append("❌ Card flash failed. No unprotected card artwork was intentionally overwritten.")
                }
            }
        }
    }
}
