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
    @MainActor func testAreaShortcutsAndRoundedMegapixels() throws {
        let model = CropModel()
        model.info = PhotoInfo(width: 6000, height: 4000, orientation: 1)
        model.preview = try Imaging.preview(fixture())
        let savedStep = UserDefaults.standard.object(forKey: "cropStep")
        defer {
            if let savedStep { UserDefaults.standard.set(savedStep, forKey: "cropStep") }
            else { UserDefaults.standard.removeObject(forKey: "cropStep") }
        }
        model.cropStep = 5
        model.crop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        XCTAssertEqual(model.cropDimensions, "6000 × 4000 → 3000 × 2000 px")
        XCTAssertEqual(model.croppedMegapixels, "Cropped: 6.00 MP")
        model.reviewing = true
        XCTAssertEqual(model.croppedMegapixels, "Cropped: 6.00 MP")
        model.reviewing = false
        XCTAssertEqual(model.cropSummary, "24.00 → 6.00 MP · −18.00 MP (75.0% reduction)")
        let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        canvas.model = model
        func key(_ text: String, code: UInt16) {
            canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!)
        }
        key("+", code: 24)
        XCTAssertEqual(model.crop.width * model.crop.height, 0.30, accuracy: 0.000001)
        XCTAssertEqual(model.cropDimensions, "6000 × 4000 → 3286 × 2190 px")
        XCTAssertEqual(model.crop.midX, 0.5, accuracy: 0.000001)
        XCTAssertEqual(model.crop.width / model.crop.height, 1, accuracy: 0.000001)
        key("-", code: 27)
        XCTAssertEqual(model.crop.width * model.crop.height, 0.25, accuracy: 0.000001)
        model.undo()
        XCTAssertEqual(model.crop.width * model.crop.height, 0.30, accuracy: 0.000001)
        model.crop = CGRect(x: 0, y: 0.25, width: 0.5, height: 0.5)
        model.adjustCrop(1)
        XCTAssertEqual(model.crop.minX, 0, accuracy: 0.000001)
        XCTAssertEqual(model.crop.width, 0.5, accuracy: 0.000001)
        for _ in 0..<100 { model.adjustCrop(-1) }
        XCTAssertGreaterThanOrEqual(model.crop.width, 0.01 - 0.000001)
        model.reviewing = true
        key("\u{1b}", code: 53)
        XCTAssertFalse(model.reviewing)
    }

    @MainActor func testPreviewLayoutsAndEnterSave() async throws {
        let url = try fixture()
        let model = CropModel()
        let defaults = UserDefaults.standard
        let keys = ["overwrite", "advance", "outputFolder", "lossless", "automaticPreview"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        model.files = [url]
        model.info = try Imaging.info(url)
        model.preview = try Imaging.preview(url)
        model.crop = CGRect(x: 0, y: 0, width: 1, height: 0.4)
        model.overwrite = false; model.advance = false; model.lossless = false
        model.outputFolder = folder.appendingPathComponent("output")
        model.reviewing = true
        let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        canvas.model = model
        model.reviewing = false
        model.automaticPreview = true
        let location = canvas.convert(CGPoint(x: 400, y: 150), to: nil)
        func mouse(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                               windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        canvas.mouseDown(with: mouse(.leftMouseDown))
        canvas.mouseDragged(with: mouse(.leftMouseDragged))
        canvas.mouseUp(with: mouse(.leftMouseUp))
        XCTAssertTrue(model.reviewing)
        let previewPreference = defaults.object(forKey: "previewMode")
        defer {
            if let previewPreference { defaults.set(previewPreference, forKey: "previewMode") }
            else { defaults.removeObject(forKey: "previewMode") }
        }
        for mode in CropPreviewMode.allCases {
            model.previewMode = mode
            let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)!
            canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
            // Every layout renders the selected blue top region in the result panel.
            let point: CGPoint
            switch mode {
            case .cropped: point = CGPoint(x: 400, y: 300)
            case .sideBySide: point = CGPoint(x: 592, y: 300)
            case .stacked: point = CGPoint(x: 400, y: 455)
            }
            let color = bitmap.colorAt(x: Int(point.x) * bitmap.pixelsWide / 800,
                                       y: Int(point.y) * bitmap.pixelsHigh / 600)!.usingColorSpace(.deviceRGB)!
            XCTAssertGreaterThan(color.blueComponent, color.redComponent + 0.5, "Layout \(mode)")
        }
        canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!)
        for _ in 0..<200 where model.saving { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.saving)
        XCTAssertNil(model.error)
        let output = model.outputFolder!.appendingPathComponent("source-cropped.jpg")
        let result = try Imaging.info(output)
        XCTAssertEqual(result.width, 160)
        XCTAssertEqual(result.height, 38)
        XCTAssertTrue(model.reviewing)
        let savedMP = String(format: "Cropped: %.2f MP", Double(result.width * result.height) / 1e6)
        XCTAssertEqual(model.croppedMegapixels, savedMP)
        XCTAssertTrue(model.status.contains(savedMP))
    }

    @MainActor func testDragAnywhereResizesAndShiftDragRepositions() throws {
        let model = CropModel()
        model.info = PhotoInfo(width: 160, height: 96, orientation: 1)
        model.preview = try Imaging.preview(fixture())
        let savedAutomatic = UserDefaults.standard.object(forKey: "automaticPreview")
        defer {
            if let savedAutomatic { UserDefaults.standard.set(savedAutomatic, forKey: "automaticPreview") }
            else { UserDefaults.standard.removeObject(forKey: "automaticPreview") }
        }
        model.automaticPreview = false
        let canvas = CanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        canvas.model = model
        // Photo occupies x=28...772, y=76.8...523.2 in this canvas.
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint, shift: Bool = false) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: shift ? [.shift] : [], timestamp: 0,
                               windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func drag(_ start: CGPoint, _ end: CGPoint, shift: Bool = false) {
            canvas.mouseDown(with: mouse(.leftMouseDown, start, shift: shift))
            canvas.mouseDragged(with: mouse(.leftMouseDragged, end, shift: shift))
            canvas.mouseUp(with: mouse(.leftMouseUp, end, shift: shift))
        }
        for point in [CGPoint(x: 200, y: 180), CGPoint(x: 600, y: 180), CGPoint(x: 200, y: 420), CGPoint(x: 600, y: 420)] {
            let original = CGRect(x: 0, y: 0, width: 1, height: 1)
            model.crop = original
            drag(point, CGPoint(x: 400, y: 300))
            XCTAssertLessThan(model.crop.width, 1)
            XCTAssertLessThan(model.crop.height, 1)
            XCTAssertEqual(model.crop.width / model.crop.height, 1, accuracy: 0.000001)
            XCTAssertGreaterThanOrEqual(model.crop.minX, 0)
            XCTAssertGreaterThanOrEqual(model.crop.minY, 0)
            XCTAssertLessThanOrEqual(model.crop.maxX, 1)
            XCTAssertLessThanOrEqual(model.crop.maxY, 1)
            model.undo()
            XCTAssertEqual(model.crop, original)
        }
        model.crop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        drag(CGPoint(x: 400, y: 300), CGPoint(x: 450, y: 320), shift: true)
        XCTAssertEqual(model.crop.width, 0.5)
        XCTAssertEqual(model.crop.height, 0.5)
        XCTAssertGreaterThan(model.crop.minX, 0.25)
        let before = model.crop
        drag(CGPoint(x: 10, y: 10), CGPoint(x: 400, y: 300))
        XCTAssertEqual(model.crop, before)
        // Even the dimmed part of the image can initiate resizing.
        drag(CGPoint(x: 100, y: 150), CGPoint(x: 180, y: 200))
        XCTAssertLessThan(model.crop.width, before.width)
    }

}
