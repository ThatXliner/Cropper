import SwiftUI
import AppKit

struct CropCanvas: NSViewRepresentable {
    @ObservedObject var model: CropModel
    func makeNSView(context: Context) -> CanvasView { let view = CanvasView(); view.model = model; return view }
    func updateNSView(_ view: CanvasView, context: Context) { view.model = model; view.needsDisplay = true }
}

final class CanvasView: NSView {
    weak var model: CropModel?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var start = CGPoint.zero
    private var initial = CGRect.zero
    private var corner: Int?
    private var dragging = false
    private var imageRect: CGRect {
        guard let info = model?.info else { return .zero }
        let area = bounds.insetBy(dx: 28, dy: 28)
        let scale = min(area.width / CGFloat(info.width), area.height / CGFloat(info.height))
        let size = CGSize(width: CGFloat(info.width) * scale, height: CGFloat(info.height) * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }
    private func cropOnScreen(_ crop: CGRect) -> CGRect {
        let r = imageRect
        return CGRect(x: r.minX + crop.minX * r.width, y: r.minY + crop.minY * r.height, width: crop.width * r.width, height: crop.height * r.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.09, alpha: 1).setFill(); bounds.fill()
        guard let model, let image = model.preview else { return }
        let r = imageRect
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)).draw(in: r, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        let c = cropOnScreen(model.crop)
        NSColor.black.withAlphaComponent(0.58).setFill()
        let shade = NSBezierPath(rect: r); shade.append(NSBezierPath(rect: c)); shade.windingRule = .evenOdd; shade.fill()
        NSColor.white.withAlphaComponent(0.95).setStroke()
        let border = NSBezierPath(rect: c); border.lineWidth = 1.5; border.stroke()
        if dragging {
            NSColor.white.withAlphaComponent(0.35).setStroke()
            let grid = NSBezierPath()
            for n in 1...2 {
                let t = CGFloat(n) / 3
                grid.move(to: CGPoint(x: c.minX + c.width * t, y: c.minY)); grid.line(to: CGPoint(x: c.minX + c.width * t, y: c.maxY))
                grid.move(to: CGPoint(x: c.minX, y: c.minY + c.height * t)); grid.line(to: CGPoint(x: c.maxX, y: c.minY + c.height * t))
            }
            grid.lineWidth = 0.5; grid.stroke()
        }
        for point in corners(c) {
            let handle = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
            NSColor.white.setFill(); handle.fill()
            NSColor.black.withAlphaComponent(0.5).setStroke(); NSBezierPath(rect: handle).stroke()
        }
    }
    private func corners(_ r: CGRect) -> [CGPoint] { [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)] }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let model, model.preview != nil, !model.saving else { return }
        start = convert(event.locationInWindow, from: nil)
        initial = model.crop
        let rect = cropOnScreen(initial)
        corner = corners(rect).enumerated().first { hypot($0.element.x - start.x, $0.element.y - start.y) < 18 }?.offset
        guard corner != nil || rect.contains(start) else { return }
        model.remember(); dragging = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard dragging, let model else { return }
        let p = convert(event.locationInWindow, from: nil), r = imageRect
        let dx = (p.x - start.x) / r.width, dy = (p.y - start.y) / r.height
        if let corner {
            let left = corner == 0 || corner == 2, top = corner == 0 || corner == 1
            let anchor = CGPoint(x: left ? initial.maxX : initial.minX, y: top ? initial.maxY : initial.minY)
            var w = max(0.01, initial.width + (left ? -dx : dx))
            var h = max(0.01, initial.height + (top ? -dy : dy))
            let maxW = left ? anchor.x : 1 - anchor.x, maxH = top ? anchor.y : 1 - anchor.y
            if let aspect = model.aspect, let info = model.info {
                let normalized = aspect / info.ratio
                // Follow whichever axis the drag changes most, keeping the opposite corner fixed.
                if abs(dx) > abs(dy * normalized) { h = w / normalized } else { w = h * normalized }
                let scale = min(1, min(maxW / w, maxH / h)); w *= scale; h *= scale
            } else { w = min(maxW, w); h = min(maxH, h) }
            model.crop = CGRect(x: left ? anchor.x - w : anchor.x, y: top ? anchor.y - h : anchor.y, width: w, height: h)
        } else {
            model.crop = CGRect(x: min(1 - initial.width, max(0, initial.minX + dx)), y: min(1 - initial.height, max(0, initial.minY + dy)), width: initial.width, height: initial.height)
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { dragging = false; needsDisplay = true }
    override func resetCursorRects() { addCursorRect(imageRect, cursor: .crosshair) }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 126: model?.navigate(-1)
        case 124, 125: model?.navigate(1)
        default: super.keyDown(with: event)
        }
    }
}
