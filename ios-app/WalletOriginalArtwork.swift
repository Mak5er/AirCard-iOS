import Foundation
import AirliftFFI

// MARK: - Original Wallet Artwork Backup / Restore

private final class OriginalArtworkLogBox: @unchecked Sendable {
    let handler: @Sendable (String) -> Void

    init(_ handler: @escaping @Sendable (String) -> Void) {
        self.handler = handler
    }
}

private let originalArtworkLogCallback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void = { context, message in
    guard let context, let message else { return }
    let box = Unmanaged<OriginalArtworkLogBox>.fromOpaque(context).takeUnretainedValue()
    box.handler(String(cString: message))
}

private struct OriginalArtworkBackupJournal: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let cardId: String
    let startedAt: Date
    var captured: [OriginalArtworkManifestFile]
    var missing: [String]
    var pendingLeaf: String?
}

enum OriginalArtworkBackupPreparation: Equatable {
    case existing
    case created
    case failed

    var isReady: Bool { self != .failed }

    /// New backups restore each exported provider file immediately, so callers no
    /// longer need to perform a whole-directory write-back after `.created`.
    var movedOriginalFiles: Bool { false }
}

extension AppViewModel {
    /// Artwork leaves that AirCard itself may overwrite when applying a skin.
    /// We preserve only files that actually exist on a given card.
    nonisolated static let originalWalletArtworkLeaves: [String] = [
        "cardBackgroundCombined@3x.png",
        "cardBackgroundCombined@2x.png",
        "cardBackgroundCombined.pdf",
        "diffuse@3x.png",
        "diffuse@2x.png",
        "background@3x.png",
        "background@2x.png",
        "background.pdf",
        "strip@3x.png",
        "strip@2x.png",
        "strip.pdf"
    ]

    nonisolated static func originalArtworkBackupDirectory(for cardId: String) -> URL {
        let safeId = cardId
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs
            .appendingPathComponent("WalletCards", isDirectory: true)
            .appendingPathComponent("Originals", isDirectory: true)
            .appendingPathComponent(safeId, isDirectory: true)
    }

    nonisolated static func originalArtworkBackupMarker(for cardId: String) -> URL {
        originalArtworkBackupDirectory(for: cardId).appendingPathComponent(".complete")
    }

    nonisolated private static func originalArtworkBackupJournalURL(for cardId: String) -> URL {
        originalArtworkBackupDirectory(for: cardId)
            .appendingPathComponent(".backup-journal.json")
    }

    nonisolated static func hasOriginalArtworkBackup(for cardId: String) -> Bool {
        validateOriginalArtworkBackup(for: cardId).isValid
    }

    nonisolated static func artworkExportFailureKind(_ error: String?) -> ArtworkExportFailureKind {
        WalletSafety.classifyArtworkExportFailure(error)
    }

    nonisolated private static func readOriginalArtworkBackupJournal(
        for cardId: String
    ) -> OriginalArtworkBackupJournal? {
        let url = originalArtworkBackupJournalURL(for: cardId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(OriginalArtworkBackupJournal.self, from: data)
    }

    nonisolated private static func writeOriginalArtworkBackupJournal(
        _ journal: OriginalArtworkBackupJournal,
        for cardId: String
    ) throws {
        let directory = originalArtworkBackupDirectory(for: cardId)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(journal).write(
            to: originalArtworkBackupJournalURL(for: cardId),
            options: .atomic
        )
    }

    nonisolated private static func clearOriginalArtworkBackupJournal(for cardId: String) {
        try? FileManager.default.removeItem(at: originalArtworkBackupJournalURL(for: cardId))
    }

    nonisolated private static func exportDeviceFile(
        pairingPath: String,
        devicePath: String,
        outputPath: String,
        log: @escaping @Sendable (String) -> Void
    ) async -> (ok: Bool, error: String?) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var outError: UnsafeMutablePointer<CChar>? = nil
                let logContext = Unmanaged.passRetained(OriginalArtworkLogBox(log)).toOpaque()
                defer { Unmanaged<OriginalArtworkLogBox>.fromOpaque(logContext).release() }

                let rc = pairingPath.withCString { pairC in
                    devicePath.withCString { deviceC in
                        outputPath.withCString { outputC in
                            al_exploit_export_file(
                                pairC,
                                deviceC,
                                outputC,
                                originalArtworkLogCallback,
                                logContext,
                                &outError
                            )
                        }
                    }
                }
                let error = outError.flatMap { String(validatingUTF8: $0) }
                if let p = outError { al_string_free(p) }
                continuation.resume(returning: (rc == 0, error))
            }
        }
    }

    nonisolated private static func writeArtworkDirectory(
        pairingPath: String,
        sourceDirectory: URL,
        targetDirectory: String,
        requireVerifiedManifestFor cardId: String?,
        log: @escaping @Sendable (String) -> Void
    ) async -> (ok: Bool, error: String?) {
        var leavesToWrite = originalWalletArtworkLeaves

        if let cardId {
            let validation = validateOriginalArtworkBackup(for: cardId)
            guard case .valid(let manifest) = validation else {
                return (false, "Original-artwork backup failed integrity validation: \(validation.message)")
            }
            // Only bytes explicitly covered by the verified manifest may be restored.
            // Extra files in the backup directory are ignored rather than trusted.
            leavesToWrite = manifest.files.map(\.name)
        }

        let stageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aircard_original_restore_\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: stageDirectory, withIntermediateDirectories: true)
            var copiedCount = 0
            for leaf in leavesToWrite {
                let source = sourceDirectory.appendingPathComponent(leaf)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                try FileManager.default.copyItem(at: source, to: stageDirectory.appendingPathComponent(leaf))
                copiedCount += 1
            }
            guard copiedCount > 0 else {
                try? FileManager.default.removeItem(at: stageDirectory)
                return (false, "No original Wallet artwork files are available in the backup")
            }
        } catch {
            try? FileManager.default.removeItem(at: stageDirectory)
            return (false, "Could not stage original Wallet artwork: \(error.localizedDescription)")
        }

        defer { try? FileManager.default.removeItem(at: stageDirectory) }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var outError: UnsafeMutablePointer<CChar>? = nil
                let logContext = Unmanaged.passRetained(OriginalArtworkLogBox(log)).toOpaque()
                defer { Unmanaged<OriginalArtworkLogBox>.fromOpaque(logContext).release() }

                let rc = pairingPath.withCString { pairC in
                    stageDirectory.path.withCString { sourceC in
                        targetDirectory.withCString { targetC in
                            al_exploit_write_dir(
                                pairC,
                                sourceC,
                                targetC,
                                originalArtworkLogCallback,
                                logContext,
                                &outError
                            )
                        }
                    }
                }
                let error = outError.flatMap { String(validatingUTF8: $0) }
                if let p = outError { al_string_free(p) }
                continuation.resume(returning: (rc == 0, error))
            }
        }
    }

    nonisolated private static func restoreSingleOriginalArtworkFile(
        cardId: String,
        leaf: String,
        pairingPath: String,
        log: @escaping @Sendable (String) -> Void
    ) async -> (ok: Bool, error: String?) {
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId
        guard originalWalletArtworkLeaves.contains(leaf) else {
            return (false, "Unexpected original-artwork leaf \(leaf)")
        }

        let backupDir = originalArtworkBackupDirectory(for: cleanId)
        let sourceURL = backupDir.appendingPathComponent(leaf)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            return (false, "Local recovery copy for \(leaf) is missing")
        }

        let oneFileStage = FileManager.default.temporaryDirectory
            .appendingPathComponent("aircard_original_single_\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: oneFileStage, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: sourceURL,
                to: oneFileStage.appendingPathComponent(leaf)
            )
        } catch {
            try? FileManager.default.removeItem(at: oneFileStage)
            return (false, "Could not stage immediate write-back for \(leaf): \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: oneFileStage) }

        let targetDir = "/var/mobile/Library/Passes/Cards/\(cleanId).pkpass"
        return await writeArtworkDirectory(
            pairingPath: pairingPath,
            sourceDirectory: oneFileStage,
            targetDirectory: targetDir,
            requireVerifiedManifestFor: nil,
            log: log
        )
    }

    nonisolated static func restoreOriginalArtworkBackupFiles(
        cardId: String,
        pairingPath: String,
        allowIncompleteRecovery: Bool = false,
        log: @escaping @Sendable (String) -> Void
    ) async -> (ok: Bool, error: String?) {
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId
        let backupDir = originalArtworkBackupDirectory(for: cleanId)
        let targetDir = "/var/mobile/Library/Passes/Cards/\(cleanId).pkpass"
        return await writeArtworkDirectory(
            pairingPath: pairingPath,
            sourceDirectory: backupDir,
            targetDirectory: targetDir,
            requireVerifiedManifestFor: allowIncompleteRecovery ? nil : cleanId,
            log: log
        )
    }

    /// Repairs the one file that may have been in-flight if a previous backup was
    /// interrupted. The journal is persisted before every move-based export, so a
    /// relaunch can retry the exact leaf rather than leaving Wallet in a partial state.
    nonisolated static func recoverInterruptedOriginalArtworkBackupIfNeeded(
        cardId: String,
        pairingPath: String,
        log: @escaping @Sendable (String) -> Void
    ) async -> (ok: Bool, recovered: Bool, error: String?) {
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId
        guard var journal = readOriginalArtworkBackupJournal(for: cleanId) else {
            return (true, false, nil)
        }

        guard journal.version <= OriginalArtworkBackupJournal.currentVersion,
              journal.cardId == cleanId else {
            return (false, false, "Original-artwork backup journal is invalid or belongs to another card")
        }

        let allowed = Set(originalWalletArtworkLeaves)
        guard Set(journal.missing).isSubset(of: allowed),
              Set(journal.captured.map(\.name)).isSubset(of: allowed) else {
            return (false, false, "Original-artwork backup journal contains unexpected files")
        }

        let backupDir = originalArtworkBackupDirectory(for: cleanId)
        for entry in journal.captured {
            let url = backupDir.appendingPathComponent(entry.name)
            guard let data = try? Data(contentsOf: url),
                  data.count == entry.size,
                  WalletSafety.sha256Hex(data) == entry.sha256.lowercased() else {
                return (false, false, "Interrupted backup copy failed integrity validation for \(entry.name)")
            }
        }

        guard let pendingLeaf = journal.pendingLeaf else {
            return (true, false, nil)
        }
        guard allowed.contains(pendingLeaf) else {
            return (false, false, "Interrupted backup references unexpected file \(pendingLeaf)")
        }

        log("  🛟 Resuming interrupted original-artwork backup at \(pendingLeaf)…")
        let localURL = backupDir.appendingPathComponent(pendingLeaf)

        if !FileManager.default.fileExists(atPath: localURL.path) {
            let devicePath = "/var/mobile/Library/Passes/Cards/\(cleanId).pkpass/\(pendingLeaf)"
            let retry = await exportDeviceFile(
                pairingPath: pairingPath,
                devicePath: devicePath,
                outputPath: localURL.path,
                log: { line in
                    if line.contains("airlift-export:") { log("    " + line) }
                }
            )
            guard retry.ok else {
                return (
                    false,
                    false,
                    "Could not recover interrupted \(pendingLeaf): \(retry.error ?? "unknown export error")"
                )
            }
        }

        guard let data = try? Data(contentsOf: localURL), !data.isEmpty else {
            return (false, false, "Interrupted local recovery copy for \(pendingLeaf) is unreadable")
        }
        let entry = WalletSafety.fileEntry(name: pendingLeaf, data: data)

        let writeBack = await restoreSingleOriginalArtworkFile(
            cardId: cleanId,
            leaf: pendingLeaf,
            pairingPath: pairingPath,
            log: { line in
                if line.contains("airlift:") { log("    " + line) }
            }
        )
        guard writeBack.ok else {
            return (
                false,
                false,
                "Could not write interrupted \(pendingLeaf) back to Wallet: \(writeBack.error ?? "unknown write error")"
            )
        }

        journal.captured.removeAll { $0.name == pendingLeaf }
        journal.captured.append(entry)
        journal.pendingLeaf = nil
        do {
            try writeOriginalArtworkBackupJournal(journal, for: cleanId)
        } catch {
            return (
                false,
                true,
                "Wallet file was restored, but the backup journal could not be updated: \(error.localizedDescription)"
            )
        }

        log("  ✅ Interrupted \(pendingLeaf) restored to Wallet")
        return (true, true, nil)
    }

    /// Ensures an immutable, verified original-artwork backup exists before the first skin write.
    ///
    /// AirTraffic export is move-based. To minimize the interruption window, every successfully
    /// exported provider file is verified locally and written back to its original Wallet path
    /// immediately before AirCard probes the next candidate. A persistent per-card journal keeps
    /// at most one leaf in-flight and allows a later launch to resume an interrupted backup.
    nonisolated static func ensureOriginalArtworkBackup(
        cardId: String,
        pairingPath: String,
        log: @escaping @Sendable (String) -> Void
    ) async -> OriginalArtworkBackupPreparation {
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId

        let interrupted = await recoverInterruptedOriginalArtworkBackupIfNeeded(
            cardId: cleanId,
            pairingPath: pairingPath,
            log: log
        )
        guard interrupted.ok else {
            log("  ❌ Interrupted backup recovery failed: \(interrupted.error ?? "unknown recovery error")")
            return .failed
        }

        let validation = validateOriginalArtworkBackup(for: cleanId)
        if validation.isValid {
            clearOriginalArtworkBackupJournal(for: cleanId)
            log("  🗃️ Original artwork backup already exists and is verified")
            return .existing
        }
        if case .invalid(let reason) = validation {
            log("  ❌ Existing original-artwork backup is invalid: \(reason)")
            log("  ❌ Refusing to overwrite an unverified backup; use Recovery diagnostics")
            return .failed
        }

        let backupDir = originalArtworkBackupDirectory(for: cleanId)
        let marker = originalArtworkBackupMarker(for: cleanId)

        do {
            try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: marker)
        } catch {
            log("  ❌ Cannot create original-artwork backup directory: \(error.localizedDescription)")
            return .failed
        }

        var journal: OriginalArtworkBackupJournal
        if let existingJournal = readOriginalArtworkBackupJournal(for: cleanId) {
            journal = existingJournal
        } else {
            let existingIncomplete = originalWalletArtworkLeaves.filter {
                FileManager.default.fileExists(atPath: backupDir.appendingPathComponent($0).path)
            }
            guard existingIncomplete.isEmpty else {
                log("  ❌ Incomplete original-artwork files exist without a resumable journal")
                log("  ❌ Refusing to overwrite them; open Recovery diagnostics for this card")
                return .failed
            }
            journal = OriginalArtworkBackupJournal(
                version: OriginalArtworkBackupJournal.currentVersion,
                cardId: cleanId,
                startedAt: Date(),
                captured: [],
                missing: [],
                pendingLeaf: nil
            )
            do {
                try writeOriginalArtworkBackupJournal(journal, for: cleanId)
            } catch {
                log("  ❌ Cannot create original-artwork backup journal: \(error.localizedDescription)")
                return .failed
            }
        }

        guard journal.version <= OriginalArtworkBackupJournal.currentVersion,
              journal.cardId == cleanId else {
            log("  ❌ Original-artwork backup journal is invalid")
            return .failed
        }

        let capturedNames = Set(journal.captured.map(\.name))
        let localKnownFiles = Set(originalWalletArtworkLeaves.filter {
            FileManager.default.fileExists(atPath: backupDir.appendingPathComponent($0).path)
        })
        guard localKnownFiles == capturedNames else {
            log("  ❌ Backup directory and resumable journal do not match")
            log("  ❌ Refusing to guess which local files are authoritative")
            return .failed
        }

        log(journal.captured.isEmpty
            ? "  🗃️ Backing up original Wallet artwork with immediate write-back…"
            : "  🗃️ Resuming original Wallet artwork backup (\(journal.captured.count) already preserved)…")

        for leaf in originalWalletArtworkLeaves {
            if journal.captured.contains(where: { $0.name == leaf }) || journal.missing.contains(leaf) {
                continue
            }

            journal.pendingLeaf = leaf
            do {
                try writeOriginalArtworkBackupJournal(journal, for: cleanId)
            } catch {
                log("    ❌ Could not journal pending export for \(leaf): \(error.localizedDescription)")
                return .failed
            }

            let devicePath = "/var/mobile/Library/Passes/Cards/\(cleanId).pkpass/\(leaf)"
            let localURL = backupDir.appendingPathComponent(leaf)
            let result = await exportDeviceFile(
                pairingPath: pairingPath,
                devicePath: devicePath,
                outputPath: localURL.path,
                log: { line in
                    if line.contains("airlift-export:") { log("    " + line) }
                }
            )

            if !result.ok {
                if artworkExportFailureKind(result.error) == .sourceMissing {
                    journal.pendingLeaf = nil
                    if !journal.missing.contains(leaf) { journal.missing.append(leaf) }
                    do {
                        try writeOriginalArtworkBackupJournal(journal, for: cleanId)
                    } catch {
                        log("    ❌ Could not record missing \(leaf): \(error.localizedDescription)")
                        return .failed
                    }
                    log("    · Not present: \(leaf)")
                    continue
                }

                log("    ❌ Backup failed at \(leaf): \(result.error ?? "unknown export error")")
                if FileManager.default.fileExists(atPath: localURL.path) {
                    let emergency = await restoreSingleOriginalArtworkFile(
                        cardId: cleanId,
                        leaf: leaf,
                        pairingPath: pairingPath,
                        log: { _ in }
                    )
                    if emergency.ok {
                        log("    ✅ Emergency write-back completed for \(leaf)")
                    } else {
                        log("    ❌ Emergency write-back also failed: \(emergency.error ?? "unknown write error")")
                    }
                }
                log("  ⚠️ Backup journal retained so the exact in-flight leaf can be recovered")
                return .failed
            }

            guard let data = try? Data(contentsOf: localURL), !data.isEmpty else {
                log("    ❌ Exported \(leaf) could not be verified locally")
                log("  ⚠️ Backup journal retained for recovery")
                return .failed
            }
            let entry = WalletSafety.fileEntry(name: leaf, data: data)

            let writeBack = await restoreSingleOriginalArtworkFile(
                cardId: cleanId,
                leaf: leaf,
                pairingPath: pairingPath,
                log: { line in
                    if line.contains("airlift:") { log("    " + line) }
                }
            )
            guard writeBack.ok else {
                log("    ❌ Immediate write-back failed for \(leaf): \(writeBack.error ?? "unknown write error")")
                log("  ⚠️ Local original and journal retained for automatic recovery")
                return .failed
            }

            journal.captured.removeAll { $0.name == leaf }
            journal.captured.append(entry)
            journal.pendingLeaf = nil
            do {
                try writeOriginalArtworkBackupJournal(journal, for: cleanId)
            } catch {
                log("    ❌ \(leaf) was restored, but backup progress could not be journaled: \(error.localizedDescription)")
                return .failed
            }

            log("    ✅ Preserved + immediately restored \(leaf)")
        }

        guard !journal.captured.isEmpty else {
            log("  ❌ No original Wallet artwork files could be preserved; skin write cancelled")
            clearOriginalArtworkBackupJournal(for: cleanId)
            return .failed
        }

        do {
            let manifest = try finalizeOriginalArtworkBackup(cardId: cleanId, directory: backupDir)
            let verified = validateOriginalArtworkBackup(for: cleanId)
            guard verified.isValid else {
                throw NSError(
                    domain: "AirCardOriginalArtwork",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: verified.message]
                )
            }
            clearOriginalArtworkBackupJournal(for: cleanId)
            log("  ✅ Original artwork backup saved and verified (\(manifest.files.count) file\(manifest.files.count == 1 ? "" : "s")); Wallet originals already restored")
            return .created
        } catch {
            log("  ❌ Could not finalize original-artwork backup: \(error.localizedDescription)")
            log("  ⚠️ Verified local originals and resumable journal retained for Recovery diagnostics")
            return .failed
        }
    }

    nonisolated static func invalidateWalletCardCaches(
        cardId: String,
        pairingPath: String
    ) async {
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId
        let stageDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("airlift_restore_inv_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
        for leaf in ["FrontFace", "Preview", "PlaceHolder"] {
            try? Data("corrupted".utf8).write(to: stageDir.appendingPathComponent(leaf))
        }

        for ext in [".cache", ".pkcache"] {
            let cacheTarget = "/var/mobile/Library/Passes/Cards/\(cleanId)\(ext)"
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    var outError: UnsafeMutablePointer<CChar>? = nil
                    _ = pairingPath.withCString { pairC in
                        stageDir.path.withCString { sourceC in
                            cacheTarget.withCString { targetC in
                                al_exploit_write_dir(pairC, sourceC, targetC, nil, nil, &outError)
                            }
                        }
                    }
                    if let p = outError { al_string_free(p) }
                    continuation.resume()
                }
            }
        }
        try? FileManager.default.removeItem(at: stageDir)
    }

    /// Legacy non-exact restore entry point retained for compatibility. New UI uses exact restore.
    func restoreOriginalArtwork(for cardId: String) {
        restoreOriginalArtworkExactly(for: cardId)
    }
}
