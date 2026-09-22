import SwiftUI

/// Coordinates first-scan rendered-face capture and immutable original-artwork backup.
/// Provider artwork is restored immediately after each move-based read so a long scan
/// cannot leave multiple original files absent from Wallet at the same time.
struct WalletScanBackupRootView: View {
    @EnvironmentObject var vm: AppViewModel
    @ObservedObject private var operationStore = WalletCardOperationStore.shared
    @State private var backupStartedForCards: Set<String> = []

    var body: some View {
        AirCardFeatureRootView()
            .onChange(of: operationStore.phases) { _, phases in
                for (cardId, phase) in phases {
                    let previewAttemptFinished: Bool

                    switch phase {
                    case .ready(let label):
                        previewAttemptFinished = label.contains("Artwork loaded")
                    case .failed(let label):
                        previewAttemptFinished = label.contains("Wallet preview unavailable")
                    default:
                        previewAttemptFinished = false
                    }

                    guard previewAttemptFinished else { continue }
                    let cleanId = CardItem.cleanCardId(cardId) ?? cardId

                    // A later manual Refresh Wallet Preview should refresh the canonical
                    // rendered FrontFace too, but it must never replace/recreate the
                    // immutable Originals backup in the same app session.
                    if backupStartedForCards.contains(cleanId) {
                        vm.refreshRenderedReferenceAfterPreview(for: cleanId)
                        continue
                    }

                    // Preview/restore recovery still blocks a second destructive read.
                    // An incomplete Originals directory is allowed through only when our
                    // persistent journal exists, because preserveFirstDetectedArtworkAfterScan
                    // repairs that exact in-flight file before touching FrontFace again.
                    let recoveryItems = AppViewModel.walletRecoveryItems(for: cleanId)
                    let hasBlockingRecovery = recoveryItems.contains { item in
                        if item.kind == .incompleteOriginal {
                            return !AppViewModel.hasResumableOriginalArtworkBackupJournal(for: cleanId)
                        }
                        return true
                    }
                    guard !hasBlockingRecovery else {
                        WalletCardOperationStore.shared.set(
                            .failed("Preview recovery required before original backup"),
                            for: cleanId
                        )
                        continue
                    }

                    backupStartedForCards.insert(cleanId)
                    vm.preserveFirstDetectedArtworkAfterScan(for: cleanId)
                }
            }
            .onChange(of: vm.cards.map(\.id)) { _, ids in
                let current = Set(ids.map { CardItem.cleanCardId($0) ?? $0 })
                backupStartedForCards = backupStartedForCards.intersection(current)
            }
    }
}

extension AppViewModel {
    nonisolated static func hasResumableOriginalArtworkBackupJournal(for cardId: String) -> Bool {
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId
        let url = originalArtworkBackupDirectory(for: cleanId)
            .appendingPathComponent(".backup-journal.json")
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Captures Wallet's canonical FrontFace.faceImage and then creates/verifies the
    /// authoritative immutable raw-artwork backup. The two stores have different jobs:
    ///
    /// - RenderedReferences = the final composite Wallet face used for faithful preview.
    /// - Originals = exact provider files used only by Restore Original.
    ///
    /// Any interrupted raw-artwork journal is repaired before FrontFace is captured so
    /// a previous partial read cannot become the visual reference for the next launch.
    func preserveFirstDetectedArtworkAfterScan(for cardId: String) {
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId

        guard hasPairingFile else {
            WalletCardOperationStore.shared.set(.failed("Pairing required for original backup"), for: cleanId)
            return
        }

        let pairingPath = PairingController.pairingFilePath()
        WalletCardOperationStore.shared.set(.backingUp("Reading exact Wallet FrontFace…"), for: cleanId)
        scanStatusText = "Found card: \(cleanId.prefix(12))… Reading Wallet FrontFace…"

        Task(priority: .userInitiated) { [weak self] in
            let interruptedRecovery = await Self.recoverInterruptedOriginalArtworkBackupIfNeeded(
                cardId: cleanId,
                pairingPath: pairingPath,
                log: { line in
                    DispatchQueue.main.async {
                        AppViewModel.shared?.log.append(line)
                    }
                }
            )

            guard interruptedRecovery.ok else {
                await MainActor.run {
                    guard let self else { return }
                    WalletCardOperationStore.shared.set(
                        .failed("Interrupted original backup needs recovery"),
                        for: cleanId
                    )
                    self.scanStatusText = "Found card: \(cleanId.prefix(12))… Recovery required"
                    self.errorMessage = interruptedRecovery.error
                        ?? "An interrupted original-artwork backup could not be repaired safely."
                    self.log.append(
                        "❌ Interrupted original-artwork recovery failed for \(cleanId.prefix(12))…: "
                        + (interruptedRecovery.error ?? "unknown recovery error")
                    )
                }
                return
            }

            if interruptedRecovery.recovered {
                await MainActor.run {
                    guard let self else { return }
                    self.log.append(
                        "🛟 Interrupted original-artwork file restored before FrontFace capture"
                    )
                }
            }

            let rendered = await Self.captureRenderedWalletReference(
                cardId: cleanId,
                pairingPath: pairingPath
            )

            await MainActor.run {
                guard let self else { return }
                switch rendered {
                case .captured(let manifest):
                    self.log.append(
                        "🎨 Exact Wallet FrontFace captured for \(cleanId.prefix(12))… " +
                        "from \(manifest.cacheSuffix)/\(manifest.leaf) " +
                        "(\(manifest.pixelWidth)×\(manifest.pixelHeight), \(manifest.byteCount) bytes)"
                    )
                    WalletCardOperationStore.shared.set(
                        .backingUp("Exact Wallet face captured · preserving original…"),
                        for: cleanId
                    )
                case .unavailable(let attempted, let detail):
                    var line = "ℹ️ No decodable Wallet FrontFace.faceImage found for \(cleanId.prefix(12))… after \(attempted) FrontFace candidates"
                    if let detail { line += ": \(detail)" }
                    self.log.append(line)
                    WalletCardOperationStore.shared.set(
                        .backingUp("Wallet FrontFace unavailable · preserving original…"),
                        for: cleanId
                    )
                case .unsafe(let error):
                    self.log.append(
                        "⚠️ Wallet FrontFace probe stopped: \(error). " +
                        "Immutable raw backup will continue."
                    )
                    WalletCardOperationStore.shared.set(
                        .backingUp("FrontFace probe stopped · preserving original…"),
                        for: cleanId
                    )
                }
                self.objectWillChange.send()
            }

            let existing = Self.validateOriginalArtworkBackup(for: cleanId)
            if existing.isValid {
                await MainActor.run {
                    guard let self else { return }
                    WalletCardOperationStore.shared.set(.ready("Artwork + original backup verified ✅"), for: cleanId)
                    self.scanStatusText = "Found card: \(cleanId.prefix(12))… Original backup verified ✅"
                    self.objectWillChange.send()
                }
                return
            }

            if case .invalid(let reason) = existing {
                await MainActor.run {
                    guard let self else { return }
                    WalletCardOperationStore.shared.set(.failed("Existing backup needs recovery"), for: cleanId)
                    self.log.append("❌ Cannot create scan backup for \(cleanId.prefix(12)): \(reason)")
                }
                return
            }

            await MainActor.run {
                guard let self else { return }
                WalletCardOperationStore.shared.set(.backingUp("Preserving first-detected artwork…"), for: cleanId)
                self.scanStatusText = "Found card: \(cleanId.prefix(12))… Saving original artwork…"
            }

            let preparation = await Self.ensureOriginalArtworkBackup(
                cardId: cleanId,
                pairingPath: pairingPath,
                log: { line in
                    DispatchQueue.main.async {
                        AppViewModel.shared?.log.append(line)
                    }
                }
            )

            guard preparation.isReady else {
                await MainActor.run {
                    guard let self else { return }
                    WalletCardOperationStore.shared.set(.failed("Original backup failed"), for: cleanId)
                    self.scanStatusText = "Found card: \(cleanId.prefix(12))… Original backup failed"
                    self.errorMessage = "The card was scanned, but its first-detected artwork could not be preserved safely."
                }
                return
            }

            let verified = Self.validateOriginalArtworkBackup(for: cleanId)
            guard verified.isValid else {
                await MainActor.run {
                    guard let self else { return }
                    WalletCardOperationStore.shared.set(.failed("Original backup verification failed"), for: cleanId)
                    self.scanStatusText = "Found card: \(cleanId.prefix(12))… Backup verification failed"
                    self.errorMessage = "The scan completed, but the original-artwork backup did not pass integrity verification."
                }
                return
            }

            await MainActor.run {
                guard let self else { return }
                WalletCardOperationStore.shared.set(.ready("Artwork + original backup saved ✅"), for: cleanId)
                self.scanStatusText = "Found card: \(cleanId.prefix(12))… Original artwork saved ✅"
                self.log.append("✅ First-detected Wallet artwork preserved, immediately restored, and verified for \(cleanId.prefix(12))…")
                self.objectWillChange.send()
            }
        }
    }

    /// Refreshes only the canonical Wallet-rendered face after the user requests a
    /// preview refresh. The immutable original-artwork backup is deliberately untouched.
    func refreshRenderedReferenceAfterPreview(for cardId: String) {
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId
        guard hasPairingFile else { return }
        let pairingPath = PairingController.pairingFilePath()

        WalletCardOperationStore.shared.set(.scanning("Refreshing exact Wallet face…"), for: cleanId)

        Task(priority: .userInitiated) { [weak self] in
            let rendered = await Self.captureRenderedWalletReference(
                cardId: cleanId,
                pairingPath: pairingPath
            )

            await MainActor.run {
                guard let self else { return }
                switch rendered {
                case .captured(let manifest):
                    self.log.append(
                        "🎨 Wallet FrontFace refreshed for \(cleanId.prefix(12))… " +
                        "(\(manifest.pixelWidth)×\(manifest.pixelHeight), \(manifest.byteCount) bytes)"
                    )
                    WalletCardOperationStore.shared.set(.ready("Exact Wallet face refreshed ✅"), for: cleanId)
                case .unavailable(_, let detail):
                    var line = "ℹ️ Wallet FrontFace refresh found no decodable faceImage for \(cleanId.prefix(12))…"
                    if let detail { line += ": \(detail)" }
                    self.log.append(line)
                    WalletCardOperationStore.shared.set(.ready("Wallet preview refreshed · exact face unavailable"), for: cleanId)
                case .unsafe(let error):
                    self.log.append("⚠️ Wallet FrontFace refresh stopped: \(error)")
                    WalletCardOperationStore.shared.set(.failed("Wallet face refresh needs recovery"), for: cleanId)
                }
                self.objectWillChange.send()
            }
        }
    }
}
