import AppKit

/// A small, static dot shown in the window tab: filled while a command runs, a ring when a long
/// command finished in a tab nobody was looking at.
@MainActor
final class TabActivityView: NSView {
    enum Mark { case hidden, running, done }

    private let dot = CAShapeLayer()
    private var accent = NSColor.controlAccentColor
    private(set) var mark: Mark = .hidden

    override var intrinsicContentSize: NSSize { NSSize(width: 14, height: 14) }

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        dot.path = CGPath(ellipseIn: CGRect(x: 4, y: 4, width: 6, height: 6), transform: nil)
        layer?.addSublayer(dot)
        isHidden = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("Programmatic views only") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.frame = bounds
        CATransaction.commit()
    }

    func applyAccent(_ color: NSColor) {
        accent = color
        render()
    }

    func setMark(_ mark: Mark) {
        guard mark != self.mark else { return }
        self.mark = mark
        render()
    }

    private func render() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch mark {
        case .hidden:
            break
        case .running:
            dot.fillColor = accent.cgColor
            dot.strokeColor = nil
            dot.lineWidth = 0
        case .done:
            dot.fillColor = nil
            dot.strokeColor = accent.cgColor
            dot.lineWidth = 1.5
        }
        CATransaction.commit()
        isHidden = mark == .hidden
        setAccessibilityElement(mark != .hidden)
        setAccessibilityLabel(mark == .running ? "Command running" : (mark == .done ? "Command finished" : nil))
    }
}
