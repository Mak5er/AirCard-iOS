//
//  TendiesEngine.swift
//  AirCard-iOS
//
//  Engine for parsing, extracting, and flashing PosterBoard .tendies wallpapers.
//

import UIKit
import Foundation
import AirliftFFI

public final class TendiesEngine {
    public static let shared = TendiesEngine()

    public static var tendiesStorageDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Tendies", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // MARK: - Import & Parse

    public func importTendie(from sourceURL: URL) async throws -> TendieItem {
        let isSecurityScoped = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileName = sourceURL.lastPathComponent
        let baseName = (fileName as NSString).deletingPathExtension
        let destinationURL = Self.tendiesStorageDirectory.appendingPathComponent(fileName)

        if sourceURL.standardizedFileURL.path != destinationURL.standardizedFileURL.path {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try? FileManager.default.removeItem(at: destinationURL)
            }
            do {
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            } catch {
                let fileData = try Data(contentsOf: sourceURL)
                try fileData.write(to: destinationURL, options: .atomic)
            }
        }

        guard FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw NSError(
                domain: "TendiesEngine",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to store wallpaper file at \(destinationURL.path)"]
            )
        }

        // Staging extraction to inspect contents
        let tempExtractDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tendie_inspect_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempExtractDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempExtractDir)
        }

        let extractRC = destinationURL.path.withCString { arcC in
            tempExtractDir.path.withCString { dstC in
                al_zip_extract_all(arcC, dstC)
            }
        }

        guard extractRC == 0 else {
            throw NSError(
                domain: "TendiesEngine",
                code: Int(extractRC),
                userInfo: [NSLocalizedDescriptionKey: "Failed to extract .tendies zip archive (code \(extractRC))"]
            )
        }

        // Analyze file structure
        var isContainer = false
        var unsafeContainer = false
        var descriptorCount = 0
        var posterType: TendiePosterType = .collections

        let fileManager = FileManager.default
        let enumerator = fileManager.enumerator(
            at: tempExtractDir,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        var candidateImages: [(url: URL, score: Int)] = []

        while let itemURL = enumerator?.nextObject() as? URL {
            let pathLower = itemURL.path.lowercased()
            let nameLower = itemURL.lastPathComponent.lowercased()

            if pathLower.contains("__macosx") || nameLower == ".ds_store" {
                continue
            }

            if pathLower.contains("/container/") || pathLower.hasSuffix("/container") {
                isContainer = true
                posterType = .container
                if nameLower.contains("pbfposterextensiondatastoresqlitedatabase.sqlite3") {
                    unsafeContainer = true
                }
            }

            if pathLower.contains("descriptor") || pathLower.contains("descriptors") {
                if pathLower.contains("video") || pathLower.contains("photos") {
                    posterType = .suggestedPhotos
                } else if pathLower.contains("mercury") {
                    posterType = .mercury
                } else if posterType != .container {
                    posterType = .collections
                }
            }

            // Count descriptors by finding .wallpaper or sub-descriptor folders
            if nameLower.hasSuffix(".wallpaper") || nameLower == "wallpaper.plist" {
                descriptorCount += 1
            }

            // Image discovery
            let ext = itemURL.pathExtension.lowercased()
            if ["heic", "png", "jpg", "jpeg"].contains(ext) {
                var score = 10
                if pathLower.contains("proxy") || pathLower.contains("adjusted") {
                    score += 90
                } else if pathLower.contains("background") || pathLower.contains("settling") {
                    score += 70
                } else if pathLower.contains("preview") || pathLower.contains("thumb") {
                    score += 50
                } else if pathLower.contains("asset.resource") {
                    score += 40
                }
                candidateImages.append((itemURL, score))
            }
        }

        if descriptorCount == 0 {
            descriptorCount = 1
        }

        // Pick best preview image
        candidateImages.sort { $0.score > $1.score }
        var previewData: Data? = nil

        for candidate in candidateImages {
            if let img = UIImage(contentsOfFile: candidate.url.path) {
                let thumb = self.downsample(image: img, maxDimension: 600)
                if let jpeg = thumb.jpegData(compressionQuality: 0.85) {
                    previewData = jpeg
                    break
                }
            }
        }

        return TendieItem(
            name: baseName,
            fileName: fileName,
            relativePath: fileName,
            isContainer: isContainer,
            unsafeContainer: unsafeContainer,
            descriptorCount: descriptorCount,
            posterType: posterType,
            previewImageData: previewData,
            dateImported: Date(),
            isSelected: true
        )
    }

    // MARK: - Downsample Thumbnail

    private func downsample(image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let maxSide = max(size.width, size.height)
        guard maxSide > maxDimension else { return image }

        let scale = maxDimension / maxSide
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    // MARK: - Send Respring Signal via Tunnel

    public func sendRespringSignal(pairingPath: String) async -> Bool {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var outError: UnsafeMutablePointer<CChar>? = nil
                let rc = pairingPath.withCString { pC in
                    al_device_respring(pC, nil, nil, &outError)
                }
                if let p = outError {
                    al_string_free(p)
                }
                continuation.resume(returning: rc == 0)
            }
        }
    }

    // MARK: - Flash Tendies to Device

    @MainActor
    public func flashTendies(
        items: [TendieItem],
        pairingPath: String,
        log: @escaping (String) -> Void,
        progress: @escaping (Double) -> Void
    ) async throws {
        guard !items.isEmpty else {
            log("⚠️ No wallpapers selected to flash")
            return
        }

        let transport = TendiesTemplateTransport(pairingPath: pairingPath, log: log)
        let device = try await transport.context()
        let manager = TemplateManager(store: TendiesTemplateTransport.store, transport: transport, log: log)
        var installedIDs = Set<String>()
        log("Target: \(device.name) · \(device.model) · \(device.udid)")

        let totalItems = Double(items.count)

        for (itemIndex, item) in items.enumerated() {
            log("\n📦 [\(itemIndex + 1)/\(items.count)] Processing '\(item.name)'…")

            let tempStageDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("tendie_flash_\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tempStageDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: tempStageDir)
            }

            let extractRC = item.fileURL.path.withCString { arcC in
                tempStageDir.path.withCString { dstC in
                    al_zip_extract_all(arcC, dstC)
                }
            }
            guard extractRC == 0 else {
                throw TemplateFailure(message: "Failed to extract \(item.name); no success was recorded.")
            }

            log("  🖼 Locating wallpaper descriptors…")
            let descriptors = findDescriptorsWithExtensions(in: tempStageDir, defaultExt: item.posterType.extensionBundleId)
            guard !descriptors.isEmpty else {
                throw TemplateFailure(message: "No wallpaper descriptors found in \(item.name).")
            }
            log("  ✨ Found \(descriptors.count) descriptor(s) to install")

            for (descIndex, descItem) in descriptors.enumerated() {
                let targetUUID = UUID().uuidString.uppercased()
                let randomizedID = Int.random(in: 10000...99999)
                log("  [\(descIndex + 1)/\(descriptors.count)] Descriptor \(targetUUID) (ID: \(randomizedID)) for \(descItem.ext)…")

                // Update plist identifiers to ensure unique indexing without collisions
                try DescriptorPreparation.prepare(in: descItem.url, randomizedID: randomizedID)

                let record = TemplateInstallation.make(
                    name: item.name, fileName: item.fileName,
                    device: device, descriptorID: targetUUID, numericID: randomizedID, provider: descItem.ext)
                try await manager.stage(record, folder: descItem.url)
                installedIDs.insert(record.id)
            }

            progress(Double(itemIndex + 1) / (totalItems + 1))
        }

        try await manager.finishInstalls(installedIDs)
        progress(1.0)
        log("Templates written and refresh prepared. NeoSpring will apply the changes.")
    }

    // The original AirCard refresh payload and both destinations are shared by
    // installation and removal. No preference snapshots or rollback stack.
    func refreshPosterBoard(
        containerPath: String, pairingPath: String,
        log: @escaping (String) -> Void
    ) async throws {
        let normalizedContainer = containerPath
        // Always force PosterBoard cache refresh and file protections reset
        log("\n🔄 Forcing PosterBoard cache refresh and file protections reset…")
        let stagePrefDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tendie_pref_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stagePrefDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: stagePrefDir)
        }

        let prefPlistURL = stagePrefDir.appendingPathComponent("com.apple.PosterBoard.unprotectedUserDefaults.plist")
        let prefDict: [String: Any] = [
            "PBF_RESET_FILE_PROTECTIONS": true,
            "PBF_LOCALE_DID_CHANGE": false,
            "PersistedPosterContainerBundleIdentifiers": [
                "com.apple.Posters.CollectionsPosterApp",
                "com.apple.WallpaperKit.CollectionsPoster"
            ],
            "CompletedPosterBundleIdentifierMigrations": [
                "com.apple.Posters.UnityPosterApp.ExtragalacticPoster",
                "com.apple.Posters.WeatherPosterApp.WeatherPoster",
                "com.apple.Posters.UnityPosterApp.Unity2025Poster",
                "com.apple.Posters.UnityPosterApp.UnityPosterExtension",
                "com.apple.Posters.UnityPosterApp.RhizomePoster",
                "com.apple.Posters.KaleidoscopePosterApp.KaleidoscopePoster"
            ]
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: prefDict, format: .binary, options: 0)
        try plistData.write(to: prefPlistURL)

        let targetPrefDir = "\(normalizedContainer)/Library/Preferences"
        try await writeDirectoryTree(
            sourceBaseDir: stagePrefDir,
            targetBaseDir: targetPrefDir,
            pairingPath: pairingPath,
            log: log
        )

        // Also write to mobile global preferences for system daemon lookup
        let mobilePrefDir = "/var/mobile/Library/Preferences"
        try? await writeDirectoryTree(
            sourceBaseDir: stagePrefDir,
            targetBaseDir: mobilePrefDir,
            pairingPath: pairingPath,
            log: log
        )
        log("✅ PosterBoard preferences staged for reload")

    }

    // MARK: - Tree Writer Helper

    private func writeDirectoryTree(
        sourceBaseDir: URL,
        targetBaseDir: String,
        pairingPath: String,
        log: @escaping (String) -> Void
    ) async throws {
        let fileManager = FileManager.default

        // Gather all directories that contain files
        var dirsToWrite: Set<URL> = []
        if let enumerator = fileManager.enumerator(
            at: sourceBaseDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            while let itemURL = enumerator.nextObject() as? URL {
                let isDir = (try? itemURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if !isDir {
                    dirsToWrite.insert(itemURL.deletingLastPathComponent())
                }
            }
        }

        // If no subfiles, write the source dir itself if not empty
        if dirsToWrite.isEmpty {
            let files = (try? fileManager.contentsOfDirectory(atPath: sourceBaseDir.path)) ?? []
            if !files.isEmpty {
                dirsToWrite.insert(sourceBaseDir)
            }
        }

        let canonicalSource = sourceBaseDir.resolvingSymlinksInPath().path

        for dir in dirsToWrite {
            let canonicalDir = dir.resolvingSymlinksInPath().path
            var relPath = ""
            if canonicalDir.hasPrefix(canonicalSource) {
                relPath = String(canonicalDir.dropFirst(canonicalSource.count))
                relPath = relPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }

            let targetDir: String
            if relPath.isEmpty {
                targetDir = targetBaseDir
            } else {
                targetDir = "\(targetBaseDir)/\(relPath)"
            }

            log("  Writing to \(targetDir)…")

            var writeOk = false
            var errDesc: String? = nil

            await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    var outError: UnsafeMutablePointer<CChar>? = nil
                    let rc = pairingPath.withCString { pairC in
                        dir.path.withCString { srcC in
                            targetDir.withCString { tgtC in
                                al_exploit_write_dir(pairC, srcC, tgtC, { _, msg in
                                    guard let msg = msg else { return }
                                    let line = String(cString: msg)
                                    DispatchQueue.main.async {
                                        AppViewModel.shared?.tendiesFlashLog.append("    " + line)
                                    }
                                }, nil, &outError)
                            }
                        }
                    }
                    if let p = outError {
                        errDesc = String(cString: p)
                        al_string_free(p)
                    }
                    writeOk = (rc == 0)
                    cont.resume()
                }
            }

            if !writeOk {
                throw NSError(
                    domain: "TendiesEngine",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to write directory: \(errDesc ?? "exploit error")"]
                )
            }
        }
    }

    // MARK: - Find Descriptors With Targeted Extensions

    private func findDescriptorsWithExtensions(in rootURL: URL, defaultExt: String) -> [(ext: String, url: URL)] {
        let fileManager = FileManager.default
        var results: [(ext: String, url: URL)] = []

        // 1. Check for standard container structure
        let containerFolder = rootURL.appendingPathComponent("container")
        let searchRoots = fileManager.fileExists(atPath: containerFolder.path) ? [containerFolder, rootURL] : [rootURL]

        for sRoot in searchRoots {
            let extensionsDir = sRoot.appendingPathComponent("Library/Application Support/PRBPosterExtensionDataStore/61/Extensions")
            if fileManager.fileExists(atPath: extensionsDir.path) {
                if let extEntries = try? fileManager.contentsOfDirectory(at: extensionsDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                    for extFolder in extEntries {
                        let descDir = extFolder.appendingPathComponent("descriptors")
                        if fileManager.fileExists(atPath: descDir.path),
                           let descEntries = try? fileManager.contentsOfDirectory(at: descDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                            for d in descEntries where (try? d.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false {
                                if !d.lastPathComponent.hasPrefix(".") && d.lastPathComponent != "__MACOSX" {
                                    results.append((ext: extFolder.lastPathComponent, url: d))
                                }
                            }
                        }
                    }
                }
            }
        }
        if !results.isEmpty {
            return results
        }

        // 2. Check for "descriptors" or "descriptor" folder
        for folderName in ["descriptors", "descriptor", "ordered-descriptors", "ordered-descriptor"] {
            let descDir = rootURL.appendingPathComponent(folderName)
            if fileManager.fileExists(atPath: descDir.path),
               let contents = try? fileManager.contentsOfDirectory(at: descDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for d in contents where (try? d.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false {
                    if !d.lastPathComponent.hasPrefix(".") && d.lastPathComponent != "__MACOSX" {
                        results.append((ext: defaultExt, url: d))
                    }
                }
            }
        }
        if !results.isEmpty {
            return results
        }

        // 3. Check for "video-descriptors" or "video-descriptor"
        for folderName in ["video-descriptors", "video-descriptor"] {
            let descDir = rootURL.appendingPathComponent(folderName)
            if fileManager.fileExists(atPath: descDir.path),
               let contents = try? fileManager.contentsOfDirectory(at: descDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for d in contents where (try? d.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false {
                    if !d.lastPathComponent.hasPrefix(".") && d.lastPathComponent != "__MACOSX" {
                        results.append((ext: "com.apple.PhotosUIPrivate.PhotosPosterProvider", url: d))
                    }
                }
            }
        }
        if !results.isEmpty {
            return results
        }

        // 4. Check if root contains versions or Wallpaper.plist
        if fileManager.fileExists(atPath: rootURL.appendingPathComponent("versions").path) ||
           fileManager.fileExists(atPath: rootURL.appendingPathComponent("Wallpaper.plist").path) ||
           fileManager.fileExists(atPath: rootURL.appendingPathComponent("com.apple.posterkit.provider.descriptor.identifier").path) {
            return [(ext: defaultExt, url: rootURL)]
        }

        // 5. Fallback: scan any subfolder with "versions" or UUID name
        if let topLevel = try? fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for sub in topLevel where (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false {
                if !sub.lastPathComponent.hasPrefix(".") && sub.lastPathComponent != "__MACOSX" {
                    let hasVersions = fileManager.fileExists(atPath: sub.appendingPathComponent("versions").path)
                    let isUUID = UUID(uuidString: sub.lastPathComponent) != nil
                    if hasVersions || isUUID {
                        results.append((ext: defaultExt, url: sub))
                    }
                }
            }
        }

        return results.isEmpty ? [(ext: defaultExt, url: rootURL)] : results
    }
}
