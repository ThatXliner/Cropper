import AppKit
import ImageIO
import UniformTypeIdentifiers

struct PhotoInfo {
    let width: Int
    let height: Int
    let orientation: Int
    var ratio: CGFloat { CGFloat(width) / CGFloat(height) }
}

enum LosslessFallback: String {
    case unavailable, orientation, alignment, toolFailed, unexpectedOutput
    var explanation: String {
        switch self {
        case .unavailable:
            return "jpegtran was not found. If you use Homebrew, install it with brew install jpeg-turbo, then save again. Cropper checks /opt/homebrew/bin/jpegtran, /usr/local/bin/jpegtran, and /usr/bin/jpegtran."
        case .orientation:
            return "This photo uses an EXIF orientation that Cropper's lossless path does not support. Use a JPEG whose pixels are already upright (orientation 1), or keep the JPEG fallback for this photo. Increasing JPEG quality reduces further compression loss but does not make the crop lossless."
        case .alignment:
            return "The selected crop does not align with JPEG blocks. Cropper currently requires the crop's top-left X and Y coordinates, width, and height to be multiples of 16 pixels. Adjust the crop to those boundaries and save again, or keep the JPEG fallback for this exact crop. Cropper never changes your selection automatically."
        case .toolFailed:
            return "jpegtran could not complete this crop. Try updating or reinstalling jpegtran (Homebrew: brew reinstall jpeg-turbo), or use the JPEG fallback for this file."
        case .unexpectedOutput:
            return "jpegtran produced an image with unexpected dimensions or orientation. Cropper discarded that result to preserve your exact selection. Try updating jpegtran, or use the JPEG fallback for this file."
        }
    }
}

struct CropSaveResult {
    let usedLossless: Bool
    let fallbackReason: LosslessFallback?
}

enum Imaging {
    static func source(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw failure("Cannot read \(url.lastPathComponent).") }
        return source
    }
    static func info(_ url: URL) throws -> PhotoInfo {
        let source = try source(url)
        let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let w = p[kCGImagePropertyPixelWidth] as? Int ?? 1
        let h = p[kCGImagePropertyPixelHeight] as? Int ?? 1
        let orientation = p[kCGImagePropertyOrientation] as? Int ?? 1
        return PhotoInfo(width: orientation >= 5 ? h : w, height: orientation >= 5 ? w : h, orientation: orientation)
    }
    static func preview(_ url: URL) throws -> CGImage {
        let source = try source(url)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2400, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw failure("Cannot decode JPEG preview.") }
        return image
    }
    // Crop coordinates are normalized, in visually oriented image space, with a top-left origin.
    static func pixels(_ rect: CGRect, info: PhotoInfo) -> CGRect {
        let x = max(0, min(info.width - 1, Int((rect.minX * CGFloat(info.width)).rounded())))
        let y = max(0, min(info.height - 1, Int((rect.minY * CGFloat(info.height)).rounded())))
        let right = max(x + 1, min(info.width, Int((rect.maxX * CGFloat(info.width)).rounded())))
        let bottom = max(y + 1, min(info.height, Int((rect.maxY * CGFloat(info.height)).rounded())))
        return CGRect(x: x, y: y, width: right - x, height: bottom - y)
    }
    static func save(source url: URL, destination: URL, crop: CGRect, quality: Double, lossless: Bool, jpegtranPaths: [String] = ["/opt/homebrew/bin/jpegtran", "/usr/local/bin/jpegtran", "/usr/bin/jpegtran"]) throws -> CropSaveResult {
        let source = try source(url)
        let info = try info(url)
        let pixelCrop = pixels(crop, info: info)
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".cropper-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: temp) }
        let fallbackReason = lossless ? tryLossless(url, temp: temp, rect: pixelCrop, info: info, executables: jpegtranPaths) : nil
        let usedLossless = lossless && fallbackReason == nil
        if !usedLossless {
            guard let full = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(info.width, info.height), kCGImageSourceShouldCacheImmediately: true] as CFDictionary), let cropped = full.cropping(to: pixelCrop), let dest = CGImageDestinationCreateWithURL(temp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw failure("Could not create cropped JPEG.") }
            var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            properties[kCGImagePropertyOrientation] = 1
            properties[kCGImagePropertyPixelWidth] = cropped.width
            properties[kCGImagePropertyPixelHeight] = cropped.height
            properties[kCGImageDestinationLossyCompressionQuality] = quality
            if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exif[kCGImagePropertyExifPixelXDimension] = cropped.width
                exif[kCGImagePropertyExifPixelYDimension] = cropped.height
                properties[kCGImagePropertyExifDictionary] = exif
            }
            if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                properties[kCGImagePropertyTIFFDictionary] = tiff
            }
            // ImageIO writes the CGImage's ICC color space and carries EXIF/IPTC/GPS dictionaries.
            CGImageDestinationAddImage(dest, cropped, properties as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { throw failure("JPEG encoding failed.") }
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: destination)
        }
        return CropSaveResult(usedLossless: usedLossless, fallbackReason: fallbackReason)
    }
    private static func tryLossless(_ source: URL, temp: URL, rect: CGRect, info: PhotoInfo, executables: [String]) -> LosslessFallback? {
        guard info.orientation == 1 else { return .orientation }
        // Only exact MCU-aligned rectangles. Never silently expand a user's crop.
        guard Int(rect.minX) % 16 == 0, Int(rect.minY) % 16 == 0, Int(rect.width) % 16 == 0, Int(rect.height) % 16 == 0 else { return .alignment }
        guard let executable = executables.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return .unavailable }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-copy", "all", "-perfect", "-crop", "\(Int(rect.width))x\(Int(rect.height))+\(Int(rect.minX))+\(Int(rect.minY))", "-outfile", temp.path, source.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { return .toolFailed }
            guard let result = try? Imaging.info(temp), result.width == Int(rect.width), result.height == Int(rect.height), result.orientation == 1 else { return .unexpectedOutput }
            return nil
        } catch { return .toolFailed }
    }
    static func failure(_ message: String) -> NSError { NSError(domain: "Cropper", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
