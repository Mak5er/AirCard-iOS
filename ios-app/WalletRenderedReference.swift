import Foundation
import UIKit
import CryptoKit
import AirliftFFI

/// Describes the canonical Wallet-rendered face captured from the per-card cache.
/// This is deliberately separate from the immutable provider-file backup used by
/// Restore Original. The rendered face is for faithful preview/reproduction; the
/// raw provider files remain the only authoritative restore source.
struct WalletRenderedReferenceManifest: Codable, Equatable, Sendable {
    let version: Int
    let cardId: String
    let capturedAt: Date
    let cacheSuffix: String
    let leaf: String
    let byteCount: Int
    let sha256: String
    let pixelWidth: Int
    let pixelHeight: Int
    let extractionPath: String?
    let containerByteCount: Int?
    let containerSha256: String?
}

enum WalletRenderedReferenceCaptureResult: Sendable {
    case captured(WalletRenderedReferenceManifest)
    case unavailable(attempted: Int, detail: String?)
    case unsafe(error: String)
}

private struct WalletRenderedCacheCandidate: Sendable {
    let suffix: String
    let leaf: String
}

private struct WalletRenderedCacheReadResult: Sendable {
    let data: Data?
    let sourceMissing: Bool
    let error: String?
}

/// Local decode target for Wallet's archived PKImage object. We intentionally decode
/// only imageData and do not instantiate any PassKit-private runtime class.
@objc(AirCardArchivedPKImage)
private final class AirCardArchivedPKImage: NSObject, NSCoding {
    let imageData: Data?

    required init?(coder: NSCoder) {
        imageData = coder.decodeObject(forKey: "imageData") as? Data
        super.init()
    }

    func encode(with coder: NSCoder) { }
}

/// Local decode target for the archived FrontFace image set. Only faceImage is needed;
/// other archived layers are ignored so their private classes never have to load.
@objc(AirCardArchivedFrontFaceImageSet)
private final class AirCardArchivedFrontFaceImageSet: NSObject, NSCoding {
    let faceImage: AirCardArchivedPKImage?

    required init?(coder: NSCoder) {
        faceImage = coder.decodeObject(forKey: "faceImage") as? AirCardArchivedPKImage
        super.init()
    }

    func encode(with coder: NSCoder) { }
}

extension AppViewModel {
    /// The final composite is FrontFace. Preview is an icon-oriented cache and
    /// PlaceHolder is only a partial strip, so neither is accepted as a full card face.
    private nonisolated static let renderedWalletCacheCandidates: [WalletRenderedCacheCandidate] = [
        .init(suffix: ".pkcache", leaf: "FrontFace"),
        .init(suffix: ".cache", leaf: "FrontFace")
    ]

    nonisolated static func renderedWalletReferenceDirectory(for cardId: String) -> URL {
        let safeId = scannedCardSafeId(cardId)
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WalletCards", isDirectory: true)
            .appendingPathComponent("RenderedReferences", isDirectory: true)
            .appendingPathComponent(safeId, isDirectory: true)
    }

    nonisolated static func renderedWalletReferenceImagePath(for cardId: String) -> URL {
        renderedWalletReferenceDirectory(for: cardId)
            .appendingPathComponent("reference.png")
    }

    nonisolated static func renderedWalletReferenceManifestPath(for cardId: String) -> URL {
        renderedWalletReferenceDirectory(for: cardId)
            .appendingPathComponent("manifest.json")
    }

    nonisolated static func renderedWalletReferenceImage(for cardId: String) -> UIImage? {
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId
        let url = renderedWalletReferenceImagePath(for: cleanId)
        guard let data = try? Data(contentsOf: url) else { return nil }

        // Version 2+ manifests describe the exact persisted face image. Verify it before
        // display so a partial/corrupt cache capture cannot silently become the preview.
        if let manifest = renderedWalletReferenceManifest(for: cleanId), manifest.version >= 2 {
            guard manifest.cardId == cleanId,
                  manifest.byteCount == data.count,
                  manifest.sha256 == renderedReferenceSHA256(data) else {
                return nil
            }
        }

        return ImageEngine.safeImageFromData(data, maxDimension: 4096)
    }

    nonisolated static func renderedWalletReferenceManifest(for cardId: String) -> WalletRenderedReferenceManifest? {
        let url = renderedWalletReferenceManifestPath(for: cardId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WalletRenderedReferenceManifest.self, from: data)
    }

    /// Returns the original Wallet-rendered reference only when both the
    /// extracted face image and the captured FrontFace cache container still
    /// match their first-capture hashes.
    nonisolated static func verifiedOriginalRenderedReferenceManifest(
        for cardId: String
    ) -> WalletRenderedReferenceManifest? {
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId

        guard let manifest = renderedWalletReferenceManifest(for: cleanId),
              manifest.version >= 2,
              manifest.cardId == cleanId,
              manifest.leaf == "FrontFace",
              [".cache", ".pkcache"].contains(manifest.cacheSuffix),
              let expectedContainerCount = manifest.containerByteCount,
              let expectedContainerSHA = manifest.containerSha256 else {
            return nil
        }

        guard let faceData = try? Data(
            contentsOf: renderedWalletReferenceImagePath(for: cleanId)
        ),
        faceData.count == manifest.byteCount,
        renderedReferenceSHA256(faceData) == manifest.sha256 else {
            return nil
        }

        let safeSuffix = manifest.cacheSuffix
            .replacingOccurrences(of: ".", with: "")

        let rawURL = renderedWalletReferenceDirectory(for: cleanId)
            .appendingPathComponent("Raw", isDirectory: true)
            .appendingPathComponent("\(safeSuffix)-\(manifest.leaf).bin")

        guard let containerData = try? Data(contentsOf: rawURL),
              containerData.count == expectedContainerCount,
              renderedReferenceSHA256(containerData) == expectedContainerSHA else {
            return nil
        }

        return manifest
    }

    /// AirTraffic export is move-based. For disposable Wallet cache entries this
    /// lets us remove a stale generated cache file before reinstating the exact
    /// original FrontFace container.
    nonisolated private static func removeWalletCacheFile(
        pairingPath: String,
        devicePath: String
    ) async -> (removed: Bool, missing: Bool, error: String?) {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "aircard_cache_remove_\(UUID().uuidString)",
                isDirectory: true
            )

        do {
            try FileManager.default.createDirectory(
                at: tempDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            return (
                false,
                false,
                "Could not create cache-removal staging: \(error.localizedDescription)"
            )
        }

        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        let outputPath = tempDirectory
            .appendingPathComponent("removed-cache-entry")
            .path

        let result: (ok: Bool, error: String?) = await withCheckedContinuation {
            continuation in

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

                let error = outError.flatMap {
                    String(validatingUTF8: $0)
                }

                if let pointer = outError {
                    al_string_free(pointer)
                }

                continuation.resume(
                    returning: (rc == 0, error)
                )
            }
        }

        if result.ok {
            return (true, false, nil)
        }

        if WalletSafety.classifyArtworkExportFailure(result.error) == .sourceMissing {
            return (false, true, nil)
        }

        return (false, false, result.error)
    }

    /// Restores the exact original Wallet FrontFace cache captured before the
    /// first AirCard modification.
    ///
    /// reference.png is verification/preview data only. The original binary
    /// Wallet cache container is written back byte-for-byte.
    nonisolated static func restoreCapturedWalletFrontFaceCache(
        cardId: String,
        pairingPath: String
    ) async -> (restored: Bool, error: String?) {
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId

        guard let manifest =
                verifiedOriginalRenderedReferenceManifest(for: cleanId) else {
            return (false, nil)
        }

        let safeSuffix = manifest.cacheSuffix
            .replacingOccurrences(of: ".", with: "")

        let rawURL = renderedWalletReferenceDirectory(for: cleanId)
            .appendingPathComponent("Raw", isDirectory: true)
            .appendingPathComponent("\(safeSuffix)-\(manifest.leaf).bin")

        guard let originalContainer = try? Data(contentsOf: rawURL) else {
            return (
                false,
                "Verified original FrontFace cache container is missing"
            )
        }

        guard originalContainer.count == manifest.containerByteCount,
              renderedReferenceSHA256(originalContainer)
                == manifest.containerSha256 else {
            return (
                false,
                "Original FrontFace cache container failed integrity verification"
            )
        }

        // Remove all currently generated cache artwork first. This prevents
        // another cache suffix from winning over the restored original face.
        for suffix in [".cache", ".pkcache"] {
            for leaf in ["FrontFace", "Preview", "PlaceHolder"] {
                let devicePath =
                    "/var/mobile/Library/Passes/Cards/\(cleanId)\(suffix)/\(leaf)"

                let removal = await removeWalletCacheFile(
                    pairingPath: pairingPath,
                    devicePath: devicePath
                )

                if !removal.removed && !removal.missing {
                    return (
                        false,
                        "Could not remove stale Wallet cache "
                        + "\(suffix)/\(leaf): "
                        + (removal.error ?? "unknown error")
                    )
                }
            }
        }

        let stageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "aircard_original_frontface_\(UUID().uuidString)",
                isDirectory: true
            )

        do {
            try FileManager.default.createDirectory(
                at: stageDirectory,
                withIntermediateDirectories: true
            )

            try originalContainer.write(
                to: stageDirectory.appendingPathComponent("FrontFace"),
                options: .atomic
            )
        } catch {
            try? FileManager.default.removeItem(at: stageDirectory)
            return (
                false,
                "Could not stage original FrontFace: "
                + error.localizedDescription
            )
        }

        defer {
            try? FileManager.default.removeItem(at: stageDirectory)
        }

        let targetDirectory =
            "/var/mobile/Library/Passes/Cards/"
            + "\(cleanId)\(manifest.cacheSuffix)"

        let write = await writeWalletDirectory(
            pairingPath: pairingPath,
            sourceDirectory: stageDirectory,
            targetDirectory: targetDirectory
        )

        guard write.ok else {
            return (
                false,
                "Could not restore original FrontFace cache: "
                + (write.error ?? "unknown write error")
            )
        }

        return (true, nil)
    }

    /// Extracts exactly FrontFace.faceImage.imageData from Wallet's NSKeyedArchiver
    /// payload. Wallet wraps the keyed archive in a small binary cache envelope, so we
    /// locate the bplist payload first. Public NSKeyedUnarchiver class substitution lets
    /// us decode the two fields we need without linking or instantiating private classes.
    ///
    /// Internal visibility is intentional so the test target can validate the decoder
    /// with a synthetic archive that uses the observed Wallet class names.
    nonisolated static func decodeRenderedWalletFrontFaceImageData(_ containerData: Data) -> Data? {
        let signature = Data("bplist00".utf8)
        guard let archiveRange = containerData.range(of: signature) else { return nil }
        let archiveData = containerData.subdata(in: archiveRange.lowerBound..<containerData.endIndex)

        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiveData)
            unarchiver.requiresSecureCoding = false
            unarchiver.setClass(AirCardArchivedPKImage.self, forClassName: "PKImage")
            unarchiver.setClass(AirCardArchivedFrontFaceImageSet.self, forClassName: "PKPassFrontFaceImageSet")
            // Keep a second observed-style alias available for OS/card-family variation.
            unarchiver.setClass(AirCardArchivedFrontFaceImageSet.self, forClassName: "PKPaymentPassFrontFaceImageSet")
            defer { unarchiver.finishDecoding() }

            guard let root = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
                    as? AirCardArchivedFrontFaceImageSet,
                  let imageData = root.faceImage?.imageData,
                  !imageData.isEmpty,
                  ImageEngine.safeImageFromData(imageData, maxDimension: 4096) != nil else {
                return nil
            }
            return imageData
        } catch {
            return nil
        }
    }

    /// Best-effort capture of Wallet's final rendered face. Failure or absence is
    /// non-fatal for immutable raw-artwork backup creation, but an unsafe move/write-back
    /// failure stops further rendered-cache probing and leaves recovery data intact.
    nonisolated static func captureRenderedWalletReference(
        cardId: String,
        pairingPath: String
    ) async -> WalletRenderedReferenceCaptureResult {
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId

        // Once captured, the original Wallet-rendered face is immutable.
        // A later custom-skin render must never replace the bank's original
        // FrontFace reference.
        if let existing =
            verifiedOriginalRenderedReferenceManifest(for: cleanId) {
            return .captured(existing)
        }

        // If a verified provider backup already exists but no verified
        // FrontFace exists, the card may already have been modified.
        // Do not accidentally label the current Wallet render as original.
        if validateOriginalArtworkBackup(for: cleanId).isValid {
            return .unavailable(
                attempted: 0,
                detail: "Original artwork backup already exists; refusing to replace the original FrontFace with the current Wallet render"
            )
        }

        var attempted = 0
        var lastDetail: String? = nil

        for candidate in renderedWalletCacheCandidates {
            attempted += 1
            let cacheDirectory = "/var/mobile/Library/Passes/Cards/\(cleanId)\(candidate.suffix)"
            let read = await readRenderedWalletCacheFileAndRestore(
                cardId: cleanId,
                cacheSuffix: candidate.suffix,
                leaf: candidate.leaf,
                pairingPath: pairingPath,
                targetDirectory: cacheDirectory
            )

            if read.sourceMissing { continue }

            if let error = read.error {
                return .unsafe(error: error)
            }

            guard let containerData = read.data else { continue }

            // Retain the raw cache envelope for diagnostics. It is never used as the
            // restore source and never replaces the immutable Originals backup.
            persistRenderedWalletRawDiagnostic(
                data: containerData,
                cardId: cleanId,
                cacheSuffix: candidate.suffix,
                leaf: candidate.leaf
            )

            guard let faceImageData = decodeRenderedWalletFrontFaceImageData(containerData),
                  let image = ImageEngine.safeImageFromData(faceImageData, maxDimension: 4096) else {
                lastDetail = "\(candidate.suffix)/\(candidate.leaf) existed (\(containerData.count) bytes) but contained no decodable FrontFace.faceImage"
                continue
            }

            // Preserve faceImage bytes as-is whenever Wallet stored PNG. If Apple ever
            // changes PKImage.imageData to another decodable format, normalize only that
            // future format to PNG so the on-disk reference path remains stable.
            let pngSignature = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
            let persistedData: Data
            let extractionPath: String
            if faceImageData.starts(with: pngSignature) {
                persistedData = faceImageData
                extractionPath = "NSKeyedArchive.faceImage.imageData"
            } else if let pngData = image.pngData() {
                persistedData = pngData
                extractionPath = "NSKeyedArchive.faceImage.imageData→PNG"
            } else {
                lastDetail = "\(candidate.suffix)/\(candidate.leaf) faceImage was decodable but could not be persisted"
                continue
            }

            guard let persistedImage = ImageEngine.safeImageFromData(persistedData, maxDimension: 4096) else {
                lastDetail = "Extracted FrontFace.faceImage failed post-extraction validation"
                continue
            }

            let width = persistedImage.cgImage?.width ?? Int(persistedImage.size.width * persistedImage.scale)
            let height = persistedImage.cgImage?.height ?? Int(persistedImage.size.height * persistedImage.scale)
            guard width > 0, height > 0 else {
                lastDetail = "Extracted FrontFace.faceImage had invalid dimensions"
                continue
            }

            let directory = renderedWalletReferenceDirectory(for: cleanId)
            let imageURL = renderedWalletReferenceImagePath(for: cleanId)
            let manifestURL = renderedWalletReferenceManifestPath(for: cleanId)
            let manifest = WalletRenderedReferenceManifest(
                version: 2,
                cardId: cleanId,
                capturedAt: Date(),
                cacheSuffix: candidate.suffix,
                leaf: candidate.leaf,
                byteCount: persistedData.count,
                sha256: renderedReferenceSHA256(persistedData),
                pixelWidth: width,
                pixelHeight: height,
                extractionPath: extractionPath,
                containerByteCount: containerData.count,
                containerSha256: renderedReferenceSHA256(containerData)
            )

            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try persistedData.write(to: imageURL, options: .atomic)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
                return .captured(manifest)
            } catch {
                return .unsafe(error: "FrontFace.faceImage was decoded but could not be persisted: \(error.localizedDescription)")
            }
        }

        return .unavailable(attempted: attempted, detail: lastDetail)
    }

    /// Reads one extensionless Wallet cache entry through the same move-based export
    /// primitive used elsewhere, but restores it to its original cache directory before
    /// returning any bytes to the caller.
    nonisolated private static func readRenderedWalletCacheFileAndRestore(
        cardId: String,
        cacheSuffix: String,
        leaf: String,
        pairingPath: String,
        targetDirectory: String
    ) async -> WalletRenderedCacheReadResult {
        let stageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aircard_rendered_probe_\(UUID().uuidString)", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: stageDirectory, withIntermediateDirectories: true)
        } catch {
            return .init(data: nil, sourceMissing: false, error: "Could not create rendered-reference staging: \(error.localizedDescription)")
        }

        var shouldDeleteStage = true
        defer {
            if shouldDeleteStage {
                try? FileManager.default.removeItem(at: stageDirectory)
            }
        }

        let exportedURL = stageDirectory.appendingPathComponent(leaf)
        let export = await exportRenderedWalletCacheFile(
            pairingPath: pairingPath,
            devicePath: "\(targetDirectory)/\(leaf)",
            outputPath: exportedURL.path
        )

        guard export.ok else {
            let missing = WalletSafety.classifyArtworkExportFailure(export.error) == .sourceMissing
            return .init(data: nil, sourceMissing: missing, error: missing ? nil : export.error)
        }

        let recoveryRoot = renderedWalletReferenceRecoveryDirectory(
            for: cardId,
            cacheSuffix: cacheSuffix,
            leaf: leaf
        )
        let recoveryFile = recoveryRoot.appendingPathComponent(leaf)

        do {
            try? FileManager.default.removeItem(at: recoveryRoot)
            try FileManager.default.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: exportedURL, to: recoveryFile)
        } catch {
            let emergency = await writeWalletDirectory(
                pairingPath: pairingPath,
                sourceDirectory: stageDirectory,
                targetDirectory: targetDirectory
            )
            if !emergency.ok {
                shouldDeleteStage = false
                return .init(
                    data: nil,
                    sourceMissing: false,
                    error: "Rendered cache \(cacheSuffix)/\(leaf) was moved but recovery creation and emergency write-back both failed. Staging retained at \(stageDirectory.path). \(emergency.error ?? "unknown write error")"
                )
            }
            return .init(
                data: nil,
                sourceMissing: false,
                error: "Rendered cache recovery copy could not be created; the Wallet cache entry was safely written back: \(error.localizedDescription)"
            )
        }

        var writeBack: (ok: Bool, error: String?) = (false, nil)
        for attempt in 0..<2 {
            writeBack = await writeWalletDirectory(
                pairingPath: pairingPath,
                sourceDirectory: recoveryRoot,
                targetDirectory: targetDirectory
            )
            if writeBack.ok { break }
            if attempt == 0 {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        guard writeBack.ok else {
            return .init(
                data: nil,
                sourceMissing: false,
                error: "Rendered cache \(cacheSuffix)/\(leaf) was read but could not be written back. Recovery retained at \(recoveryRoot.path). \(writeBack.error ?? "unknown write error")"
            )
        }

        guard let data = try? Data(contentsOf: exportedURL) else {
            try? FileManager.default.removeItem(at: recoveryRoot)
            return .init(
                data: nil,
                sourceMissing: false,
                error: "Rendered cache \(cacheSuffix)/\(leaf) was restored, but the local probe copy could not be read"
            )
        }

        try? FileManager.default.removeItem(at: recoveryRoot)
        return .init(data: data, sourceMissing: false, error: nil)
    }

    nonisolated private static func renderedWalletReferenceRecoveryDirectory(
        for cardId: String,
        cacheSuffix: String,
        leaf: String
    ) -> URL {
        let safeSuffix = cacheSuffix.replacingOccurrences(of: ".", with: "")
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WalletCards", isDirectory: true)
            .appendingPathComponent("RenderedReferenceRecovery", isDirectory: true)
            .appendingPathComponent(scannedCardSafeId(cardId), isDirectory: true)
            .appendingPathComponent("\(safeSuffix)-\(leaf)", isDirectory: true)
    }

    nonisolated private static func persistRenderedWalletRawDiagnostic(
        data: Data,
        cardId: String,
        cacheSuffix: String,
        leaf: String
    ) {
        let directory = renderedWalletReferenceDirectory(for: cardId)
            .appendingPathComponent("Raw", isDirectory: true)
        let safeSuffix = cacheSuffix.replacingOccurrences(of: ".", with: "")
        let url = directory.appendingPathComponent("\(safeSuffix)-\(leaf).bin")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            // Diagnostic persistence must never change scan/backup safety semantics.
        }
    }

    nonisolated private static func renderedReferenceSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func exportRenderedWalletCacheFile(
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
                            al_exploit_export_file(pairC, deviceC, outputC, nil, nil, &outError)
                        }
                    }
                }
                let error = outError.flatMap { String(validatingUTF8: $0) }
                if let pointer = outError { al_string_free(pointer) }
                continuation.resume(returning: (rc == 0, error))
            }
        }
    }
}
