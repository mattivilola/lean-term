import AppKit
import LeanTermCore
import QuartzCore

/// Thin status bars in a pane's left padding, one per finished command in view: from the top of its
/// prompt row to the bottom of its last output row. Layers are reused, nothing is drawn, and only the
/// bars themselves take mouse events, so the overlay never blocks the terminal.
@MainActor
final class CommandStatusView: NSView, NSViewToolTipOwner {
    private static let barWidth: CGFloat = 3
    private static let barX: CGFloat = 5
    /// Pointing at a 3 pt bar would be fiddly; the clickable and tooltip area is wider.
    private static let hitInset: CGFloat = -3
    private static let fadeInDuration: CFTimeInterval = 0.15

    /// Bar colours by outcome.
    var colorForOutcome: (CommandOutcome) -> NSColor = { _ in .labelColor } {
        didSet { shown = nil }
    }
    /// Called with the buffer row of the clicked command's prompt.
    var onSelect: ((Int) -> Void)?

    private struct Shown: Equatable {
        var bars: [CommandStatusBar]
        var originY: CGFloat
        var rowHeight: CGFloat
    }

    private var shown: Shown?
    private var layers: [CALayer] = []
    private var entries: [(hitRect: CGRect, bar: CommandStatusBar)] = []

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("Programmatic views only") }

    func clear() {
        guard shown != nil || !entries.isEmpty else { return }
        show([], originY: 0, rowHeight: 0, fadeInNewest: false)
    }

    /// Lays the bars out. `originY` is the top of the first viewport row in this view. Returns whether the
    /// newest bar appeared with this call and was faded in.
    @discardableResult
    func show(_ bars: [CommandStatusBar], originY: CGFloat, rowHeight: CGFloat, fadeInNewest: Bool) -> Bool {
        let next = Shown(bars: bars, originY: originY, rowHeight: rowHeight)
        guard next != shown else { return false }
        let appeared = fadeInNewest && bars.last.map { $0 != shown?.bars.last } == true
        shown = next
        entries.removeAll(keepingCapacity: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            let top = originY + CGFloat(bar.firstRow) * rowHeight + 1
            let height = max(Self.barWidth, CGFloat(bar.lastRow - bar.firstRow + 1) * rowHeight - 2)
            let rect = CGRect(x: Self.barX, y: top, width: Self.barWidth, height: height)
            let layer = index < layers.count ? layers[index] : makeLayer()
            layer.frame = rect
            layer.backgroundColor = colorForOutcome(bar.outcome).cgColor
            layer.isHidden = false
            entries.append((rect.insetBy(dx: Self.hitInset, dy: 0), bar))
            if appeared, index == bars.count - 1 { fadeIn(layer) }
        }
        for layer in layers.dropFirst(bars.count) { layer.isHidden = true }
        CATransaction.commit()
        removeAllToolTips()
        for entry in entries { addToolTip(entry.hitRect, owner: self, userData: nil) }
        window?.invalidateCursorRects(for: self)
        return appeared
    }

    private func makeLayer() -> CALayer {
        let layer = CALayer()
        layer.cornerRadius = Self.barWidth / 2
        self.layer?.addSublayer(layer)
        layers.append(layer)
        return layer
    }

    private func fadeIn(_ layer: CALayer) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = Self.fadeInDuration
        layer.add(fade, forKey: "fadeIn")
    }

    private func entry(at point: NSPoint) -> (hitRect: CGRect, bar: CommandStatusBar)? {
        entries.first { $0.hitRect.contains(point) }
    }

    // MARK: Mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        entry(at: convert(point, from: superview)) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        guard let entry = entry(at: convert(event.locationInWindow, from: nil)) else { return }
        onSelect?(entry.bar.promptRow)
    }

    override func resetCursorRects() {
        for entry in entries { addCursorRect(entry.hitRect, cursor: .pointingHand) }
    }

    nonisolated func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        MainActor.assumeIsolated { entry(at: point)?.bar.outcome.summary ?? "" }
    }
}
