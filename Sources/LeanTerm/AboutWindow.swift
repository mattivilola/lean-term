import AppKit

@MainActor
final class AboutWindow: NSWindowController {
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 385),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "About Lean Term"
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        let icon = NSImageView(image: NSImage(named: NSImage.applicationIconName) ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 88).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 88).isActive = true
        let title = Self.label("Lean Term", size: 28, weight: .semibold)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        let development = Bundle.main.object(forInfoDictionaryKey: "LeanTermReleaseBuild") as? Bool != true
        let versionLabel = Self.label("Version \(version)" + (development ? " · Development" : ""), size: 12)
        versionLabel.textColor = .secondaryLabelColor
        let credits = Self.label("Developed with ❤️ by Matti Vilola.", size: 14)
        let sponsor = Self.label("Sponsored and distributed by\nILO APPLICATIONS SL.", size: 12)
        sponsor.textColor = .secondaryLabelColor
        let website = NSButton(title: "Website", target: self, action: #selector(openWebsite))
        let source = NSButton(title: "Source Code", target: self, action: #selector(openSource))
        for button in [website, source] { button.bezelStyle = .rounded; button.controlSize = .small }
        let links = NSStackView(views: [website, source]); links.spacing = 12
        let name = NSStackView(views: [title, versionLabel]); name.orientation = .vertical; name.spacing = 5
        let creditGroup = NSStackView(views: [credits, sponsor]); creditGroup.orientation = .vertical; creditGroup.spacing = 10
        let stack = NSStackView(views: [icon, name, creditGroup, links])
        stack.orientation = .vertical; stack.alignment = .centerX; stack.spacing = 23
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 22),
            stack.widthAnchor.constraint(lessThanOrEqualTo: window.contentView!.widthAnchor, constant: -32)
        ])
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("Programmatic windows only") }
    private static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.alignment = .center
        return label
    }
    @objc private func openWebsite() { NSWorkspace.shared.open(URL(string: "https://leanterm.com")!) }
    @objc private func openSource() { NSWorkspace.shared.open(URL(string: "https://github.com/mattivilola/lean-term")!) }
}
