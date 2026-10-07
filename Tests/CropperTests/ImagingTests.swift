import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Cropper

final class ImagingTests: XCTestCase {
    var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }
    func fixture(width: Int = 160, height: Int = 96, orientation: Int = 1) throws -> URL {
        let url = folder.appendingPathComponent("source.jpg")
        let color = CGColorSpace(name: CGColorSpace.displayP3)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: color, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: orientation, kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:07 12:00:00", kCGImagePropertyExifUserComment: "Cropper fixture"], kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "EOS R7"], kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
    func testCropPreservesMetadataProfileAndSource() throws {
        let url = try fixture()
        let before = try Data(contentsOf: url)
        let output = folder.appendingPathComponent("result.jpg")
        XCTAssertFalse(try Imaging.save(source: url, destination: output, crop: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), quality: 0.9, lossless: false))
        let source = try Imaging.source(output)
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        XCTAssertEqual(image.width, 80); XCTAssertEqual(image.height, 48)
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.displayP3)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
        let exif = properties[kCGImagePropertyExifDictionary] as! NSDictionary
        XCTAssertEqual(exif[kCGImagePropertyExifDateTimeOriginal] as? String, "2026:10:07 12:00:00")
        let tiff = properties[kCGImagePropertyTIFFDictionary] as! NSDictionary
        XCTAssertEqual(tiff[kCGImagePropertyTIFFModel] as? String, "EOS R7")
        XCTAssertEqual(try Data(contentsOf: url), before)
    }
    func testAllOrientationsAndOverwrite() throws {
        for orientation in 1...8 {
            let url = try fixture(orientation: orientation)
            let info = try Imaging.info(url)
            XCTAssertEqual(info.width, orientation >= 5 ? 96 : 160)
            let output = folder.appendingPathComponent("rotated.jpg")
            _ = try Imaging.save(source: url, destination: output, crop: CGRect(x: 0, y: 0, width: 0.5, height: 0.5), quality: 1, lossless: false)
            let saved = try Imaging.info(output)
            XCTAssertEqual(saved.width, info.width / 2); XCTAssertEqual(saved.height, info.height / 2)
            XCTAssertEqual(saved.orientation, 1)
            _ = try Imaging.save(source: output, destination: output, crop: CGRect(x: 0, y: 0, width: 0.5, height: 1), quality: 1, lossless: false)
            XCTAssertEqual(try Imaging.info(output).width, info.width / 4)
        }
    }
    func testTopLeftCropMatchesPreview() throws {
        let url = try fixture()
        let output = folder.appendingPathComponent("top.jpg")
        _ = try Imaging.save(source: url, destination: output, crop: CGRect(x: 0, y: 0, width: 1, height: 0.4), quality: 1, lossless: false)
        let source = try Imaging.source(output)
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        let data = image.dataProvider!.data! as Data
        // Fixture's visual top is blue. A bottom-origin crop would be red.
        XCTAssertGreaterThan(Int(data[2]), Int(data[0]) + 100)
    }
    func testOrientedCropPixelsMatchVisualTopLeft() throws {
        for orientation in 1...8 {
            let url = try fixture(orientation: orientation)
            let preview = try Imaging.preview(url)
            let output = folder.appendingPathComponent("visual.jpg")
            _ = try Imaging.save(source: url, destination: output, crop: CGRect(x: 0, y: 0, width: 0.25, height: 0.25), quality: 1, lossless: false)
            let result = CGImageSourceCreateImageAtIndex(try Imaging.source(output), 0, nil)!
            func sample(_ image: CGImage) -> [Int] {
                let pixel = image.cropping(to: CGRect(x: 4, y: 4, width: 1, height: 1))!
                let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
                return (0..<3).map { Int(bytes[$0]) }
            }
            let expected = sample(preview), actual = sample(result)
            for channel in 0..<3 { XCTAssertLessThan(abs(expected[channel] - actual[channel]), 12, "Orientation \(orientation)") }
        }
    }
    func testLargeImagePreviewIsBounded() throws {
        let url = try fixture(width: 6960, height: 4640)
        let start = Date()
        let preview = try Imaging.preview(url)
        XCTAssertEqual(preview.width, 2400)
        XCTAssertLessThanOrEqual(preview.bytesPerRow * preview.height, 16 * 1024 * 1024)
        print("32.3 MP preview: \(Date().timeIntervalSince(start)) seconds; \(preview.bytesPerRow * preview.height) bytes")
    }
    @MainActor func testModelSaveAndNavigation() throws {
        let url = try fixture()
        try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent("second.jpg"))
        let model = CropModel()
        model.overwrite = false
        model.open(folder)
        XCTAssertEqual(model.files.count, 2)
        model.navigate(1); XCTAssertEqual(model.index, 1)
        model.info = try Imaging.info(url)
        model.setRatio(.square)
        XCTAssertEqual(model.crop.width / model.crop.height * model.info!.ratio, 1, accuracy: 0.001)
        model.undo(); XCTAssertEqual(model.crop.width, 1)
    }
}
