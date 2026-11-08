import AppKit
import QuartzCore

/// Rounded phosphor rectangles over the visible find matches, the current one stronger with a 1 px border.
/// A child of the terminal view that never draws and ignores the mouse; layers are pooled and only touched
/// when the set of rectangles changes.
@MainActor
final class FindHighlightView: NSView {
    private static let maximumLayers = 2_000
    private var others: [CALayer] = []
    private var currents: [CALayer] = []
    private var phosphor = NSColor.systemGreen
    private var shown: (others: [CGRect], current: [CGRect]) = ([], [])

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        autoresizingMask = [.width, .height]
        isHidden = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("Programmatic views only") }

    func applyColor(_ phosphor: NSColor) {
        self.phosphor = phosphor
        withoutActions {
            for layer in others { style(layer, current: false) }
            for layer in currents { style(layer, current: true) }
        }
    }

    private func style(_ layer: CALayer, current: Bool) {
        layer.cornerRadius = 3
        layer.backgroundColor = phosphor.withAlphaComponent(current ? 0.45 : 0.22).cgColor
        layer.borderWidth = current ? 1 : 0
        layer.borderColor = current ? phosphor.cgColor : nil
    }

    /// Shows the rectangles (view coordinates) of the matches, and those of the current match (one per row it
    /// covers) stronger on top. Does nothing when they are unchanged.
    func show(others rects: [CGRect], current: [CGRect]) {
        guard rects != shown.others || current != shown.current else { return }
        shown = (rects, current)
        isHidden = rects.isEmpty && current.isEmpty
        withoutActions {
            place(rects.prefix(Self.maximumLayers), in: &others, current: false)
            place(current[...], in: &currents, current: true)
        }
    }

    private func place(_ rects: ArraySlice<CGRect>, in pool: inout [CALayer], current: Bool) {
        while pool.count < rects.count {
            let layer = CALayer()
            style(layer, current: current)
            // The current match stays above the others.
            if current { self.layer?.addSublayer(layer) } else { self.layer?.insertSublayer(layer, at: 0) }
            pool.append(layer)
        }
        for (index, layer) in pool.enumerated() {
            if index < rects.count {
                layer.frame = rects[rects.startIndex + index]
                layer.isHidden = false
            } else {
                layer.isHidden = true
            }
        }
    }

    func clear() { show(others: [], current: []) }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }
}
