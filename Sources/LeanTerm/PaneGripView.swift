import AppKit
import QuartzCore

/// What a drag started on a pane's grip is doing.
enum PaneGripPhase { case began, moved, ended }

/// The top padding strip of a pane. Hovering it fades in a small grip (when the tab has several panes) that
/// starts a pane drag. The fade is Core Animation only; the only scheduled work is one cancellable work item
/// for the hover delay. Outside the grip itself the view ignores the mouse.
@MainActor
final class PaneGripView: NSView {
    static let stripHeight: CGFloat = 12
    private static let gripSize = CGSize(width: 24, height: 8)
    private static let hoverDelay: TimeInterval = 0.15
    private static let dragThreshold: CGFloat = 3

    /// Whether the pane may be dragged right now (several panes, not zoomed). Asked on hover.
    var isAvailable: () -> Bool = { false }
    var onDrag: (PaneGripPhase, NSPoint) -> Void = { _, _ in }

    private let grip = CAShapeLayer()
    private var enabled = false { didSet { if enabled != oldValue { window?.invalidateCursorRects(for: self) } } }
    private var hoverWork: DispatchWorkItem?
    private var downPoint: NSPoint?
    private var dragging = false

    private var gripRect: NSRect {
        NSRect(x: ((bounds.width - Self.gripSize.width) / 2).rounded(), y: ((bounds.height - Self.gripSize.height) / 2).rounded(),
               width: Self.gripSize.width, height: Self.gripSize.height)
    }

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setAccessibilityElement(false)
        grip.opacity = 0
        grip.lineWidth = 1.5
        grip.lineCap = .round
        grip.fillColor = nil
        let path = CGMutablePath()
        for y in [1.5, 4.0, 6.5] as [CGFloat] {
            path.move(to: CGPoint(x: 4, y: y))
            path.addLine(to: CGPoint(x: 20, y: y))
        }
        grip.path = path
        layer?.addSublayer(grip)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func applyTheme(_ theme: TerminalTheme) { grip.strokeColor = theme.foreground.withAlphaComponent(0.5).cgColor }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        grip.frame = gripRect
        CATransaction.commit()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        enabled && gripRect.contains(convert(point, from: superview)) ? self : nil
    }

    override func resetCursorRects() {
        if enabled { addCursorRect(gripRect, cursor: .openHand) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        guard isAvailable() else { return }
        enabled = true
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fade(to: 1, duration: 0.12) }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDelay, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        guard !dragging else { return }
        hide()
    }

    private func hide() {
        hoverWork?.cancel()
        hoverWork = nil
        enabled = false
        fade(to: 0, duration: 0.12)
    }

    private func fade(to opacity: Float, duration: CFTimeInterval) {
        let from = grip.presentation()?.opacity ?? grip.opacity
        grip.opacity = opacity
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = opacity
        animation.duration = duration
        grip.add(animation, forKey: "fade")
    }

    override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downPoint else { return }
        let point = event.locationInWindow
        if !dragging {
            guard hypot(point.x - start.x, point.y - start.y) > Self.dragThreshold else { return }
            dragging = true
            onDrag(.began, point)
        }
        onDrag(.moved, point)
    }

    override func mouseUp(with event: NSEvent) {
        let wasDragging = dragging
        downPoint = nil
        dragging = false
        if wasDragging { onDrag(.ended, event.locationInWindow) }
        // The pointer may have left the strip during the drag.
        if wasDragging || !bounds.contains(convert(event.locationInWindow, from: nil)) { hide() }
    }
}
