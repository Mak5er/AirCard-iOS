import Foundation
import UIKit
import AirliftFFI

private let scannedWalletPreviewCache = NSCache<NSString, UIImage>()
private let scannedWalletLogoCache = NSCache<NSString, UIImage>()

struct WalletCardMetadata: Codable, Equatable, Sendable {
    let organizationName: String?
    let cardDescription: String?
    let logoText: String?
    let passTypeIdentifier: String?
    let serialNumber: String?

    var displayName: String? {
        for value in [logoText, cardDescription, organizationName] {
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return value
            }
        }
        return nil
    }

    var secondaryName: String? {
        guard let organizationName, organizationName != displayName else { return nil }
        return organizationName
    }
}

extension AppViewModel {
    /// Display candidates only. These are deliberately separate from the immutable
    /// original-artwork backup used by Restore Original.
    nonisolated static let scannedCardPreviewCandidates: [String] = [
        "cardBackgroundCombined@3x.png",
        "cardBackgroundCombined@2x.png",
        "background@3x.png",
        "background@2x.png",
        "diffuse@3x.png",
        "diffuse@2x.png",
        "strip@3x.png",
        "strip@2x.png",
        "cardBackgroundCombined.pdf",
        "background.pdf",
        "strip.pdf"
    ]

    nonisolated static let scannedCardLogoCandidates: [String] = [
        "logo@3x.png",
        "logo@2x.png",
        "logo.png",
        "icon@3x.png",
        "icon@2x.png",
        "icon.png"
    ]

    nonisolated static func scannedCardSafeId(_ cardId: String) -> String {
        (CardItem.cleanCardId(cardId) ?? cardId)
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
    }

    nonisolated static func scannedCardPreviewPath(for cardId: String) -> URL {
        walletCardsDirectory()
            .appendingPathComponent("ScanPreviews", isDirectory: true)
            .appendingPathComponent("card_\(scannedCardSafeId(cardId)).png")
    }

    nonisolated static func scannedCardLogoPath(for cardId: String) -> URL {
        walletCardsDirectory()
            .appendingPathComponent("ScanLogos", isDirectory: true)
            .appendingPathComponent("logo_\(scannedCardSafeId(cardId)).png")
    }

    nonisolated static func scannedCardMetadataPath(for cardId: String) -> URL {
        walletCardsDirectory()
            .appendingPathComponent("ScanMetadata", isDirectory: true)
            .appendingPathComponent("meta_\(scannedCardSafeId(cardId)).json")
    }

    nonisolated static func scannedCardCaptureMarkerPath(for cardId: String) -> URL {
        walletCardsDirectory()
            .appendingPathComponent("ScanMetadata", isDirectory: true)
            .appendingPathComponent("capture_\(scannedCardSafeId(cardId)).complete")
    }

    nonisolated static func scannedCardRecoveryDirectory(for cardId: String) -> URL {
        walletCardsDirectory()
            .appendingPathComponent("ScanRecovery", isDirectory: true)
            .appendingPathComponent(scannedCardSafeId(cardId), isDirectory: true)
    }

    nonisolated private static func walletCardsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WalletCards", isDirectory: true)
    }

    nonisolated static func scannedCardPreviewImage(for cardId: String) -> UIImage? {
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId
        let cacheKey = cleanId as NSString
        if let cached = scannedWalletPreviewCache.object(forKey: cacheKey) {
            return cached
        }

        let previewURL = scannedCardPreviewPath(for: cleanId)
        if let data = try? Data(contentsOf: previewURL),
           let image = ImageEngine.safeImageFromData(data, maxDimension: 1024) {
            scannedWalletPreviewCache.setObject(image, forKey: cacheKey)
            return image
        }

        // A verified immutable backup is a trustworthy preview source for cards that
        // were backed up before the scan-preview feature existed.
        let backupDir = originalArtworkBackupDirectory(for: cleanId)
        if validateOriginalArtworkBackup(for: cleanId).isValid {
            for leaf in scannedCardPreviewCandidates {
                let url = backupDir.appendingPathComponent(leaf)
                guard let data = try? Data(contentsOf: url) else { continue }
                if let image = decodeScannedCardPreview(data: data, filename: leaf) {
                    scannedWalletPreviewCache.setObject(image, forKey: cacheKey)
                    return image
                }
            }
        }

        return nil
    }

    nonisolated static func scannedCardLogoImage(for cardId: String) -> UIImage? {
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId
        let key = cleanId as NSString
        if let cached = scannedWalletLogoCache.object(forKey: key) { return cached }

        let url = scannedCardLogoPath(for: cleanId)
        guard let data = try? Data(contentsOf: url),
              let image = ImageEngine.safeImageFromData(data, maxDimension: 512) else {
            return nil
        }
        scannedWalletLogoCache.setObject(image, forKey: key)
        return image
    }

    nonisolated static func scannedCardMetadata(for cardId: String) -> WalletCardMetadata? {
        let url = scannedCardMetadataPath(for: cardId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WalletCardMetadata.self, from: data)
    }

    nonisolated static func removeScannedCardPreview(for cardId: String) {
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId
        scannedWalletPreviewCache.removeObject(forKey: cleanId as NSString)
        scannedWalletLogoCache.removeObject(forKey: cleanId as NSString)
        try? FileManager.default.removeItem(at: scannedCardPreviewPath(for: cleanId))
        try? FileManager.default.removeItem(at: scannedCardLogoPath(for: cleanId))
        try? FileManager.default.removeItem(at: scannedCardMetadataPath(for: cleanId))
        try? FileManager.default.removeItem(at: scannedCardCaptureMarkerPath(for: cleanId))
        try? FileManager.default.removeItem(at: scannedCardRecoveryDirectory(for: cleanId))
    }

    nonisolated static func removeAllScannedCardPreviews() {
        scannedWalletPreviewCache.removeAllObjects()
        scannedWalletLogoCache.removeAllObjects()
        let cardsDir = walletCardsDirectory()
        for leaf in ["ScanPreviews", "ScanLogos", "ScanMetadata", "ScanRecovery"] {
            try? FileManager.default.removeItem(at: cardsDir.appendingPathComponent(leaf, isDirectory: true))
        }
    }

    func refreshScannedCardPreview(for cardId: String) {
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId
        scannedWalletPreviewCache.removeObject(forKey: cleanId as NSString)
        scannedWalletLogoCache.removeObject(forKey: cleanId as NSString)
        try? FileManager.default.removeItem(at: Self.scannedCardPreviewPath(for: cleanId))
        try? FileManager.default.removeItem(at: Self.scannedCardLogoPath(for: cleanId))
        try? FileManager.default.removeItem(at: Self.scannedCardMetadataPath(for: cleanId))
        try? FileManager.default.removeItem(at: Self.scannedCardCaptureMarkerPath(for: cleanId))
        captureScannedCardPreviewIfNeeded(for: cleanId, force: true)
    }

    /// Captures display-only current Wallet artwork, logo and safe identity metadata.
    ///
    /// IMPORTANT: scanning does NOT create the immutable Restore Original backup.
    /// The authoritative original backup is still created immediately before the
    /// first AirCard skin write. This prevents an already-customized legacy card from
    /// being silently labelled as provider-original merely because it was scanned.
    func captureScannedCardPreviewIfNeeded(for cardId: String, force: Bool = false) {
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId

        if !force,
           Self.scannedCardPreviewImage(for: cleanId) != nil,
           FileManager.default.fileExists(atPath: Self.scannedCardCaptureMarkerPath(for: cleanId).path) {
            objectWillChange.send()
            return
        }

        guard hasPairingFile else { return }
        let pairingPath = PairingController.pairingFilePath()
        scanStatusText = "Found card: \(cleanId.prefix(12))… Loading Wallet artwork…"
        WalletCardOperationStore.shared.set(.scanning("Loading Wallet artwork and logo…"), for: cleanId)

        Task.detached(priority: .userInitiated) { [weak self] in
            // Allow the Wallet selection/syslog event to settle before opening services.
            try? await Task.sleep(nanoseconds: 350_000_000)

            let result = await Self.captureScannedCardIdentity(
                cardId: cleanId,
                pairingPath: pairingPath
            )

            await MainActor.run {
                guard let self else { return }
                if result.previewLoaded {
                    self.scanStatusText = "Found card: \(cleanId.prefix(12))… Artwork loaded ✅"
                    var detail = "Artwork loaded"
                    if result.logoLoaded { detail += " · logo" }
                    if result.metadataLoaded { detail += " · card name" }
                    WalletCardOperationStore.shared.set(.ready("\(detail) ✅"), for: cleanId)
                    self.log.append(
                        "🖼️ Loaded Wallet preview for \(cleanId.prefix(12))… " +
                        "(logo=\(result.logoLoaded), metadata=\(result.metadataLoaded))"
                    )
                } else {
                    self.scanStatusText = "Found card: \(cleanId.prefix(12))… Preview unavailable"
                    WalletCardOperationStore.shared.set(.failed("Wallet preview unavailable"), for: cleanId)
                    if let error = result.error {
                        self.log.append("⚠️ Card preview unavailable for \(cleanId.prefix(12)): \(error)")
                    }
                }
                self.objectWillChange.send()
            }
        }
    }

    private struct ScannedIdentityResult: Sendable {
        let previewLoaded: Bool
        let logoLoaded: Bool
        let metadataLoaded: Bool
        let error: String?
    }

    nonisolated private static func captureScannedCardIdentity(
        cardId: String,
        pairingPath: String
    ) async -> ScannedIdentityResult {
        let cleanId = CardItem.cleanCardId(cardId) ?? cardId
        let targetDir = "/var/mobile/Library/Passes/Cards/\(cleanId).pkpass"

        let repair = await repairPendingScannedRecovery(
            cardId: cleanId,
            pairingPath: pairingPath,
            targetDirectory: targetDir
        )
        guard repair.ok else {
            return ScannedIdentityResult(
                previewLoaded: false,
                logoLoaded: false,
                metadataLoaded: false,
                error: repair.error
            )
        }

        var previewLoaded = false
        var logoLoaded = false
        var metadataLoaded = false
        var firstError: String? = nil

        for leaf in scannedCardPreviewCandidates {
            let read = await readWalletFileAndRestore(
                cardId: cleanId,
                leaf: leaf,
                pairingPath: pairingPath,
                targetDirectory: targetDir
            )
            if let error = read.error, firstError == nil { firstError = error }
            guard let data = read.data else {
                if read.sourceMissing { continue }
                break
            }
            guard let image = decodeScannedCardPreview(data: data, filename: leaf),
                  let pngData = ImageEngine.normalizeAndDownsample(image, maxDimension: 1024).pngData() else {
                continue
            }
            do {
                let previewURL = scannedCardPreviewPath(for: cleanId)
                try FileManager.default.createDirectory(
                    at: previewURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try pngData.write(to: previewURL, options: .atomic)
                scannedWalletPreviewCache.setObject(image, forKey: cleanId as NSString)
                previewLoaded = true
            } catch {
                firstError = "Could not save card preview: \(error.localizedDescription)"
            }
            break
        }

        // Standard Wallet passes expose these fields in pass.json. Some payment-card
        // bundles do not, so failure to find pass.json is expected and non-fatal.
        let metadataRead = await readWalletFileAndRestore(
            cardId: cleanId,
            leaf: "pass.json",
            pairingPath: pairingPath,
            targetDirectory: targetDir
        )
        if let data = metadataRead.data, let metadata = parseWalletCardMetadata(data) {
            do {
                let url = scannedCardMetadataPath(for: cleanId)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try JSONEncoder().encode(metadata).write(to: url, options: .atomic)
                metadataLoaded = true
            } catch {
                if firstError == nil {
                    firstError = "Could not save Wallet metadata: \(error.localizedDescription)"
                }
            }
        } else if let error = metadataRead.error, firstError == nil, !metadataRead.sourceMissing {
            firstError = error
        }

        for leaf in scannedCardLogoCandidates {
            let read = await readWalletFileAndRestore(
                cardId: cleanId,
                leaf: leaf,
                pairingPath: pairingPath,
                targetDirectory: targetDir
            )
            if let error = read.error, firstError == nil, !read.sourceMissing {
                firstError = error
            }
            guard let data = read.data else {
                if read.sourceMissing { continue }
                break
            }
            guard let image = ImageEngine.safeImageFromData(data, maxDimension: 512),
                  let pngData = ImageEngine.normalizeAndDownsample(image, maxDimension: 512).pngData() else {
                continue
            }
            do {
                let url = scannedCardLogoPath(for: cleanId)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try pngData.write(to: url, options: .atomic)
                scannedWalletLogoCache.setObject(image, forKey: cleanId as NSString)
                logoLoaded = true
            } catch {
                if firstError == nil {
                    firstError = "Could not save Wallet logo: \(error.localizedDescription)"
                }
            }
            break
        }

        if previewLoaded {
            let marker = scannedCardCaptureMarkerPath(for: cleanId)
            try? FileManager.default.createDirectory(
                at: marker.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? Data("ok\n".utf8).write(to: marker, options: .atomic)
        }

        return ScannedIdentityResult(
            previewLoaded: previewLoaded,
            logoLoaded: logoLoaded,
            metadataLoaded: metadataLoaded,
            error: firstError
        )
    }

    nonisolated private static func repairPendingScannedRecovery(
        cardId: String,
        pairingPath: String,
        targetDirectory: String
    ) async -> (ok: Bool, error: String?) {
        let recoveryDir = scannedCardRecoveryDirectory(for: cardId)
        guard FileManager.default.fileExists(atPath: recoveryDir.path) else { return (true, nil) }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: recoveryDir.path)) ?? []
        guard !contents.isEmpty else {
            try? FileManager.default.removeItem(at: recoveryDir)
            return (true, nil)
        }

        let repair = await writeWalletDirectory(
            pairingPath: pairingPath,
            sourceDirectory: recoveryDir,
            targetDirectory: targetDirectory
        )
        if repair.ok {
            try? FileManager.default.removeItem(at: recoveryDir)
            return (true, nil)
        }
        return (
            false,
            "Pending scan recovery could not be restored: \(repair.error ?? "unknown write error")"
        )
    }

    private struct WalletFileReadResult: Sendable {
        let data: Data?
        let sourceMissing: Bool
        let error: String?
    }

    /// Reads one Wallet file through the move-based export primitive and restores the
    /// exact bytes before returning them to the caller. A persistent recovery copy is
    /// created before write-back. No local staging file is discarded while it is the
    /// only surviving copy of a successfully exported Wallet file.
    nonisolated private static func readWalletFileAndRestore(
        cardId: String,
        leaf: String,
        pairingPath: String,
        targetDirectory: String
    ) async -> WalletFileReadResult {
        let stageDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aircard_scan_read_\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
        } catch {
            return WalletFileReadResult(data: nil, sourceMissing: false, error: error.localizedDescription)
        }

        var shouldDeleteStage = true
        defer {
            if shouldDeleteStage {
                try? FileManager.default.removeItem(at: stageDir)
            }
        }

        let exportedURL = stageDir.appendingPathComponent(leaf)
        let export = await exportScannedPreviewFile(
            pairingPath: pairingPath,
            devicePath: "\(targetDirectory)/\(leaf)",
            outputPath: exportedURL.path
        )
        guard export.ok else {
            let missing = WalletSafety.classifyArtworkExportFailure(export.error) == .sourceMissing
            return WalletFileReadResult(
                data: nil,
                sourceMissing: missing,
                error: missing ? nil : export.error
            )
        }

        // A successful export is destructive at the source. First create the persistent
        // recovery copy. If that fails, restore directly from staging before returning.
        let recoveryDir = scannedCardRecoveryDirectory(for: cardId)
        do {
            try? FileManager.default.removeItem(at: recoveryDir)
            try FileManager.default.createDirectory(at: recoveryDir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: exportedURL,
                to: recoveryDir.appendingPathComponent(leaf)
            )
        } catch {
            let emergency = await writeWalletDirectory(
                pairingPath: pairingPath,
                sourceDirectory: stageDir,
                targetDirectory: targetDirectory
            )
            if !emergency.ok {
                // Do not delete the only known surviving local copy. It may remain in
                // tmp if persistent storage itself is unavailable; expose its path.
                shouldDeleteStage = false
                return WalletFileReadResult(
                    data: nil,
                    sourceMissing: false,
                    error: "Could not create scan recovery copy and emergency write-back failed. " +
                           "Retained staging at \(stageDir.path). \(emergency.error ?? "unknown write error")"
                )
            }
            return WalletFileReadResult(
                data: nil,
                sourceMissing: false,
                error: "Could not create scan recovery copy; Wallet file was safely written back: " +
                       error.localizedDescription
            )
        }

        var writeBack: (ok: Bool, error: String?) = (false, nil)
        for attempt in 0..<2 {
            writeBack = await writeWalletDirectory(
                pairingPath: pairingPath,
                sourceDirectory: recoveryDir,
                targetDirectory: targetDirectory
            )
            if writeBack.ok { break }
            if attempt == 0 {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }

        guard writeBack.ok else {
            // Recovery directory remains discoverable in Recovery Diagnostics.
            return WalletFileReadResult(
                data: nil,
                sourceMissing: false,
                error: "Wallet \(leaf) was read but could not be written back. " +
                       "Recovery copy retained: \(writeBack.error ?? "unknown write error")"
            )
        }

        // Source has now been restored. Local decoding failure can no longer damage Wallet.
        guard let data = try? Data(contentsOf: exportedURL) else {
            try? FileManager.default.removeItem(at: recoveryDir)
            return WalletFileReadResult(
                data: nil,
                sourceMissing: false,
                error: "Wallet \(leaf) was restored but its local preview copy could not be read"
            )
        }

        try? FileManager.default.removeItem(at: recoveryDir)
        return WalletFileReadResult(data: data, sourceMissing: false, error: nil)
    }

    nonisolated private static func exportScannedPreviewFile(
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

    nonisolated private static func parseWalletCardMetadata(_ data: Data) -> WalletCardMetadata? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        func firstString(_ keys: [String]) -> String? {
            for key in keys {
                if let value = json[key] as? String {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                }
            }
            return nil
        }

        let metadata = WalletCardMetadata(
            organizationName: firstString(["organizationName", "issuerName", "issuer", "bankName"]),
            cardDescription: firstString([
                "description", "localizedDescription", "displayName", "productName", "cardName"
            ]),
            logoText: firstString(["logoText"]),
            passTypeIdentifier: firstString(["passTypeIdentifier"]),
            serialNumber: firstString(["serialNumber"])
        )

        if metadata.organizationName == nil,
           metadata.cardDescription == nil,
           metadata.logoText == nil,
           metadata.passTypeIdentifier == nil {
            return nil
        }
        return metadata
    }

    nonisolated static func decodeScannedCardPreview(data: Data, filename: String) -> UIImage? {
        if filename.lowercased().hasSuffix(".pdf") {
            return renderScannedCardPDF(data)
        }
        return ImageEngine.safeImageFromData(data, maxDimension: 1536)
    }

    nonisolated private static func renderScannedCardPDF(_ data: Data) -> UIImage? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else {
            return nil
        }

        let mediaBox = page.getBoxRect(.mediaBox)
        guard mediaBox.width > 0, mediaBox.height > 0 else { return nil }

        let maxDimension: CGFloat = 1536
        let scale = min(maxDimension / mediaBox.width, maxDimension / mediaBox.height)
        let size = CGSize(
            width: max(1, mediaBox.width * scale),
            height: max(1, mediaBox.height * scale)
        )

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.saveGState()
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: scale, y: -scale)
            context.cgContext.drawPDFPage(page)
            context.cgContext.restoreGState()
        }
    }
}
