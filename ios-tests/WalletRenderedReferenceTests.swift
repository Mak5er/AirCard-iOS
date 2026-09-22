import XCTest
import UIKit
@testable import AirCard_iOS

private final class FixturePKImage: NSObject, NSCoding {
    let imageData: Data

    init(imageData: Data) {
        self.imageData = imageData
        super.init()
    }

    required init?(coder: NSCoder) {
        guard let data = coder.decodeObject(forKey: "imageData") as? Data else { return nil }
        imageData = data
        super.init()
    }

    func encode(with coder: NSCoder) {
        coder.encode(imageData, forKey: "imageData")
    }
}

private final class FixtureFrontFaceImageSet: NSObject, NSCoding {
    let faceImage: FixturePKImage

    init(faceImage: FixturePKImage) {
        self.faceImage = faceImage
        super.init()
    }

    required init?(coder: NSCoder) {
        guard let image = coder.decodeObject(forKey: "faceImage") as? FixturePKImage else { return nil }
        faceImage = image
        super.init()
    }

    func encode(with coder: NSCoder) {
        coder.encode(faceImage, forKey: "faceImage")
    }
}

final class WalletRenderedReferenceTests: XCTestCase {
    func testFrontFaceDecoderExtractsExactFaceImageBytesFromWalletStyleArchive() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 15))
        let png = try XCTUnwrap(renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 15))
            UIColor.white.setFill()
            context.fill(CGRect(x: 2, y: 2, width: 5, height: 5))
        }.pngData())

        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.setClassName("PKImage", for: FixturePKImage.self)
        archiver.setClassName("PKPassFrontFaceImageSet", for: FixtureFrontFaceImageSet.self)
        archiver.encode(
            FixtureFrontFaceImageSet(faceImage: FixturePKImage(imageData: png)),
            forKey: NSKeyedArchiveRootObjectKey
        )
        archiver.finishEncoding()

        // Wallet's cache payload has an opaque binary envelope before the bplist archive.
        var walletStyleContainer = Data(repeating: 0x00, count: 48)
        walletStyleContainer.append(archiver.encodedData)

        let extracted = AppViewModel.decodeRenderedWalletFrontFaceImageData(walletStyleContainer)
        XCTAssertEqual(extracted, png)
    }

    func testFrontFaceDecoderRejectsNonArchivePayload() {
        XCTAssertNil(
            AppViewModel.decodeRenderedWalletFrontFaceImageData(Data("not-a-wallet-front-face".utf8))
        )
    }
}
