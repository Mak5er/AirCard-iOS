import Foundation
import AirliftFFI

// MARK: - Exact original-artwork restore

extension AppViewModel {
    nonisolated static func exactRestoreMissingFileError(_ error: String?) -> Bool {
        WalletSafety.classifyArtworkExportFailure(error) == .sourceMissing
    }

    /// Destructively move one current Wallet artwork file into a local snapshot.
    nonisolated private static func exactRestoreExportCurrentFile(
        pairingPath: String,
        devicePath: String,
        outputPath: String
    ) async -> (ok: Bool, error: String?) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var outError: UnsafeMutablePointer<CChar>? = nil
                let rc = pairingPath.withCString { pairC in
                    devicePath.withCString { deviceC in
                        outputPath.withCString { outputC in
                            al_exploit_export_file(
                                pairC,
                                deviceC,
                                outputC,
                                nil,
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
    }

    nonisolated private static func exactRestoreWriteDirectory(
        pairingPath: String,
        sourceDirectory: URL,
        targetDirectory: String
    ) async -> (ok: Bool, error: String?) {
        await writeWalletDirectory(
            pairingPath: pairingPath,
            sourceDirectory: sourceDirectory,
            targetDirectory: targetDirectory
        )
    }

    nonisolated private static func persistRestoreRecovery(
        snapshotDirectory: URL,
        cardId: String
    ) -> URL? {
        let root = restoreRecoveryRoot(for: cardId)
        let destination = root.appendingPathComponent("snapshot-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: snapshotDirectory, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    /// Restores the exact original artwork set, including absence of files that
    /// AirCard may have added during a custom flash.
    ///
    /// Every current candidate is first exported to a rollback snapshot. Only the
    /// verified provider-issued files from the immutable backup are then written.
    /// If rollback fails, the snapshot is retained under WalletCards/RestoreRecovery.
    func restoreOriginalArtworkExactly(for cardId: String) {
        guard hasPairingFile else {
            errorMessage = "Pair this iPhone before restoring original Wallet artwork."
            return
        }
        let validation = Self.validateOriginalArtworkBackup(for: cardId)
        guard case .valid(let manifest) = validation else {
            errorMessage = "No verified original artwork backup is available for this card. \(validation.message)"
            return
        }
        guard cardFlashPhase != .running else { return }

        cardFlashPhase = .running
        cardFlashProgress = 0
        cardFlashLog.removeAll()
        errorMessage = nil

        let pairingPath = PairingController.pairingFilePath()
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId
        let targetDirectory = "/var/mobile/Library/Passes/Cards/\(cleanId).pkpass"
        WalletCardOperationStore.shared.set(.restoring("Preparing exact restore…"), for: cleanId)

        cardFlashLog.append("Restoring exact original artwork for \(cleanId.prefix(12))…")
        cardFlashLog.append("  🔐 Verified original backup: \(manifest.files.count) file\(manifest.files.count == 1 ? "" : "s")")

        Task.detached { [weak self] in
            guard let self else { return }

            let snapshotDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("aircard_pre_restore_\(UUID().uuidString)", isDirectory: true)

            do {
                try FileManager.default.createDirectory(
                    at: snapshotDirectory,
                    withIntermediateDirectories: true
                )
            } catch {
                await MainActor.run {
                    self.cardFlashPhase = .done(ok: false)
                    self.cardFlashLog.append("❌ Could not create restore snapshot: \(error.localizedDescription)")
                    WalletCardOperationStore.shared.set(.failed("Restore preparation failed"), for: cleanId)
                    self.errorMessage = "Could not prepare the original-artwork restore."
                }
                return
            }

            var snapshotCount = 0
            var snapshotFailed = false
            var snapshotFailure: String? = nil

            await MainActor.run {
                self.cardFlashLog.append("  📦 Snapshotting current artwork before restore…")
                WalletCardOperationStore.shared.set(.restoring("1/3 Snapshotting current artwork…"), for: cleanId)
            }

            for leaf in Self.originalWalletArtworkLeaves {
                let devicePath = "\(targetDirectory)/\(leaf)"
                let outputPath = snapshotDirectory.appendingPathComponent(leaf).path
                let result = await Self.exactRestoreExportCurrentFile(
                    pairingPath: pairingPath,
                    devicePath: devicePath,
                    outputPath: outputPath
                )

                if result.ok {
                    snapshotCount += 1
                    continue
                }

                if Self.exactRestoreMissingFileError(result.error) {
                    continue
                }

                snapshotFailed = true
                snapshotFailure = result.error ?? "unknown export error"
                break
            }

            let snapshotCountForLog = snapshotCount
            await MainActor.run {
                self.cardFlashLog.append(
                    "  ✅ Current artwork snapshot: \(snapshotCountForLog) file\(snapshotCountForLog == 1 ? "" : "s")"
                )
            }

            if snapshotFailed {
                var rollbackError: String? = nil
                if snapshotCount > 0 {
                    let rollback = await Self.exactRestoreWriteDirectory(
                        pairingPath: pairingPath,
                        sourceDirectory: snapshotDirectory,
                        targetDirectory: targetDirectory
                    )
                    if !rollback.ok {
                        rollbackError = rollback.error ?? "unknown rollback error"
                    }
                }

                var recoveryURL: URL? = nil
                if rollbackError != nil, snapshotCount > 0 {
                    recoveryURL = Self.persistRestoreRecovery(
                        snapshotDirectory: snapshotDirectory,
                        cardId: cleanId
                    )
                }
                try? FileManager.default.removeItem(at: snapshotDirectory)

                let snapshotFailureForUI = snapshotFailure
                let rollbackErrorForUI = rollbackError
                let recoveryRetainedForUI = recoveryURL != nil
                let snapshotCountForUI = snapshotCount

                await MainActor.run {
                    self.cardFlashPhase = .done(ok: false)
                    self.cardFlashLog.append(
                        "  ❌ Could not snapshot current artwork: \(snapshotFailureForUI ?? "unknown error")"
                    )
                    if let rollbackErrorForUI {
                        self.cardFlashLog.append(
                            "  ❌ Snapshot rollback also failed: \(rollbackErrorForUI)"
                        )
                        if recoveryRetainedForUI {
                            self.cardFlashLog.append(
                                "  🛟 Recovery snapshot retained for manual repair"
                            )
                        }
                    } else if snapshotCountForUI > 0 {
                        self.cardFlashLog.append(
                            "  ✅ Current artwork restored after snapshot failure"
                        )
                    }
                    WalletCardOperationStore.shared.set(
                        .failed("Restore snapshot failed"),
                        for: cleanId
                    )
                    self.errorMessage =
                        "Could not safely prepare the original-artwork restore."
                    self.objectWillChange.send()
                }
                return
            }

            await MainActor.run {
                self.cardFlashLog.append("  ↩️ Writing provider-issued original artwork…")
                WalletCardOperationStore.shared.set(.restoring("2/3 Restoring verified original…"), for: cleanId)
            }

            let restore = await Self.restoreOriginalArtworkBackupFiles(
                cardId: cleanId,
                pairingPath: pairingPath,
                log: { line in
                    DispatchQueue.main.async {
                        AppViewModel.shared?.cardFlashLog.append("    " + line)
                    }
                }
            )

            guard restore.ok else {
                var rollbackError: String? = nil
                if snapshotCount > 0 {
                    let rollback = await Self.exactRestoreWriteDirectory(
                        pairingPath: pairingPath,
                        sourceDirectory: snapshotDirectory,
                        targetDirectory: targetDirectory
                    )
                    if !rollback.ok {
                        rollbackError = rollback.error ?? "unknown rollback error"
                    } else {
                        await Self.invalidateWalletCardCaches(
                            cardId: cleanId,
                            pairingPath: pairingPath
                        )
                    }
                }

                var recoveryURL: URL? = nil
                if rollbackError != nil, snapshotCount > 0 {
                    recoveryURL = Self.persistRestoreRecovery(
                        snapshotDirectory: snapshotDirectory,
                        cardId: cleanId
                    )
                }
                try? FileManager.default.removeItem(at: snapshotDirectory)

                let rollbackErrorForUI = rollbackError
                let recoveryRetainedForUI = recoveryURL != nil
                let snapshotCountForUI = snapshotCount

                await MainActor.run {
                    self.cardFlashPhase = .done(ok: false)
                    self.cardFlashLog.append(
                        "❌ Original-artwork write failed: \(restore.error ?? "unknown write error")"
                    )
                    if let rollbackErrorForUI {
                        self.cardFlashLog.append(
                            "❌ Could not restore the pre-restore artwork snapshot: \(rollbackErrorForUI)"
                        )
                        if recoveryRetainedForUI {
                            self.cardFlashLog.append(
                                "🛟 Pre-restore snapshot retained in Recovery diagnostics"
                            )
                        }
                    } else if snapshotCountForUI > 0 {
                        self.cardFlashLog.append(
                            "✅ Previous artwork restored after failed original restore"
                        )
                    }
                    WalletCardOperationStore.shared.set(
                        .failed("Original restore failed"),
                        for: cleanId
                    )
                    self.errorMessage =
                        "Could not restore the original Wallet artwork."
                    self.objectWillChange.send()
                }
                return
            }

            await MainActor.run {
                WalletCardOperationStore.shared.set(
                    .refreshing("3/3 Restoring original Wallet face…"),
                    for: cleanId
                )
                self.cardFlashLog.append(
                    "  🎨 Provider files restored; reinstating captured original FrontFace…"
                )
            }

            let frontFaceRestore =
                await Self.restoreCapturedWalletFrontFaceCache(
                    cardId: cleanId,
                    pairingPath: pairingPath
                )

            if frontFaceRestore.restored {
                await MainActor.run {
                    self.cardFlashLog.append(
                        "  ✅ Exact original Wallet FrontFace cache restored"
                    )
                }
            } else {
                await MainActor.run {
                    if let error = frontFaceRestore.error {
                        self.cardFlashLog.append(
                            "  ⚠️ Original FrontFace restore failed: \(error)"
                        )
                    } else {
                        self.cardFlashLog.append(
                            "  ℹ️ No verified original FrontFace cache is available"
                        )
                    }

                    self.cardFlashLog.append(
                        "  🧹 Falling back to Wallet cache regeneration…"
                    )
                }

                await Self.invalidateWalletCardCaches(
                    cardId: cleanId,
                    pairingPath: pairingPath
                )
            }

            try? FileManager.default.removeItem(at: snapshotDirectory)

            let finalSnapshotCount = snapshotCount

            await MainActor.run {
                self.cardFlashPhase = .done(ok: true)
                self.cardFlashProgress = 1.0
                self.cardFlashLog.append(
                    "✅ Exact original Wallet artwork restored (\(finalSnapshotCount) current → \(manifest.files.count) original). Force-close Wallet to refresh."
                )
                WalletCardOperationStore.shared.set(.ready("Original artwork restored ✅"), for: cleanId)
                self.successAlertMessage = "Original Wallet artwork restored and verified.\n\nForce-close and reopen Wallet to refresh the card. Your custom image remains saved in AirCard."
                self.showSuccessAlert = true
                self.objectWillChange.send()
            }
        }
    }
}
