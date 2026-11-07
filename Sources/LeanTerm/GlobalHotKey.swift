import AppKit
import Carbon.HIToolbox
import LeanTermCore

/// One system-wide hot key registered through Carbon's `RegisterEventHotKey`, which needs no Accessibility permission.
///
/// Carbon delivers hot-key events on the main thread through a C callback that cannot capture state, so the
/// callback only hops to the main actor and calls the static `handler`.
@MainActor
final class GlobalHotKey {
    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            status == OSStatus(eventHotKeyExistsErr)
                ? "That shortcut is already used by another app or by macOS. Choose another combination."
                : "The shortcut could not be registered (error \(status))."
        }
    }

    private static var handler: (@MainActor () -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    var isRegistered: Bool { hotKeyRef != nil }

    func register(_ hotKey: QuickTerminalHotKey, action: @escaping @MainActor () -> Void) throws {
        unregister()
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), globalHotKeyCallback, 1, &eventType, nil, &handlerRef)
        guard installed == noErr else { handlerRef = nil; throw Failure(status: installed) }
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: OSType(0x4C54_5154), id: 1) // 'LTQT'
        let status = RegisterEventHotKey(hotKey.keyCode, Self.carbonModifiers(hotKey.shortcutModifiers), identifier,
                                         GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else {
            removeHandler()
            throw Failure(status: status)
        }
        hotKeyRef = reference
        Self.handler = action
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        Self.handler = nil
        removeHandler()
    }

    fileprivate static func fire() { handler?() }

    private func removeHandler() {
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
    }

    private static func carbonModifiers(_ modifiers: ShortcutModifiers) -> UInt32 {
        var value = 0
        if modifiers.contains(.command) { value |= cmdKey }
        if modifiers.contains(.shift) { value |= shiftKey }
        if modifiers.contains(.option) { value |= optionKey }
        if modifiers.contains(.control) { value |= controlKey }
        return UInt32(value)
    }
}

private func globalHotKeyCallback(_ call: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    Task { @MainActor in GlobalHotKey.fire() }
    return noErr
}
