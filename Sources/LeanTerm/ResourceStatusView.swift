import AppKit
import LeanTermCore

@MainActor
final class ResourceStatusView: NSView {
    let cpuButton = NSButton(title: "CPU —", target: nil, action: nil)
    let memoryButton = NSButton(title: "MEM —", target: nil, action: nil)
    var focusedProcesses: () -> [PaneProcessUsage] = { [] }
    private let breakdown = NSPopover()
    private let cpuGraph = ResourceSparklineView()
    private let memoryGraph = ResourceSparklineView()
    private static let cpuWidth: CGFloat = 104
    private static let memoryWidth: CGFloat = 120
    private static let rowSpacing: CGFloat = 8
    private static let graphWidth: CGFloat = 32
    private static let graphSpacing: CGFloat = 4

    var showsSparklines = true {
        didSet {
            guard showsSparklines != oldValue else { return }
            cpuGraph.isHidden = !showsSparklines
            memoryGraph.isHidden = !showsSparklines
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        let labels = Self.cpuWidth + Self.memoryWidth + Self.rowSpacing
        let graphs = showsSparklines ? 2 * (Self.graphWidth + Self.graphSpacing) : 0
        return NSSize(width: labels + graphs, height: 18)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let cpuRow = NSStackView(views: [cpuButton, cpuGraph])
        cpuRow.orientation = .horizontal
        cpuRow.spacing = Self.graphSpacing
        let memoryRow = NSStackView(views: [memoryButton, memoryGraph])
        memoryRow.orientation = .horizontal
        memoryRow.spacing = Self.graphSpacing
        let row = NSStackView(views: [cpuRow, memoryRow])
        row.orientation = .horizontal
        row.spacing = Self.rowSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        for button in [cpuButton, memoryButton] {
            button.isBordered = false
            button.alignment = .right
            button.lineBreakMode = .byClipping
            button.target = self
            button.action = #selector(showBreakdown(_:))
        }
        breakdown.behavior = .transient
        cpuGraph.setContentHuggingPriority(.required, for: .horizontal)
        memoryGraph.setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 18),
            cpuButton.widthAnchor.constraint(equalToConstant: Self.cpuWidth),
            memoryButton.widthAnchor.constraint(equalToConstant: Self.memoryWidth),
            cpuGraph.widthAnchor.constraint(equalToConstant: Self.graphWidth),
            memoryGraph.widthAnchor.constraint(equalToConstant: Self.graphWidth)
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        applyAccent(.controlAccentColor)
        update(total: ProcessMetricsSnapshot(), pane: nil)
    }

    required init?(coder: NSCoder) { fatalError("Programmatic views only") }

    func update(total: ProcessMetricsSnapshot, pane: ProcessMetricsUsage?) {
        let description: String
        switch total.status {
        case .paused:
            setText("CPU paused", "MEM paused")
            description = "Resource sampling paused."
        case .sampling:
            setText("CPU … (…)", "MEM … (…)")
            description = "Sampling local process usage."
        case .unavailable:
            setText("CPU n/a", "MEM n/a")
            description = "Local process usage unavailable."
        case .available:
            let paneCPU = pane?.cpuPercent.map(Self.cpuText) ?? "—"
            let totalCPU = total.cpuPercent.map(Self.cpuText) ?? "—"
            let paneMemory = pane.map { Self.memoryText($0.physicalFootprintBytes) } ?? "—"
            let totalMemory = total.physicalFootprintBytes.map(Self.memoryText) ?? "—"
            setText("CPU \(paneCPU) (\(totalCPU))", "MEM \(paneMemory) (\(totalMemory)) MiB")
            description = "Focused pane: CPU \(paneCPU), memory \(paneMemory) MiB. Lean Term total: CPU \(totalCPU), memory \(totalMemory) MiB."
        }

        cpuGraph.values = total.cpuHistory.map { value in
            value.map { $0 / total.cpuScalePercent }
        }
        memoryGraph.values = total.memoryHistory.map { value in
            value.map { Double($0) / Double(total.memoryScaleBytes) }
        }

        let details = "The first value covers the pane’s local shell and its child processes. The total includes Lean Term and its local child processes across all sessions. CPU is percent of one core. Memory is the sum of process footprints. Short-lived or unreadable processes can be missed. Remote host usage is separate."
        let cpuScale = total.cpuScalePercent.formatted(.number.precision(.fractionLength(0)))
        let memoryScale = (total.memoryScaleBytes / (1024 * 1024)).formatted()
        let scales = "Sparklines track totals. CPU scale: 0–\(cpuScale)%. Memory scale: 0–\(memoryScale) MiB."
        let message = "\(description) \(details) \(scales)"
        setAccessibilityLabel(message)
        toolTip = message
        cpuButton.toolTip = "Show the focused pane’s processes by CPU. \(message)"
        memoryButton.toolTip = "Show the focused pane’s processes by memory. \(message)"
    }

    private func setText(_ cpu: String, _ memory: String) {
        for (button, title, metric) in [(cpuButton, cpu, "CPU"), (memoryButton, memory, "Memory")] {
            guard button.attributedTitle.string != title else { continue }
            button.attributedTitle = NSAttributedString(string: title, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor
            ])
            button.setAccessibilityLabel("\(title). Show processes by \(metric)")
        }
    }

    func closeProcessBreakdown() { breakdown.close() }

    var isProcessBreakdownShown: Bool { breakdown.isShown }

    @objc private func showBreakdown(_ sender: NSButton) {
        if breakdown.isShown {
            breakdown.close()
            return
        }
        let byCPU = sender === cpuButton
        let processes = focusedProcesses().sorted {
            if byCPU {
                let left = $0.cpuPercent ?? -1
                let right = $1.cpuPercent ?? -1
                if left != right { return left > right }
            } else if $0.physicalFootprintBytes != $1.physicalFootprintBytes {
                return $0.physicalFootprintBytes > $1.physicalFootprintBytes
            }
            return $0.pid < $1.pid
        }
        let title = NSTextField(labelWithString: byCPU ? "Pane processes by CPU" : "Pane processes by memory")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        content.addArrangedSubview(title)
        if processes.isEmpty {
            content.addArrangedSubview(NSTextField(labelWithString: "No local process readings yet."))
        } else {
            let heading = ["Process", "PID", "CPU", "Memory"].map {
                let label = NSTextField(labelWithString: $0)
                label.font = .systemFont(ofSize: 11, weight: .medium)
                label.textColor = .secondaryLabelColor
                return label
            }
            let rows = processes.prefix(8).map { process in
                [process.name, String(process.pid), process.cpuPercent.map(Self.cpuText) ?? "—",
                 "\(Self.memoryText(process.physicalFootprintBytes)) MiB"].map {
                    let label = NSTextField(labelWithString: $0)
                    label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
                    return label
                }
            }
            let grid = NSGridView(views: [heading] + rows)
            grid.columnSpacing = 12
            grid.rowSpacing = 4
            for column in 1..<grid.numberOfColumns { grid.column(at: column).xPlacement = .trailing }
            content.addArrangedSubview(grid)
            let detail = NSTextField(labelWithString: "Local snapshot · \(rows.count) of \(processes.count) processes")
            detail.font = .systemFont(ofSize: 10)
            detail.textColor = .secondaryLabelColor
            content.addArrangedSubview(detail)
        }
        let controller = NSViewController()
        controller.view = content
        breakdown.contentViewController = controller
        breakdown.contentSize = content.fittingSize
        breakdown.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    func applyAccent(_ color: NSColor) {
        cpuGraph.accentColor = color
        memoryGraph.accentColor = color
    }

    private static func cpuText(_ percent: Double) -> String {
        if percent < 0.1 { return "<0.1%" }
        return percent.formatted(.number.precision(.fractionLength(percent < 10 ? 1 : 0))) + "%"
    }

    private static func memoryText(_ bytes: UInt64) -> String {
        let mebibytes = Double(bytes) / Double(1024 * 1024)
        return mebibytes.formatted(.number.precision(.fractionLength(mebibytes < 1000 ? 1 : 0)))
    }
}

@MainActor
private final class ResourceSparklineView: NSView {
    var values: [Double?] = [] { didSet { if values != oldValue { updatePaths() } } }
    var accentColor: NSColor = .controlAccentColor { didSet { updateColors() } }

    private let baselineLayer = CAShapeLayer()
    private let lineLayer = CAShapeLayer()
    private let dotsLayer = CAShapeLayer()

    override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 14) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        baselineLayer.lineWidth = 0.5
        baselineLayer.fillColor = nil
        lineLayer.lineWidth = 1.25
        lineLayer.lineCap = .round
        lineLayer.lineJoin = .round
        lineLayer.fillColor = nil
        dotsLayer.strokeColor = nil
        for shape in [baselineLayer, lineLayer, dotsLayer] {
            shape.actions = ["path": NSNull(), "strokeColor": NSNull(), "fillColor": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer?.addSublayer(shape)
        }
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("Programmatic views only") }

    override func layout() {
        super.layout()
        for shape in [baselineLayer, lineLayer, dotsLayer] { shape.frame = bounds }
        updatePaths()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            baselineLayer.strokeColor = NSColor.separatorColor.withAlphaComponent(0.55).cgColor
            lineLayer.strokeColor = accentColor.withAlphaComponent(0.95).cgColor
            dotsLayer.fillColor = accentColor.withAlphaComponent(0.95).cgColor
        }
    }

    private func updatePaths() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let inset: CGFloat = 1
        let baseline = CGMutablePath()
        baseline.move(to: CGPoint(x: bounds.minX, y: bounds.minY + inset))
        baseline.addLine(to: CGPoint(x: bounds.maxX, y: bounds.minY + inset))
        baselineLayer.path = baseline

        let usableHeight = max(1, bounds.height - inset * 2)
        let denominator = max(1, values.count - 1)
        let path = CGMutablePath()
        let dots = CGMutablePath()
        var hasPoint = false
        var segmentLength = 0
        var isolatedPoint: CGPoint?

        func closeSegment() {
            if segmentLength == 1, let isolatedPoint {
                dots.addEllipse(in: CGRect(x: isolatedPoint.x - 1, y: isolatedPoint.y - 1, width: 2, height: 2))
            }
            hasPoint = false
            segmentLength = 0
            isolatedPoint = nil
        }

        for (index, value) in values.enumerated() {
            guard let value, value.isFinite else { closeSegment(); continue }
            let fraction = min(1, max(0, value))
            let point = CGPoint(x: bounds.minX + inset + (bounds.width - inset * 2) * CGFloat(index) / CGFloat(denominator),
                                y: bounds.minY + inset + usableHeight * CGFloat(fraction))
            if hasPoint {
                path.addLine(to: point)
                segmentLength += 1
                isolatedPoint = nil
            } else {
                path.move(to: point)
                segmentLength = 1
                isolatedPoint = point
            }
            hasPoint = true
        }
        closeSegment()
        lineLayer.path = path
        dotsLayer.path = dots
    }
}
