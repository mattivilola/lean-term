import AppKit
import LeanTermCore
import SwiftTerm
import Synchronization

/// Terminal view that reports the bell to the app without making any sound,
/// accepts dropped files and text, and confirms multi-line pastes.
final class LeanTerminalView: LocalProcessTerminalView {
    private let bellPending = Atomic<Bool>(false)
    /// Called on the main thread, at most once per burst of bells.
    var onBell: (@MainActor () -> Void)?
    /// Whether a multi-line paste into a program without bracketed paste needs confirmation.
    var confirmsMultilinePaste = true
    /// Turns the confirmation preference off after the user ticks "Don't ask again".
    var onDisableMultilinePasteConfirmation: (@MainActor () -> Void)?
    private var pasteConfirmationShowing = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes([.fileURL, .string])
    }

    /// Runs on the parse thread: only touches the atomic, then hops to the main thread once per burst.
    nonisolated override func bell(source: Terminal) {
        super.bell(source: source)
        guard bellPending.compareExchange(expected: false, desired: true, ordering: .relaxed).exchanged else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.bellPending.store(false, ordering: .relaxed)
                self.onBell?()
            }
        }
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropContent(from: sender.draggingPasteboard) == nil ? [] : .copy
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropContent(from: sender.draggingPasteboard) == nil ? [] : .copy
    }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropContent(from: sender.draggingPasteboard) != nil
    }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let content = dropContent(from: sender.draggingPasteboard) else { return false }
        // SwiftTerm's paste path honours bracketed paste mode; no newline is ever appended.
        // Escaped file paths are single-line; dropped text gets the same confirmation as a paste.
        if content.isFiles { pasteText(content.text) }
        else { confirmIfNeeded(text: content.text) { [weak self] in self?.pasteText(content.text) } }
        return true
    }

    private func dropContent(from pasteboard: NSPasteboard) -> (text: String, isFiles: Bool)? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return (urls.map { ShellEscape.path($0.path) }.joined(separator: " ") + " ", true)
        }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return nil }
        return (text, false)
    }

    // MARK: Paste confirmation

    /// Every paste (⌘V, Edit › Paste) arrives here, so one check covers menus and shortcuts.
    override func paste(_ sender: Any) {
        confirmIfNeeded(text: NSPasteboard.general.string(forType: .string)) { [weak self] in self?.performPaste(sender) }
    }

    private func performPaste(_ sender: Any) { super.paste(sender) }

    /// Runs `proceed` now, or after the user accepts a sheet when `text` has several lines and the
    /// program is not using bracketed paste.
    private func confirmIfNeeded(text: String?, then proceed: @escaping @MainActor () -> Void) {
        guard confirmsMultilinePaste, !pasteConfirmationShowing, let window, let text,
              terminalInputStateSnapshot()?.bracketedPasteMode != true else {
            proceed()
            return
        }
        var body = Substring(text)
        if body.last?.isNewline == true { body = body.dropLast() }
        let lines = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard lines.count > 1 else {
            proceed()
            return
        }
        var preview = lines.prefix(3).map { line in
            line.count > 80 ? String(line.prefix(80)) + "…" : String(line)
        }.joined(separator: "\n")
        if lines.count > 3 { preview += "\n…" }
        let alert = NSAlert()
        alert.messageText = "Paste \(lines.count) lines?"
        alert.informativeText = "This program isn't using bracketed paste, so each line may run as a command.\n\n" + preview
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        pasteConfirmationShowing = true
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                self?.pasteConfirmationShowing = false
                if alert.suppressionButton?.state == .on { self?.onDisableMultilinePasteConfirmation?() }
                if response == .alertFirstButtonReturn { proceed() }
            }
        }
    }
}
