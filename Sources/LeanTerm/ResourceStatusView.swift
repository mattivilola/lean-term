import AppKit
import LeanTermCore

@MainActor
final class ResourceStatusView: NSView {
    private let cpuLabel = NSTextField(labelWithString: "CPU —")
    private let memoryLabel = NSTextField(labelWithString: "MEM —")
    private let cpuGraph = ResourceSparklineView()
    private let memoryGraph = ResourceSparklineView()

    override var intrinsicContentSize: NSSize { NSSize(width: 228, height: 18) }

    convenience init() {
        self.init(frame: .zero)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let cpuRow = NSStackView(views: [cpuLabel, cpuGraph])
        cpuRow.orientation = .horizontal
        cpuRow.spacing = 4
        let memoryRow = NSStackView(views: [memoryLabel, memoryGraph])
        memoryRow.orientation = .horizontal
        memoryRow.spacing = 4
        let row = NSStackView(views: [cpuRow, memoryRow])
        row.orientation = .horizontal
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        for label in [cpuLabel, memoryLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byClipping
            label.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        cpuLabel.alignment = .right
        memoryLabel.alignment = .right
        cpuGraph.setContentHuggingPriority(.required, for: .horizontal)
        memoryGraph.setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 18),
            cpuLabel.widthAnchor.constraint(equalToConstant: 60),
            memoryLabel.widthAnchor.constraint(equalToConstant: 86),
            cpuGraph.widthAnchor.constraint(equalToConstant: 32),
            memoryGraph.widthAnchor.constraint(equalToConstant: 32)
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        applyAccent(.controlAccentColor)
        update(ProcessMetricsSnapshot())
    }

    required init?(coder: NSCoder) { fatalError("Programmatic views only") }

    func update(_ snapshot: ProcessMetricsSnapshot) {
        switch snapshot.status {
        case .paused:
            cpuLabel.stringValue = "CPU paused"
            memoryLabel.stringValue = "MEM paused"
        case .sampling:
            cpuLabel.stringValue = snapshot.cpuPercent.map(Self.cpuText) ?? "CPU —"
            memoryLabel.stringValue = snapshot.physicalFootprintBytes.map(Self.memoryText) ?? "MEM …"
        case .available:
            cpuLabel.stringValue = snapshot.cpuPercent.map(Self.cpuText) ?? "CPU —"
            memoryLabel.stringValue = snapshot.physicalFootprintBytes.map(Self.memoryText) ?? "MEM —"
        case .unavailable:
            cpuLabel.stringValue = "CPU n/a"
            memoryLabel.stringValue = "MEM n/a"
        }

        cpuGraph.values = snapshot.cpuHistory.map { value in
            value.map { $0 / snapshot.cpuScalePercent }
        }
        memoryGraph.values = snapshot.memoryHistory.map { value in
            value.map { Double($0) / Double(snapshot.memoryScaleBytes) }
        }

        let message = accessibilityDescription(for: snapshot)
        setAccessibilityLabel(message)
        setAccessibilityValue(message)
        toolTip = message
    }

    func applyAccent(_ color: NSColor) {
        cpuGraph.accentColor = color
        memoryGraph.accentColor = color
    }

    private func accessibilityDescription(for snapshot: ProcessMetricsSnapshot) -> String {
        let cpuScale = String(format: "%.0f%%", locale: Locale(identifier: "en_US_POSIX"), snapshot.cpuScalePercent)
        let memoryScaleMiB = snapshot.memoryScaleBytes / (1024 * 1024)
        let scales = "Sparkline scales: CPU 0–\(cpuScale) of one core; memory 0–\(memoryScaleMiB) MiB physical footprint."
        let description: String
        switch snapshot.status {
        case .paused:
            description = "Process resource sampling paused. CPU is percent of one core. Memory is this app’s physical footprint in MiB. Child processes and helpers are excluded."
        case .sampling:
            description = "Sampling this app’s process resources. CPU is percent of one core. Memory is physical footprint in MiB. Child processes and helpers are excluded."
        case .unavailable:
            description = "Process resource readings unavailable. CPU is percent of one core. Memory is physical footprint in MiB. Child processes and helpers are excluded."
        case .available:
            let cpu = snapshot.cpuPercent.map { "\(Self.cpuText($0)) of one core" } ?? "waiting for a second CPU reading"
            let memory = snapshot.physicalFootprintBytes.map { "\(Self.memoryText($0)) physical footprint" } ?? "unavailable"
            description = "Lean Term only: \(cpu); \(memory). Child processes and helpers are excluded."
        }
        return "\(description) \(scales)"
    }

    private static func cpuText(_ percent: Double) -> String {
        if percent < 0.1 { return "CPU <0.1%" }
        return "CPU \(String(format: percent < 10 ? "%.1f%%" : "%.0f%%", locale: Locale(identifier: "en_US_POSIX"), percent))"
    }

    private static func memoryText(_ bytes: UInt64) -> String {
        let mebibytes = Double(bytes) / Double(1024 * 1024)
        let format = mebibytes < 1000 ? "%.1f" : "%.0f"
        return "MEM \(String(format: format, locale: Locale(identifier: "en_US_POSIX"), mebibytes)) MiB"
    }
}

@MainActor
private final class ResourceSparklineView: NSView {
    var values: [Double?] = [] { didSet { setNeedsDisplay(bounds) } }
    var accentColor: NSColor = .controlAccentColor { didSet { setNeedsDisplay(bounds) } }

    override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 14) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let inset: CGFloat = 1
        let baselineY = bounds.minY + inset
        let baseline = NSBezierPath()
        baseline.lineWidth = 0.5
        baseline.move(to: NSPoint(x: bounds.minX, y: baselineY))
        baseline.line(to: NSPoint(x: bounds.maxX, y: baselineY))
        NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
        baseline.stroke()

        guard values.count > 0 else { return }
        let usableHeight = max(1, bounds.height - inset * 2)
        let denominator = max(1, values.count - 1)
        let path = NSBezierPath()
        path.lineWidth = 1.25
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        var hasPoint = false
        var segmentLength = 0
        var isolatedPoint: NSPoint?
        let dots = NSBezierPath()

        for (index, value) in values.enumerated() {
            guard let value, value.isFinite else {
                if segmentLength == 1, let isolatedPoint {
                    dots.appendOval(in: NSRect(x: isolatedPoint.x - 1, y: isolatedPoint.y - 1,
                                               width: 2, height: 2))
                }
                hasPoint = false
                segmentLength = 0
                isolatedPoint = nil
                continue
            }
            let fraction = min(1, max(0, value))
            let point = NSPoint(x: bounds.minX + inset + (bounds.width - inset * 2) * CGFloat(index) / CGFloat(denominator),
                                y: bounds.minY + inset + usableHeight * CGFloat(fraction))
            if hasPoint {
                path.line(to: point)
                segmentLength += 1
                isolatedPoint = nil
            } else {
                path.move(to: point)
                segmentLength = 1
                isolatedPoint = point
            }
            hasPoint = true
        }

        if segmentLength == 1, let isolatedPoint {
            dots.appendOval(in: NSRect(x: isolatedPoint.x - 1, y: isolatedPoint.y - 1,
                                       width: 2, height: 2))
        }
        accentColor.withAlphaComponent(0.95).setStroke()
        path.stroke()
        accentColor.withAlphaComponent(0.95).setFill()
        dots.fill()
    }
}
