import SwiftUI
import AppKit

enum Ratio: String, CaseIterable, Identifiable {
    case original = "Original", free = "Freeform", square = "1:1", threeTwo = "3:2", fourThree = "4:3", fiveFour = "5:4", wide = "16:9", custom = "Custom"
    var id: String { rawValue }
    func value(original: CGFloat, custom: CGFloat) -> CGFloat? {
        switch self {
        case .original: return original
        case .free: return nil
        case .square: return 1
        case .threeTwo: return 1.5
        case .fourThree: return 4 / 3
        case .fiveFour: return 1.25
        case .wide: return 16 / 9
        case .custom: return custom
        }
    }
}

enum CropPreviewMode: String, CaseIterable, Identifiable {
    case cropped = "Cropped only", sideBySide = "Side by side", stacked = "Top and bottom"
    var id: String { rawValue }
}

// NSCache is thread-safe; the lock protects cancellation across the UI and decode queue.
final class PreviewCache: @unchecked Sendable {
    let images = NSCache<NSURL, CGImage>()
    private let lock = NSLock()
    private var token = UUID()
    func request(_ value: UUID) { lock.lock(); token = value; lock.unlock() }
    func isCurrent(_ value: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return token == value }
    func object(forKey key: NSURL) -> CGImage? { images.object(forKey: key) }
    func setObject(_ image: CGImage, forKey key: NSURL, cost: Int) { images.setObject(image, forKey: key, cost: cost) }
    func removeObject(forKey key: NSURL) { images.removeObject(forKey: key) }
    func removeAllObjects() { images.removeAllObjects() }
}

@MainActor final class CropModel: ObservableObject {
    @Published var files: [URL] = []
    @Published var index = 0
    @Published var preview: CGImage?
    @Published var info: PhotoInfo?
    @Published var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @Published var ratio: Ratio = .original
    @Published var customWidth = 3.0
    @Published var customHeight = 2.0
    @Published var reviewing = false
    @Published var previewMode = CropPreviewMode(rawValue: UserDefaults.standard.string(forKey: "previewMode") ?? "") ?? .sideBySide {
        didSet { UserDefaults.standard.set(previewMode.rawValue, forKey: "previewMode") }
    }
    @Published var automaticPreview = UserDefaults.standard.bool(forKey: "automaticPreview") {
        didSet { UserDefaults.standard.set(automaticPreview, forKey: "automaticPreview") }
    }
    @Published var cropStep = UserDefaults.standard.object(forKey: "cropStep") as? Double ?? 5 {
        didSet { UserDefaults.standard.set(cropStep, forKey: "cropStep") }
    }
    var croppedMegapixels: String? {
        guard let info else { return nil }
        let pixels = Imaging.pixels(crop, info: info)
        return String(format: "Cropped: %.2f MP", Double(pixels.width * pixels.height) / 1e6)
    }
    var cropDimensions: String? {
        guard let info else { return nil }
        let pixels = Imaging.pixels(crop, info: info)
        return "\(info.width) × \(info.height) → \(Int(pixels.width)) × \(Int(pixels.height)) px"
    }
    var cropSummary: String? {
        guard let info else { return nil }
        let pixels = Imaging.pixels(crop, info: info)
        let original = Double(info.width) * Double(info.height)
        let retained = Double(pixels.width * pixels.height)
        return String(format: "%.2f → %.2f MP · −%.2f MP (%.1f%% reduction)", original / 1e6, retained / 1e6, (original - retained) / 1e6, (1 - retained / original) * 100)
    }
    @Published var loading = false
    @Published var saving = false
    @Published var losslessWarning: String?
    @Published var error: String?
    @Published var status = "Open a folder to begin"
    @Published var outputFolder: URL? {
        didSet { UserDefaults.standard.set(outputFolder?.path, forKey: "outputFolder") }
    }
    @Published var overwrite = UserDefaults.standard.bool(forKey: "overwrite") {
        didSet { UserDefaults.standard.set(overwrite, forKey: "overwrite") }
    }
    @Published var advance = UserDefaults.standard.bool(forKey: "advance") {
        didSet { UserDefaults.standard.set(advance, forKey: "advance") }
    }
    @Published var quality = UserDefaults.standard.object(forKey: "quality") as? Double ?? 0.95 {
        didSet { UserDefaults.standard.set(quality, forKey: "quality") }
    }
    @Published var lossless = UserDefaults.standard.object(forKey: "lossless") as? Bool ?? true {
        didSet { UserDefaults.standard.set(lossless, forKey: "lossless") }
    }
    private let queue = DispatchQueue(label: "Cropper.images", qos: .userInitiated)
    private let cache = PreviewCache()
    private var generation = UUID()
    private var history: [CGRect] = []
    var canUndo: Bool { !history.isEmpty }
    var current: URL? { files.indices.contains(index) ? files[index] : nil }
    var aspect: CGFloat? { ratio.value(original: info?.ratio ?? 1.5, custom: CGFloat(customWidth / max(0.01, customHeight))) }
    init() {
        cache.images.countLimit = 3
        cache.images.totalCostLimit = 80 * 1024 * 1024
        if let path = UserDefaults.standard.string(forKey: "outputFolder") { outputFolder = URL(fileURLWithPath: path) }
    }
    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Open JPEG Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }
    func open(_ folder: URL) {
        guard !saving else { return }
        do {
            files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]).filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            cache.removeAllObjects(); index = 0
            if files.isEmpty { preview = nil; info = nil; status = "No JPEG images in this folder"; generation = UUID(); cache.request(generation) } else { load() }
        } catch { self.error = error.localizedDescription }
    }
    func chooseOutput() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = "Use Output Folder"
        if panel.runModal() == .OK { outputFolder = panel.url }
    }
    func navigate(_ delta: Int) {
        guard !saving, !files.isEmpty else { return }
        let next = max(0, min(files.count - 1, index + delta))
        guard next != index else { return }
        index = next; load()
    }
    func load() {
        guard let url = current else { return }
        let token = UUID(); generation = token; cache.request(token)
        reviewing = false; loading = true; preview = nil; info = nil; history.removeAll(); crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        let neighbors = [index - 1, index + 1].filter { files.indices.contains($0) }.map { files[$0] }
        let cache = cache
        queue.async { [weak self] in
            guard cache.isCurrent(token) else { return }
            do {
                let info = try Imaging.info(url)
                let image: CGImage
                if let cached = cache.object(forKey: url as NSURL) { image = cached } else {
                    image = try Imaging.preview(url); cache.setObject(image, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
                }
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.info = info; self.preview = image; self.loading = false; self.fitRatio(record: false)
                    self.status = "\(info.width) × \(info.height)"
                }
                for neighbor in neighbors where cache.object(forKey: neighbor as NSURL) == nil {
                    guard cache.isCurrent(token) else { break }
                    // Prefetch remains bounded to two adjacent display-sized images.
                    if let image = try? Imaging.preview(neighbor) { cache.setObject(image, forKey: neighbor as NSURL, cost: image.bytesPerRow * image.height) }
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { guard let self, self.generation == token else { return }; self.loading = false; self.error = message }
            }
        }
    }
    func remember() { history.append(crop); if history.count > 50 { history.removeFirst() } }
    func undo() { if let prior = history.popLast() { reviewing = false; crop = prior } }
    func reset() { reviewing = false; remember(); crop = CGRect(x: 0, y: 0, width: 1, height: 1); fitRatio(record: false) }
    func setRatio(_ value: Ratio) { reviewing = false; ratio = value; fitRatio() }
    func fitRatio(record: Bool = true) {
        guard let info, let aspect else { return }
        if record { remember() }
        let normalized = aspect / info.ratio
        var w = crop.width; var h = crop.height
        if w / h > normalized { w = h * normalized } else { h = w / normalized }
        crop = CGRect(x: crop.midX - w / 2, y: crop.midY - h / 2, width: w, height: h)
    }
    // Adjust retained image area in percentage points, preserving center and ratio.
    func adjustCrop(_ direction: Double) {
        guard preview != nil, !loading, !saving else { return }
        let area = crop.width * crop.height
        let maxScale = min(2 * min(crop.midX, 1 - crop.midX) / crop.width,
                           2 * min(crop.midY, 1 - crop.midY) / crop.height)
        let minimumScale = max(0.01 / crop.width, 0.01 / crop.height)
        let target = max(area * minimumScale * minimumScale,
                         min(area * maxScale * maxScale, area + direction * CGFloat(max(1, min(25, cropStep))) / 100))
        guard abs(target - area) > 0.0000001 else { return }
        remember()
        let scale = sqrt(target / area)
        let w = crop.width * scale, h = crop.height * scale
        crop = CGRect(x: crop.midX - w / 2, y: crop.midY - h / 2, width: w, height: h)
    }
    func save() {
        guard let url = current, preview != nil, !loading, !saving else { return }
        let destination: URL
        do {
            if overwrite { destination = url } else {
                let folder = outputFolder ?? url.deletingLastPathComponent().appendingPathComponent("Cropped", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let base = url.deletingPathExtension().lastPathComponent + "-cropped"
                var candidate = folder.appendingPathComponent(base + ".jpg"); var number = 2
                while FileManager.default.fileExists(atPath: candidate.path) { candidate = folder.appendingPathComponent("\(base)-\(number).jpg"); number += 1 }
                destination = candidate
            }
        } catch { self.error = error.localizedDescription; return }
        saving = true
        losslessWarning = nil
        let rect = crop, quality = quality, lossless = lossless, advance = advance, cache = cache
        let resultMegapixels = croppedMegapixels ?? ""
        queue.async { [weak self] in
            do {
                let result = try Imaging.save(source: url, destination: destination, crop: rect, quality: quality, lossless: lossless)
                cache.removeObject(forKey: url as NSURL)
                DispatchQueue.main.async {
                    guard let self else { return }; self.saving = false; self.history.removeAll()
                    if let reason = result.fallbackReason {
                        self.losslessWarning = "Saved \(destination.lastPathComponent) using JPEG quality \(Int(quality * 100))%. The crop was saved successfully, but re-encoded rather than losslessly cropped.\n\n\(reason.explanation)\n\nRetry from the original JPEG to avoid recompressing a previously saved crop."
                    }
                    if advance && self.index < self.files.count - 1 { self.navigate(1) }
                    else if destination == url { self.load() }
                    self.status = "Saved \(destination.lastPathComponent) · \(resultMegapixels) · \(result.usedLossless ? "lossless" : "JPEG")"
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { self?.saving = false; self?.error = message }
            }
        }
    }
}
