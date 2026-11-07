import AppKit
import LeanTermCore

/// A path from terminal output that exists on this machine.
struct ResolvedPath: Equatable {
    let url: URL
    let isDirectory: Bool
    let line: Int?
    let column: Int?
}

/// Resolves clicked paths against the shell's directory and opens files with the chosen editor.
@MainActor
enum FileOpener {
    static let leanVSCodeBundleID = "com.mattivilola.leanvscode"
    static let leanVSCodeScheme = "lean-code"
    static let leanVSCodeSite = URL(string: "https://leanvscode.com")!

    static var leanVSCodeURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: leanVSCodeBundleID)
    }

    /// Checks the file system; call only at click time or once per hovered token.
    static func resolve(_ detected: DetectedPath, relativeTo directory: String) -> ResolvedPath? {
        var candidates = [detected.path]
        if let stripped = PathDetection.strippingGitPrefix(detected.path) { candidates.append(stripped) }
        for candidate in candidates {
            let expanded = (candidate as NSString).expandingTildeInPath
            let url = (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded)
                : URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: directory, isDirectory: true)))
                .standardizedFileURL
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                return ResolvedPath(url: url, isDirectory: isDirectory.boolValue, line: detected.line, column: detected.column)
            }
        }
        return nil
    }

    static func open(_ file: ResolvedPath, with choice: Preferences.FileOpenerChoice) {
        let workspace = NSWorkspace.shared
        switch choice {
        case .leanVSCode:
            guard let app = leanVSCodeURL else { workspace.open(file.url); return }
            if let line = file.line, let url = leanVSCodeLink(for: file.url, line: line, column: file.column) {
                workspace.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            } else {
                workspace.open([file.url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            }
        case .system:
            workspace.open(file.url)
        case .app(let identifier):
            if let app = applicationURL(for: identifier) {
                workspace.open([file.url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            } else {
                workspace.open(file.url)
            }
        }
    }

    /// `lean-code://file/abs/path:line:column`, the same shape as VS Code's `vscode://file/…`.
    static func leanVSCodeLink(for file: URL, line: Int, column: Int?) -> URL? {
        guard let path = file.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "\(leanVSCodeScheme)://file\(path):\(line):\(column ?? 1)")
    }

    /// The app a saved choice refers to: a bundle identifier, or a path for apps without one.
    static func applicationURL(for identifier: String) -> URL? {
        if identifier.hasPrefix("/") {
            return FileManager.default.fileExists(atPath: identifier) ? URL(fileURLWithPath: identifier) : nil
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
    }

    static func displayName(ofApplicationAt url: URL) -> String {
        FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    /// The identifier to persist for an app the user picked.
    static func identifier(forApplicationAt url: URL) -> String {
        Bundle(url: url)?.bundleIdentifier ?? url.path
    }
}
