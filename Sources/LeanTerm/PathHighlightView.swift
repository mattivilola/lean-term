import AppKit
import QuartzCore

/// Colours of the ⌘-hover highlight, all taken from the terminal theme.
struct PathHighlightColors {
    let phosphor: NSColor
    let background: NSColor
    let foreground: NSColor
    let dark: Bool
}

/// The phosphor highlight shown over an existing path while ⌘ is held: a translucent fill, a glowing underline
/// and, once the pointer rests, a small hint label.
///
/// Created on the first ⌘-hover and reused. All motion is Core Animation owned by the render server; the only
/// scheduled work is one cancellable work item for the hint delay. The view never draws and ignores the mouse.
@MainActor
final class PathHighlightView: NSView {
    private static let fillFadeIn: CFTimeInterval = 0.10
    private static let underlineGrow: CFTimeInterval = 0.14
    private static let slide: CFTimeInterval = 0.10
    private static let fadeOut: CFTimeInterval = 0.12
    private static let hintDelay: TimeInterval = 0.35
    private static let underlineHeight: CGFloat = 1.5

    private let content = CALayer()
    private let fill = CALayer()
    private let underline = CALayer()
    private let label = CALayer()
    private let labelText = CATextLayer()
    private var colors: PathHighlightColors
    private var shown = false
    private var target: (rect: CGRect, hint: String)?
    private var hintWork: DispatchWorkItem?

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(colors: PathHighlightColors) {
        self.colors = colors
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        autoresizingMask = [.width, .height]
        isHidden = true
        setAccessibilityElement(false)

        fill.cornerRadius = 3
        underline.anchorPoint = CGPoint(x: 0, y: 0.5)
        underline.shadowOffset = .zero
        underline.shadowRadius = 5
        underline.shadowOpacity = 0.6
        label.cornerRadius = 4
        label.borderWidth = 1
        label.opacity = 0
        labelText.alignmentMode = .left
        labelText.isWrapped = false
        label.addSublayer(labelText)
        content.opacity = 0
        content.addSublayer(fill)
        content.addSublayer(underline)
        content.addSublayer(label)
        layer?.addSublayer(content)
        applyColors(colors)
    }

    required init?(coder: NSCoder) { fatalError("Programmatic views only") }

    func applyColors(_ colors: PathHighlightColors) {
        self.colors = colors
        withoutActions {
            fill.backgroundColor = colors.phosphor.withAlphaComponent(colors.dark ? 0.16 : 0.12).cgColor
            underline.backgroundColor = colors.phosphor.cgColor
            underline.shadowColor = colors.phosphor.cgColor
            label.backgroundColor = (colors.background.blended(withFraction: 0.08, of: colors.foreground) ?? colors.background).cgColor
            label.borderColor = colors.phosphor.withAlphaComponent(0.4).cgColor
        }
        if let target { setHint(target.hint) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        labelText.contentsScale = window?.backingScaleFactor ?? 2
    }

    override func layout() {
        super.layout()
        content.frame = bounds
    }

    // MARK: Showing and hiding

    /// Highlights `rect` (in this view's coordinates) and schedules `hint` for when the pointer rests.
    func show(rect: CGRect, hint: String) {
        if let target, target.rect == rect, target.hint == hint, shown { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let wasShown = shown
        shown = true
        isHidden = false
        target = (rect, hint)
        hintWork?.cancel()
        content.frame = bounds
        labelText.contentsScale = window?.backingScaleFactor ?? 2
        let underlineRect = CGRect(x: rect.minX, y: rect.minY + 1, width: rect.width, height: Self.underlineHeight)

        if wasShown {
            // Resize and move to the new token; the hint of the old one fades out meanwhile.
            transaction(duration: reduceMotion ? 0 : Self.slide, timing: .easeInEaseOut) {
                fill.bounds = CGRect(origin: .zero, size: rect.size)
                fill.position = CGPoint(x: rect.midX, y: rect.midY)
                underline.bounds = CGRect(origin: .zero, size: underlineRect.size)
                underline.position = CGPoint(x: underlineRect.minX, y: underlineRect.midY)
            }
            withoutActions { label.opacity = 0 }
        } else {
            withoutActions {
                fill.bounds = CGRect(origin: .zero, size: rect.size)
                fill.position = CGPoint(x: rect.midX, y: rect.midY)
                fill.opacity = 0
                underline.position = CGPoint(x: underlineRect.minX, y: underlineRect.midY)
                underline.bounds = CGRect(origin: .zero, size: CGSize(width: reduceMotion ? underlineRect.width : 0,
                                                                      height: underlineRect.height))
                underline.opacity = reduceMotion ? 0 : 1
                label.opacity = 0
                content.opacity = 1
            }
            transaction(duration: Self.fillFadeIn, timing: .easeOut) { fill.opacity = 1 }
            if reduceMotion {
                transaction(duration: Self.fillFadeIn, timing: .easeOut) { underline.opacity = 1 }
            } else {
                transaction(duration: Self.underlineGrow, timing: .easeOut) {
                    underline.bounds = CGRect(origin: .zero, size: underlineRect.size)
                }
            }
        }

        setHint(hint)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.showHint() }
        }
        hintWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hintDelay, execute: work)
    }

    /// Fades everything out, then hides the view. Keeps the layers for reuse.
    func hide() {
        guard shown else { return }
        shown = false
        target = nil
        hintWork?.cancel()
        hintWork = nil
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.fadeOut)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.shown else { return }
                self.isHidden = true
            }
        }
        content.opacity = 0
        CATransaction.commit()
    }

    // MARK: Hint

    private func setHint(_ hint: String) {
        let text = NSAttributedString(string: hint, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: colors.foreground
        ])
        let size = text.size()
        let textSize = CGSize(width: ceil(size.width) + 1, height: ceil(size.height))
        let labelSize = CGSize(width: textSize.width + 16, height: textSize.height + 8)
        withoutActions {
            labelText.string = text
            labelText.frame = CGRect(x: 8, y: 4, width: textSize.width, height: textSize.height)
            guard let rect = target?.rect else { return }
            // Above the token, or below it when the top edge is too close.
            let aboveY = rect.maxY + 4
            let y = aboveY + labelSize.height <= bounds.height ? aboveY : max(0, rect.minY - 4 - labelSize.height)
            let x = min(max(0, rect.minX), max(0, bounds.width - labelSize.width))
            label.frame = CGRect(origin: CGPoint(x: x, y: y), size: labelSize)
        }
    }

    private func showHint() {
        guard shown else { return }
        transaction(duration: Self.fillFadeIn, timing: .easeOut) { label.opacity = 1 }
    }

    // MARK: Transactions

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    private func transaction(duration: CFTimeInterval, timing: CAMediaTimingFunctionName, _ body: () -> Void) {
        CATransaction.begin()
        if duration > 0 {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: timing))
        } else {
            CATransaction.setDisableActions(true)
        }
        body()
        CATransaction.commit()
    }
}
