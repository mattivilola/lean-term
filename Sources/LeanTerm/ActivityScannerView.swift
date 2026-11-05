import AppKit
import LeanTermCore
import QuartzCore

/// A 2pt "Knight Rider" line shown above the terminal while a command runs.
///
/// The sweep is a single Core Animation animation owned by the render server, so there is no per-frame
/// main-thread work. The view never draws and never overlaps the terminal.
@MainActor
final class ActivityScannerView: NSView {
    private static let sweepKey = "sweep"
    private static let sweepDuration: CFTimeInterval = 1.4
    private static let fadeDuration: CFTimeInterval = 0.25

    private let track = CALayer()
    private let replicator = CAReplicatorLayer()
    private let blob = CAGradientLayer()
    private var accent = NSColor.controlAccentColor
    private var hostTint: NSColor?
    private var indicator: ActivityIndicator = .idle
    private var visible = false
    private var animatedWidth: CGFloat?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 2) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        setAccessibilityElement(false)

        track.opacity = 0
        blob.startPoint = CGPoint(x: 0, y: 0.5)
        blob.endPoint = CGPoint(x: 1, y: 0.5)
        blob.cornerRadius = 1
        replicator.instanceCount = 4
        // Positive delay makes each copy lag the lead blob, which reads as a fading trail.
        replicator.instanceDelay = 0.07
        replicator.instanceAlphaOffset = -0.25
        replicator.isHidden = true
        replicator.addSublayer(blob)
        layer?.addSublayer(track)
        layer?.addSublayer(replicator)
        layer?.opacity = 0
        applyAccent(accent)
    }

    required init?(coder: NSCoder) { fatalError("Programmatic views only") }

    func applyAccent(_ color: NSColor) {
        accent = color
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        blob.colors = [color.withAlphaComponent(0).cgColor, color.cgColor, color.withAlphaComponent(0).cgColor]
        CATransaction.commit()
        render()
    }

    /// A steady line in the colour of a matching host rule while idle (remote sessions are always idle).
    func setHostTint(_ color: NSColor?) {
        guard color != hostTint else { return }
        hostTint = color
        render()
    }

    func setIndicator(_ indicator: ActivityIndicator, visible: Bool) {
        guard indicator != self.indicator || visible != self.visible || needsSweepRestore(indicator, visible) else { return }
        self.indicator = indicator
        self.visible = visible
        render()
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        replicator.frame = bounds
        let blobWidth = max(40, width * 0.18)
        blob.bounds = CGRect(x: 0, y: 0, width: blobWidth, height: bounds.height)
        blob.position = CGPoint(x: blobWidth / 2, y: bounds.height / 2)
        CATransaction.commit()
        if animatedWidth != nil, animatedWidth != width { removeSweep(); render() }
    }

    /// Reduce Motion or Low Power Mode changed: re-evaluate even though the indicator did not.
    func motionOptionsChanged() { render() }

    private var isSweeping: Bool { blob.animation(forKey: Self.sweepKey) != nil }

    /// Self-heals a sweep that Core Animation dropped while our visibility flag never changed.
    private func needsSweepRestore(_ indicator: ActivityIndicator, _ visible: Bool) -> Bool {
        indicator == .sweeping && visible && motionAllowed && !isSweeping
    }

    private var motionAllowed: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private func render() {
        guard let root = layer else { return }
        let steadyTint = indicator == .idle ? hostTint : nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.backgroundColor = (steadyTint ?? accent).cgColor
        CATransaction.commit()
        switch indicator {
        case .idle:
            if steadyTint != nil {
                fade(root, to: 1)
                removeSweep()
                setStatic(trackOpacity: 0.85, blobVisible: false)
            } else if visible, animatedWidth != nil {
                // Let the fade finish before freezing the blob.
                CATransaction.begin()
                CATransaction.setAnimationDuration(Self.fadeDuration)
                CATransaction.setCompletionBlock { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.indicator == .idle else { return }
                        self.removeSweep()
                    }
                }
                root.opacity = 0
                CATransaction.commit()
            } else {
                fade(root, to: 0)
                removeSweep()
            }
        case .sweeping:
            fade(root, to: 1)
            if motionAllowed {
                setStatic(trackOpacity: 0.12, blobVisible: true)
                if visible { addSweep() } else { removeSweep() }
            } else {
                removeSweep()
                setStatic(trackOpacity: 0.7, blobVisible: false)
            }
        case .holding:
            fade(root, to: 1)
            removeSweep()
            setStatic(trackOpacity: 0.3, blobVisible: false)
        }
        setAccessibilityElement(indicator == .sweeping)
        setAccessibilityRole(indicator == .sweeping ? .progressIndicator : nil)
        setAccessibilityLabel(indicator == .sweeping ? "Command running" : nil)
    }

    private func fade(_ root: CALayer, to opacity: Float) {
        guard root.opacity != opacity else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.fadeDuration)
        root.opacity = opacity
        CATransaction.commit()
    }

    private func setStatic(trackOpacity: Float, blobVisible: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.opacity = trackOpacity
        replicator.isHidden = !blobVisible
        CATransaction.commit()
    }

    private func addSweep() {
        let width = bounds.width
        guard blob.animation(forKey: Self.sweepKey) == nil, width > 0 else { return }
        let half = blob.bounds.width / 2
        guard width > half * 2 else { return }
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = half
        sweep.toValue = width - half
        sweep.duration = Self.sweepDuration
        sweep.autoreverses = true
        sweep.repeatCount = .infinity
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sweep.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        blob.add(sweep, forKey: Self.sweepKey)
        animatedWidth = width
    }

    private func removeSweep() {
        guard animatedWidth != nil || blob.animation(forKey: Self.sweepKey) != nil else { return }
        blob.removeAnimation(forKey: Self.sweepKey)
        animatedWidth = nil
    }
}
