import XCTest
@testable import AirCard_iOS

final class TendiesEngineTests: XCTestCase {

    func testInspectTendiesDescriptorDiscovery() throws {
        let inspectURL = URL(fileURLWithPath: "/tmp/inspect_tendies")
        guard FileManager.default.fileExists(atPath: inspectURL.path) else {
            throw XCTSkip("/tmp/inspect_tendies does not exist on this machine")
        }

        let engine = TendiesEngine.shared
        let descriptors = engine.findDescriptorsWithExtensions(in: inspectURL, defaultExt: "com.apple.WallpaperKit.CollectionsPoster")

        XCTAssertEqual(descriptors.count, 4, "iPhone 18 Pro.tendies should contain exactly 4 descriptors")

        for desc in descriptors {
            XCTAssertEqual(desc.ext, "com.apple.MercuryPoster")
            XCTAssertTrue(engine.isDescriptorFolder(desc.url))
            let ext = engine.determineExtension(for: desc.url, defaultExt: "com.apple.WallpaperKit.CollectionsPoster")
            XCTAssertEqual(ext, "com.apple.MercuryPoster")
        }

        let folderNames = Set(descriptors.map { $0.url.lastPathComponent })
        XCTAssertTrue(folderNames.contains("C127E8D0-67E8-4B32-9154-F6E47F2DDD0B"))
        XCTAssertTrue(folderNames.contains("26930337-4424-4CF6-9A2D-4AE0A0BB84E9"))
        XCTAssertTrue(folderNames.contains("8896EDDD-2E0D-4E52-9D95-8479F318E4C6"))
        XCTAssertTrue(folderNames.contains("2B1A15F7-CDA1-4BC9-B1CA-4063A869E251"))
    }

    func testSyntheticDescriptorFolderDetection() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let descDir = tempDir.appendingPathComponent("12345678-ABCD-1234-ABCD-1234567890AB")
        let versionsDir = descDir.appendingPathComponent("versions/0/contents", isDirectory: true)
        try FileManager.default.createDirectory(at: versionsDir, withIntermediateDirectories: true)

        let engine = TendiesEngine.shared
        XCTAssertTrue(engine.isDescriptorFolder(descDir))

        // Synthetic mercury path
        let mercuryDir = tempDir.appendingPathComponent("Extensions/com.apple.MercuryPoster/descriptors/MERCURY-UUID")
        try FileManager.default.createDirectory(at: mercuryDir.appendingPathComponent("versions"), withIntermediateDirectories: true)
        XCTAssertEqual(engine.determineExtension(for: mercuryDir, defaultExt: "default.ext"), "com.apple.MercuryPoster")

        let found = engine.findDescriptorsWithExtensions(in: tempDir, defaultExt: "default.ext")
        XCTAssertEqual(found.count, 2)
    }

    func testWindows11DescriptorDiscovery() throws {
        let inspectURL = URL(fileURLWithPath: "/tmp/inspect_windows11")
        guard FileManager.default.fileExists(atPath: inspectURL.path) else {
            throw XCTSkip("/tmp/inspect_windows11 does not exist")
        }

        let engine = TendiesEngine.shared
        let descriptors = engine.findDescriptorsWithExtensions(in: inspectURL, defaultExt: "com.apple.WallpaperKit.CollectionsPoster")

        XCTAssertEqual(descriptors.count, 1, "windows11 should contain exactly 1 descriptor")
        guard let first = descriptors.first else { return }
        XCTAssertEqual(first.ext, "com.apple.WallpaperKit.CollectionsPoster")
        XCTAssertEqual(first.url.lastPathComponent, "E538499C-3F95-4FEA-AE58-191E5112E194")
    }

    func testSuggestionMetadataPreservesWallpaperId() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let suggestionPlistURL = tempDir.appendingPathComponent("com.apple.posterkit.provider.identifierURL.suggestionMetadata.plist")
        try "dummy".data(using: .utf8)?.write(to: suggestionPlistURL)

        let wallpaperPlistURL = tempDir.appendingPathComponent("Wallpaper.plist")
        let origDict: [String: Any] = ["identifier": 7400, "name": "Windows 11"]
        let origData = try PropertyListSerialization.data(fromPropertyList: origDict, format: .xml, options: 0)
        try origData.write(to: wallpaperPlistURL)

        let engine = TendiesEngine.shared
        engine.updatePlistIdentifiers(in: tempDir, randomizedID: 99999)

        let readData = try Data(contentsOf: wallpaperPlistURL)
        let readDict = try PropertyListSerialization.propertyList(from: readData, options: [], format: nil) as? [String: Any]
        XCTAssertEqual(readDict?["identifier"] as? Int, 7400, "Wallpaper.plist identifier should NOT be modified when suggestionMetadata exists")
    }

    func testNoSuggestionMetadataRandomizesWallpaperId() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let wallpaperPlistURL = tempDir.appendingPathComponent("Wallpaper.plist")
        let origDict: [String: Any] = ["identifier": 7400, "name": "Video Wallpaper"]
        let origData = try PropertyListSerialization.data(fromPropertyList: origDict, format: .xml, options: 0)
        try origData.write(to: wallpaperPlistURL)

        let engine = TendiesEngine.shared
        engine.updatePlistIdentifiers(in: tempDir, randomizedID: 44444)

        let readData = try Data(contentsOf: wallpaperPlistURL)
        let readDict = try PropertyListSerialization.propertyList(from: readData, options: [], format: nil) as? [String: Any]
        XCTAssertEqual(readDict?["identifier"] as? Int, 44444, "Wallpaper.plist identifier SHOULD be randomized when suggestionMetadata is absent")
    }

    func testMercuryDescriptorsIgnoredNameFolder() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let engine = TendiesEngine.shared
        let mercuryDescriptorsDir = tempDir.appendingPathComponent("mercury-descriptors")
        let actualDescDir = mercuryDescriptorsDir.appendingPathComponent("UUID-1234")
        try FileManager.default.createDirectory(at: actualDescDir.appendingPathComponent("versions"), withIntermediateDirectories: true)

        XCTAssertFalse(engine.isDescriptorFolder(mercuryDescriptorsDir), "mercury-descriptors container should be ignored as a descriptor folder")
        XCTAssertTrue(engine.isDescriptorFolder(actualDescDir), "inner UUID folder with versions should be recognized as descriptor folder")

        let found = engine.findDescriptorsWithExtensions(in: tempDir, defaultExt: "default.ext")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.ext, "com.apple.MercuryPoster")
    }

    @MainActor
    func testDocumentsTendieIsMovedIntoStorage() throws {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let name = "dropped_\(UUID().uuidString).tendies"
        let dropped = docs.appendingPathComponent(name)
        let stored = TendiesEngine.tendiesStorageDirectory.appendingPathComponent(name)
        try Data().write(to: dropped)
        defer {
            try? FileManager.default.removeItem(at: dropped)
            try? FileManager.default.removeItem(at: stored)
        }

        // init scans Documents and picks up the dropped archive.
        let vm = AppViewModel()
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dropped.path))

        // Deleting the wallpaper removes the stored archive; the next scan must not bring it back.
        try FileManager.default.removeItem(at: stored)
        vm.scanDocumentsForTendies()
        XCTAssertFalse(FileManager.default.fileExists(atPath: stored.path))
    }
}
