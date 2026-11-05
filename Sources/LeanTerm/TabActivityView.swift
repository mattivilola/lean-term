import AppKit

/// What the tab says about the session itself, beside the activity dot.
enum SessionMark: Equatable {
    case none
    /// The associated value is the tooltip and accessibility description.
    case remote(String)
    case root
}

/// Static marks shown in the window tab: an optional leading symbol for remote and root sessions, and a dot
/// that is filled while a command runs or a ring when a long command finished in a tab nobody was looking at.
@MainActor
final class TabActivityView: NSView {
    enum Mark { case hidden, running, done }

    private static let dotSize: CGFloat = 14
    private static let symbolSize: CGFloat = 14
    private let dotView = DotView()
    private let symbol = NSImageView()
    private var phosphor = NSColor.controlAccentColor
    private var amber = NSColor.systemOrange
    private(set) var mark: Mark = .hidden
    private(set) var session: SessionMark = .none

    private var showsSymbol: Bool { session != .none }
    private var showsDot: Bool { mark != .hidden }

    override var intrinsicContentSize: NSSize {
        let width = (showsSymbol ? Self.symbolSize : 0) + (showsDot ? Self.dotSize : 0)
        return NSSize(width: max(width, Self.dotSize), height: Self.dotSize)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.dotSize, height: Self.dotSize))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        symbol.imageScaling = .scaleNone
        symbol.isHidden = true
        dotView.isHidden = true
        addSubview(symbol)
        addSubview(dotView)
        isHidden = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("Programmatic views only") }

    override func layout() {
        super.layout()
        let symbolWidth = showsSymbol ? Self.symbolSize : 0
        symbol.frame = NSRect(x: 0, y: 0, width: symbolWidth, height: bounds.height)
        dotView.frame = NSRect(x: symbolWidth, y: 0, width: Self.dotSize, height: bounds.height)
    }

    func applyColors(phosphor: NSColor, amber: NSColor) {
        self.phosphor = phosphor
        self.amber = amber
        render()
    }

    func setMark(_ mark: Mark) {
        guard mark != self.mark else { return }
        self.mark = mark
        render()
    }

    func setSession(_ session: SessionMark) {
        guard session != self.session else { return }
        self.session = session
        render()
    }

    private func render() {
        dotView.apply(mark, color: phosphor)
        dotView.isHidden = !showsDot
        switch session {
        case .none:
            symbol.image = nil
            symbol.toolTip = nil
            toolTip = nil
        case .remote(let description):
            show(symbol: "network", description: description)
        case .root:
            show(symbol: "number", description: "Running as root")
        }
        symbol.isHidden = !showsSymbol
        symbol.contentTintColor = amber
        isHidden = !showsSymbol && !showsDot
        setAccessibilityElement(!isHidden)
        setAccessibilityLabel(accessibilityDescription())
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func show(symbol name: String, description: String) {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)
        symbol.image = image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .medium))
        symbol.toolTip = description
        toolTip = description
    }

    private func accessibilityDescription() -> String? {
        var parts: [String] = []
        switch session {
        case .none: break
        case .remote(let description): parts.append(description)
        case .root: parts.append("Running as root")
        }
        switch mark {
        case .hidden: break
        case .running: parts.append("Command running")
        case .done: parts.append("Command finished")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// The dot itself: a filled circle while running, a ring when done.
@MainActor
private final class DotView: NSView {
    private let shape = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        shape.path = CGPath(ellipseIn: CGRect(x: 4, y: 4, width: 6, height: 6), transform: nil)
        layer?.addSublayer(shape)
    }

    required init?(coder: NSCoder) { fatalError("Programmatic views only") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        CATransaction.commit()
    }

    func apply(_ mark: TabActivityView.Mark, color: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch mark {
        case .hidden:
            break
        case .running:
            shape.fillColor = color.cgColor
            shape.strokeColor = nil
            shape.lineWidth = 0
        case .done:
            shape.fillColor = nil
            shape.strokeColor = color.cgColor
            shape.lineWidth = 1.5
        }
        CATransaction.commit()
    }
}
