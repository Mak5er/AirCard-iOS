import XCTest
@testable import AirCard_iOS

final class WalletSafetyTests: XCTestCase {
    private let sampleCardId = "TMdsAhN-+WpUmpa6xdsAAXEG68M="

    func testCardIdCleaningFromWalletPath() {
        let raw = "/var/mobile/Library/Passes/Cards/\(sampleCardId).pkpass"
        XCTAssertEqual(CardItem.cleanCardId(raw), sampleCardId)
    }

    func testMissingExportClassification() {
        XCTAssertEqual(
            WalletSafety.classifyArtworkExportFailure("Exported file not found in AFC recovery area"),
            .sourceMissing
        )
        XCTAssertEqual(
            WalletSafety.classifyArtworkExportFailure("Connection reset by peer"),
            .fatal
        )
        XCTAssertEqual(WalletSafety.classifyArtworkExportFailure(nil), .fatal)
    }

    func testManifestValidationDetectsTampering() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallet_manifest_test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let leaf = "cardBackgroundCombined@2x.png"
        let original = Data("provider-original".utf8)
        try original.write(to: dir.appendingPathComponent(leaf))

        let manifest = try WalletSafety.makeManifest(
            cardId: sampleCardId,
            directory: dir,
            leaves: [leaf]
        )
        XCTAssertTrue(
            WalletSafety.validateManifest(
                manifest,
                cardId: sampleCardId,
                directory: dir,
                allowedLeaves: [leaf]
            ).isValid
        )

        try Data("tampered".utf8).write(to: dir.appendingPathComponent(leaf))
        let validation = WalletSafety.validateManifest(
            manifest,
            cardId: sampleCardId,
            directory: dir,
            allowedLeaves: [leaf]
        )
        guard case .invalid(let reason) = validation else {
            return XCTFail("Expected invalid manifest after file tampering")
        }
        XCTAssertTrue(reason.contains("mismatch"))
    }

    func testExactRestoreInventoryRemovesCurrentAndRestoresOnlyOriginalSet() {
        let allowed: Set<String> = ["a.png", "b.png", "c.pdf"]
        let current: Set<String> = ["a.png", "b.png", "c.pdf", "unrelated.dat"]
        let original: Set<String> = ["b.png"]

        let plan = WalletSafety.exactRestoreInventory(
            currentLeaves: current,
            originalLeaves: original,
            allowedLeaves: allowed
        )

        XCTAssertEqual(plan.remove, allowed)
        XCTAssertEqual(plan.restore, ["b.png"])
    }

    func testRecoveryInventoryFindsFlatScanRecoveryDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wallet_recovery_test_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("recovery".utf8).write(to: root.appendingPathComponent("background@2x.png"))

        let items = WalletSafety.recoveryInventory(
            root: root,
            cardId: sampleCardId,
            kind: .scanWriteBack
        )
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.kind, .scanWriteBack)
        XCTAssertEqual(items.first?.fileCount, 1)
    }

    func testBackupBundleRoundTripPreservesIntegrityMetadata() throws {
        let bytes = Data("original-art".utf8)
        let entry = WalletSafety.fileEntry(name: "background@2x.png", data: bytes)
        let manifest = OriginalArtworkManifest(
            version: OriginalArtworkManifest.currentVersion,
            cardId: sampleCardId,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            files: [entry]
        )
        let bundle = WalletArtworkBackupBundle(
            version: WalletArtworkBackupBundle.currentVersion,
            cardId: sampleCardId,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_100),
            manifest: manifest,
            files: [entry.name: bytes]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(bundle)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WalletArtworkBackupBundle.self, from: encoded)

        XCTAssertEqual(decoded.cardId, sampleCardId)
        XCTAssertEqual(decoded.manifest.files.first?.sha256, WalletSafety.sha256Hex(bytes))
        XCTAssertEqual(decoded.files[entry.name], bytes)
    }
}
