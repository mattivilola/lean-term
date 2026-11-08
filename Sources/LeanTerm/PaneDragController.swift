import AppKit
import LeanTermCore
import QuartzCore

/// Where a dragged pane would land: on one side of the target (`edge`), or swapped with it (nil).
struct PaneDrop: Equatable {
    let target: UUID
    let edge: PaneLayout.Edge?
}

/// A pane drag inside one tab. It follows the pointer events that the grip view receives, shows the drop
/// indicator over the pane area and reports the drop; the window applies it. Esc cancels. Created with the
/// window, idle (no timers, no monitors) until a drag begins.
@MainActor
final class PaneDragController {
    private static let dimmedAlpha: CGFloat = 0.6
    /// The central share of a pane (per axis) that means "swap".
    private static let swapZone: ClosedRange<CGFloat> = 0.35...0.65

    private let area: NSView
    private let indicator = DropIndicatorView()
    private var source: TerminalPane?
    private var drop: PaneDrop?
    private var keyMonitor: Any?
    private weak var window: NSWindow?

    init(area: NSView) { self.area = area }

    var isActive: Bool { source != nil }

    func begin(_ pane: TerminalPane, theme: TerminalTheme) {
        cancel()
        source = pane
        window = area.window
        pane.view.alphaValue = Self.dimmedAlpha
        indicator.apply(theme)
        window?.disableCursorRects()
        NSCursor.closedHand.set()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self, isActive else { return event }
            cancel()
            return nil
        }
    }

    func move(to windowPoint: NSPoint, panes: [TerminalPane]) {
        guard let source else { return }
        NSCursor.closedHand.set()
        let next = target(at: windowPoint, panes: panes, excluding: source)
        guard next?.drop != drop else { return }
        drop = next?.drop
        if let next {
            if indicator.superview == nil { area.addSubview(indicator) }
            indicator.show(frame: next.frame)
        } else {
            indicator.hide()
        }
    }

    /// Ends the drag and returns the dragged pane with where it was dropped, if anywhere.
    func finish(at windowPoint: NSPoint, panes: [TerminalPane]) -> (pane: TerminalPane, drop: PaneDrop)? {
        guard let source else { return nil }
        move(to: windowPoint, panes: panes)
        let result = drop.map { (source, $0) }
        cancel()
        return result
    }

    /// Ends the drag without dropping and restores the source pane.
    func cancel() {
        guard let source else { return }
        source.view.alphaValue = 1
        self.source = nil
        drop = nil
        indicator.hide()
        indicator.removeFromSuperview()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        window?.enableCursorRects()
        window?.resetCursorRects()
        NSCursor.arrow.set()
    }

    private func target(at windowPoint: NSPoint, panes: [TerminalPane], excluding source: TerminalPane) -> (drop: PaneDrop, frame: NSRect)? {
        let point = area.convert(windowPoint, from: nil)
        for pane in panes where pane !== source && pane.view.window != nil {
            let rect = area.convert(pane.view.bounds, from: pane.view)
            guard rect.contains(point) else { continue }
            let nx = (point.x - rect.minX) / rect.width
            let ny = area.isFlipped ? (point.y - rect.minY) / rect.height : (rect.maxY - point.y) / rect.height
            if Self.swapZone.contains(nx) && Self.swapZone.contains(ny) {
                return (PaneDrop(target: pane.id, edge: nil), rect)
            }
            let distances: [(PaneLayout.Edge, CGFloat)] = [(.left, nx), (.right, 1 - nx), (.top, ny), (.bottom, 1 - ny)]
            let edge = distances.min { $0.1 < $1.1 }?.0 ?? .left
            var half = rect
            switch edge {
            case .left: half.size.width /= 2
            case .right: half.size.width /= 2; half.origin.x = rect.midX
            case .top: half.size.height /= 2; half.origin.y = area.isFlipped ? rect.minY : rect.midY
            case .bottom: half.size.height /= 2; half.origin.y = area.isFlipped ? rect.midY : rect.minY
            }
            return (PaneDrop(target: pane.id, edge: edge), half)
        }
        return nil
    }
}

/// The phosphor overlay that shows where a dragged pane would land. Layer-based; its frame moves with a
/// short animation unless Reduce Motion is on. Ignores the mouse.
@MainActor
private final class DropIndicatorView: NSView {
    private static let duration: CFTimeInterval = 0.10
    private let box = CALayer()
    private var visible = false

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setAccessibilityElement(false)
        box.borderWidth = 1.5
        box.cornerRadius = 3
        box.opacity = 0
        layer?.addSublayer(box)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func apply(_ theme: TerminalTheme) {
        box.backgroundColor = theme.phosphor.withAlphaComponent(0.18).cgColor
        box.borderColor = theme.phosphor.cgColor
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let superview { frame = superview.bounds; autoresizingMask = [.width, .height] }
    }

    func show(frame target: NSRect) {
        let animate = visible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.duration)
        CATransaction.setDisableActions(!animate)
        box.frame = target
        CATransaction.commit()
        setVisible(true)
    }

    func hide() { setVisible(false) }

    private func setVisible(_ show: Bool) {
        guard visible != show else { return }
        visible = show
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.duration)
        box.opacity = show ? 1 : 0
        CATransaction.commit()
    }
}
