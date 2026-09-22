import Foundation
import CryptoKit
import SwiftUI
import AirliftFFI

struct OriginalArtworkManifestFile: Codable, Equatable, Sendable {
    let name: String
    let size: Int
    let sha256: String
}

struct OriginalArtworkManifest: Codable, Equatable, Sendable {
    static let currentVersion = 2

    let version: Int
    let cardId: String
    let createdAt: Date
    let files: [OriginalArtworkManifestFile]
}

enum OriginalArtworkBackupValidation: Equatable, Sendable {
    case valid(OriginalArtworkManifest)
    case missing
    case invalid(String)

    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }

    var manifest: OriginalArtworkManifest? {
        if case .valid(let manifest) = self { return manifest }
        return nil
    }

    var message: String {
        switch self {
        case .valid(let manifest):
            return "Verified · \(manifest.files.count) file\(manifest.files.count == 1 ? "" : "s")"
        case .missing:
            return "No original backup"
        case .invalid(let reason):
            return "Backup invalid · \(reason)"
        }
    }
}

enum ArtworkExportFailureKind: Equatable, Sendable {
    case sourceMissing
    case fatal
}

struct WalletArtworkBackupBundle: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let cardId: String
    let exportedAt: Date
    let manifest: OriginalArtworkManifest
    let files: [String: Data]
}

enum WalletRecoveryKind: String, Sendable {
    case scanWriteBack = "Scan write-back"
    case restoreSnapshot = "Restore rollback snapshot"
    case incompleteOriginal = "Incomplete original backup"
}

struct WalletRecoveryItem: Identifiable, Sendable {
    var id: String { url.path }
    let kind: WalletRecoveryKind
    let cardId: String
    let url: URL
    let fileCount: Int
    let modifiedAt: Date?
}

enum WalletCardOperationPhase: Equatable, Sendable {
    case idle
    case scanning(String)
    case ready(String)
    case backingUp(String)
    case writing(String)
    case refreshing(String)
    case restoring(String)
    case failed(String)

    var label: String? {
        switch self {
        case .idle: return nil
        case .scanning(let value), .ready(let value), .backingUp(let value),
             .writing(let value), .refreshing(let value), .restoring(let value),
             .failed(let value): return value
        }
    }

    var systemImage: String {
        switch self {
        case .idle: return "circle"
        case .scanning: return "wave.3.right"
        case .ready: return "checkmark.circle.fill"
        case .backingUp: return "archivebox.fill"
        case .writing: return "bolt.fill"
        case .refreshing: return "arrow.clockwise"
        case .restoring: return "arrow.uturn.backward.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

@MainActor
final class WalletCardOperationStore: ObservableObject {
    static let shared = WalletCardOperationStore()

    @Published private(set) var phases: [String: WalletCardOperationPhase] = [:]

    func set(_ phase: WalletCardOperationPhase, for cardId: String) {
        phases[CardItem.cleanCardId(cardId) ?? cardId] = phase
    }

    func phase(for cardId: String) -> WalletCardOperationPhase {
        phases[CardItem.cleanCardId(cardId) ?? cardId] ?? .idle
    }

    func clear(_ cardId: String) {
        phases.removeValue(forKey: CardItem.cleanCardId(cardId) ?? cardId)
    }

    func clearAll() {
        phases.removeAll()
    }
}

enum WalletSafety {
    static let missingExportMarker = "Exported file not found in AFC recovery area"

    static func classifyArtworkExportFailure(_ error: String?) -> ArtworkExportFailureKind {
        guard let error, error.contains(missingExportMarker) else { return .fatal }
        return .sourceMissing
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func fileEntry(name: String, data: Data) -> OriginalArtworkManifestFile {
        OriginalArtworkManifestFile(name: name, size: data.count, sha256: sha256Hex(data))
    }

    static func makeManifest(
        cardId: String,
        directory: URL,
        leaves: [String],
        createdAt: Date = Date()
    ) throws -> OriginalArtworkManifest {
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId
        var entries: [OriginalArtworkManifestFile] = []
        for leaf in leaves.sorted() {
            let url = directory.appendingPathComponent(leaf)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let data = try Data(contentsOf: url)
            entries.append(fileEntry(name: leaf, data: data))
        }
        guard !entries.isEmpty else {
            throw NSError(
                domain: "AirCardWalletBackup",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No artwork files are available to manifest"]
            )
        }
        return OriginalArtworkManifest(
            version: OriginalArtworkManifest.currentVersion,
            cardId: cleanId,
            createdAt: createdAt,
            files: entries
        )
    }

    static func writeManifest(_ manifest: OriginalArtworkManifest, to marker: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(manifest).write(to: marker, options: .atomic)
    }

    static func decodeManifest(_ data: Data) -> OriginalArtworkManifest? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(OriginalArtworkManifest.self, from: data)
    }

    static func validateManifest(
        _ manifest: OriginalArtworkManifest,
        cardId: String,
        directory: URL,
        allowedLeaves: Set<String>
    ) -> OriginalArtworkBackupValidation {
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId
        guard manifest.version <= OriginalArtworkManifest.currentVersion else {
            return .invalid("unsupported manifest version \(manifest.version)")
        }
        guard manifest.cardId == cleanId else {
            return .invalid("card identifier mismatch")
        }
        guard !manifest.files.isEmpty else {
            return .invalid("manifest contains no files")
        }

        var names = Set<String>()
        for entry in manifest.files {
            guard allowedLeaves.contains(entry.name) else {
                return .invalid("unexpected file \(entry.name)")
            }
            guard names.insert(entry.name).inserted else {
                return .invalid("duplicate file \(entry.name)")
            }
            let url = directory.appendingPathComponent(entry.name)
            guard let data = try? Data(contentsOf: url) else {
                return .invalid("missing \(entry.name)")
            }
            guard data.count == entry.size else {
                return .invalid("size mismatch for \(entry.name)")
            }
            guard sha256Hex(data) == entry.sha256.lowercased() else {
                return .invalid("SHA-256 mismatch for \(entry.name)")
            }
        }
        return .valid(manifest)
    }

    static func exactRestoreInventory(
        currentLeaves: Set<String>,
        originalLeaves: Set<String>,
        allowedLeaves: Set<String>
    ) -> (remove: Set<String>, restore: Set<String>) {
        (
            currentLeaves.intersection(allowedLeaves),
            originalLeaves.intersection(allowedLeaves)
        )
    }

    static func recoveryInventory(
        root: URL,
        cardId: String,
        kind: WalletRecoveryKind
    ) -> [WalletRecoveryItem] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .contentModificationDateKey]
        let children = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )) ?? []

        let directories: [URL]
        if children.contains(where: { (try? $0.resourceValues(forKeys: resourceKeys).isDirectory) == true }) {
            directories = children.filter { (try? $0.resourceValues(forKeys: resourceKeys).isDirectory) == true }
        } else {
            directories = [root]
        }

        return directories.compactMap { directory in
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            guard !files.isEmpty else { return nil }
            let modified = try? directory.resourceValues(forKeys: resourceKeys).contentModificationDate
            return WalletRecoveryItem(
                kind: kind,
                cardId: cardId,
                url: directory,
                fileCount: files.count,
                modifiedAt: modified
            )
        }
    }
}

extension AppViewModel {
    nonisolated static func validateOriginalArtworkBackup(for cardId: String) -> OriginalArtworkBackupValidation {
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId
        let directory = originalArtworkBackupDirectory(for: cleanId)
        let marker = originalArtworkBackupMarker(for: cleanId)
        guard let markerData = try? Data(contentsOf: marker) else { return .missing }
        let allowed = Set(originalWalletArtworkLeaves)

        if let manifest = WalletSafety.decodeManifest(markerData) {
            return WalletSafety.validateManifest(
                manifest,
                cardId: cleanId,
                directory: directory,
                allowedLeaves: allowed
            )
        }

        // Backward compatibility with the original newline-only .complete marker.
        guard let legacyText = String(data: markerData, encoding: .utf8) else {
            return .invalid("manifest is unreadable")
        }
        let legacyLeaves = legacyText
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { allowed.contains($0) }
        guard !legacyLeaves.isEmpty else { return .invalid("legacy manifest is empty") }

        do {
            let manifest = try WalletSafety.makeManifest(
                cardId: cleanId,
                directory: directory,
                leaves: legacyLeaves,
                createdAt: (try? marker.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            )
            let validation = WalletSafety.validateManifest(
                manifest,
                cardId: cleanId,
                directory: directory,
                allowedLeaves: allowed
            )
            if validation.isValid {
                try? WalletSafety.writeManifest(manifest, to: marker)
            }
            return validation
        } catch {
            return .invalid(error.localizedDescription)
        }
    }

    nonisolated static func finalizeOriginalArtworkBackup(
        cardId: String,
        directory: URL? = nil
    ) throws -> OriginalArtworkManifest {
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId
        let backupDir = directory ?? originalArtworkBackupDirectory(for: cleanId)
        let manifest = try WalletSafety.makeManifest(
            cardId: cleanId,
            directory: backupDir,
            leaves: originalWalletArtworkLeaves
        )
        try WalletSafety.writeManifest(manifest, to: backupDir.appendingPathComponent(".complete"))
        return manifest
    }

    nonisolated static func exportOriginalArtworkBackup(for cardId: String) throws -> URL {
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId
        guard case .valid(let manifest) = validateOriginalArtworkBackup(for: cleanId) else {
            throw NSError(
                domain: "AirCardWalletBackup",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "A verified original-artwork backup is required before export"]
            )
        }
        let directory = originalArtworkBackupDirectory(for: cleanId)
        var files: [String: Data] = [:]
        for entry in manifest.files {
            files[entry.name] = try Data(contentsOf: directory.appendingPathComponent(entry.name))
        }
        let bundle = WalletArtworkBackupBundle(
            version: WalletArtworkBackupBundle.currentVersion,
            cardId: cleanId,
            exportedAt: Date(),
            manifest: manifest,
            files: files
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(bundle)
        let safeId = cleanId
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirCard-Original-\(safeId).aircardbackup")
        try data.write(to: url, options: .atomic)
        return url
    }

    func importOriginalArtworkBackup(from url: URL, for cardId: String) throws {
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId
        let existingValidation = Self.validateOriginalArtworkBackup(for: cleanId)
        guard case .missing = existingValidation else {
            throw NSError(
                domain: "AirCardWalletBackup",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        existingValidation.isValid
                        ? "A verified immutable backup already exists for this card and will not be overwritten"
                        : "Existing backup or recovery data is present for this card. Resolve it in Recovery Diagnostics before importing another original backup."
                ]
            )
        }

        let target = Self.originalArtworkBackupDirectory(for: cleanId)
        let existingKnownFiles = Self.originalWalletArtworkLeaves.filter {
            FileManager.default.fileExists(atPath: target.appendingPathComponent($0).path)
        }
        guard existingKnownFiles.isEmpty else {
            throw NSError(
                domain: "AirCardWalletBackup",
                code: 9,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Incomplete original-artwork recovery files already exist for this card. AirCard will not overwrite them."
                ]
            )
        }

        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundle = try decoder.decode(WalletArtworkBackupBundle.self, from: data)
        guard bundle.version <= WalletArtworkBackupBundle.currentVersion else {
            throw NSError(domain: "AirCardWalletBackup", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unsupported AirCard backup version"])
        }
        guard bundle.cardId == cleanId, bundle.manifest.cardId == cleanId else {
            throw NSError(domain: "AirCardWalletBackup", code: 5, userInfo: [NSLocalizedDescriptionKey: "This backup belongs to a different Wallet card"])
        }

        let allowed = Set(Self.originalWalletArtworkLeaves)
        for entry in bundle.manifest.files {
            guard allowed.contains(entry.name), let fileData = bundle.files[entry.name] else {
                throw NSError(domain: "AirCardWalletBackup", code: 6, userInfo: [NSLocalizedDescriptionKey: "Backup is incomplete"])
            }
            guard fileData.count == entry.size,
                  WalletSafety.sha256Hex(fileData) == entry.sha256.lowercased() else {
                throw NSError(domain: "AirCardWalletBackup", code: 7, userInfo: [NSLocalizedDescriptionKey: "Backup integrity verification failed for \(entry.name)"])
            }
        }

        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("aircard_backup_import_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: stage) }
        for entry in bundle.manifest.files {
            try bundle.files[entry.name]!.write(to: stage.appendingPathComponent(entry.name), options: .atomic)
        }
        try WalletSafety.writeManifest(bundle.manifest, to: stage.appendingPathComponent(".complete"))
        let stagedValidation = WalletSafety.validateManifest(
            bundle.manifest,
            cardId: cleanId,
            directory: stage,
            allowedLeaves: allowed
        )
        guard stagedValidation.isValid else {
            throw NSError(domain: "AirCardWalletBackup", code: 8, userInfo: [NSLocalizedDescriptionKey: stagedValidation.message])
        }

        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: stage, to: target)
        objectWillChange.send()
    }

    nonisolated static func restoreRecoveryRoot(for cardId: String) -> URL {
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId
        let safeId = cleanId
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs
            .appendingPathComponent("WalletCards", isDirectory: true)
            .appendingPathComponent("RestoreRecovery", isDirectory: true)
            .appendingPathComponent(safeId, isDirectory: true)
    }

    nonisolated static func walletRecoveryItems(for cardId: String) -> [WalletRecoveryItem] {
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId
        var items: [WalletRecoveryItem] = []
        items += WalletSafety.recoveryInventory(
            root: scannedCardRecoveryDirectory(for: cleanId),
            cardId: cleanId,
            kind: .scanWriteBack
        )
        items += WalletSafety.recoveryInventory(
            root: restoreRecoveryRoot(for: cleanId),
            cardId: cleanId,
            kind: .restoreSnapshot
        )

        let backupDir = originalArtworkBackupDirectory(for: cleanId)
        let marker = originalArtworkBackupMarker(for: cleanId)
        if FileManager.default.fileExists(atPath: backupDir.path),
           !FileManager.default.fileExists(atPath: marker.path) {
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: backupDir.path)) ?? [])
                .filter { originalWalletArtworkLeaves.contains($0) }
            if !files.isEmpty {
                items.append(WalletRecoveryItem(
                    kind: .incompleteOriginal,
                    cardId: cleanId,
                    url: backupDir,
                    fileCount: files.count,
                    modifiedAt: (try? backupDir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ))
            }
        }
        return items.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    nonisolated static func writeWalletDirectory(
        pairingPath: String,
        sourceDirectory: URL,
        targetDirectory: String
    ) async -> (ok: Bool, error: String?) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var outError: UnsafeMutablePointer<CChar>? = nil
                let rc = pairingPath.withCString { pairC in
                    sourceDirectory.path.withCString { sourceC in
                        targetDirectory.withCString { targetC in
                            al_exploit_write_dir(pairC, sourceC, targetC, nil, nil, &outError)
                        }
                    }
                }
                let error = outError.flatMap { String(validatingUTF8: $0) }
                if let pointer = outError { al_string_free(pointer) }
                continuation.resume(returning: (rc == 0, error))
            }
        }
    }

    func retryRecovery(_ item: WalletRecoveryItem) {
        guard hasPairingFile else {
            errorMessage = "Pair this iPhone before repairing Wallet recovery files."
            return
        }
        guard item.kind != .incompleteOriginal else {
            errorMessage = "This is an incomplete original backup. Keep it for diagnosis; it cannot be safely auto-restored without a completed manifest."
            return
        }
        let cleanId = CardItem.cleanCardId(item.cardId) ?? item.cardId
        let target = "/var/mobile/Library/Passes/Cards/\(cleanId).pkpass"
        let pairingPath = PairingController.pairingFilePath()
        WalletCardOperationStore.shared.set(.restoring("Repairing recovery snapshot…"), for: cleanId)

        Task.detached { [weak self] in
            let result = await Self.writeWalletDirectory(
                pairingPath: pairingPath,
                sourceDirectory: item.url,
                targetDirectory: target
            )
            if result.ok {
                await Self.invalidateWalletCardCaches(cardId: cleanId, pairingPath: pairingPath)
                try? FileManager.default.removeItem(at: item.url)
            }
            await MainActor.run {
                guard let self else { return }
                if result.ok {
                    WalletCardOperationStore.shared.set(.ready("Recovery repaired ✅"), for: cleanId)
                    self.successAlertMessage = "Wallet recovery snapshot was written back successfully."
                    self.showSuccessAlert = true
                    self.objectWillChange.send()
                } else {
                    WalletCardOperationStore.shared.set(.failed("Recovery repair failed"), for: cleanId)
                    self.errorMessage = "Recovery repair failed: \(result.error ?? "unknown write error")"
                }
            }
        }
    }
}
