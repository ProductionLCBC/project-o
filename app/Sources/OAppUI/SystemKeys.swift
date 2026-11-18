// OAppUI — Spec 10 §9, what the keys need of the system: the keyboard layout's labels, and the system-wide key ⌃⌥⌘⎋.

import AppKit
@preconcurrency import Carbon.HIToolbox
import OApp

/// Spec 10 §15 — "Keys are drawn as the current keyboard layout labels
/// them, though matched by position (§9)."
@MainActor
enum KeyboardLayout {
    /// What the current keyboard layout prints on the key at a position,
    /// with nothing held; nil when the layout has no character there.
    static func label(code: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        return data.withUnsafeBytes { bytes -> String? in
            guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }

    /// The current layout's identifier, such as `com.apple.keylayout.US`.
    static var identifier: String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        return Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
    }
}

/// Spec 10 §9, "Fixed keys" — how ⌃⌥⌘⎋ is asked of the system. A seam, so a
/// test never takes a key from the whole Mac.
@MainActor
protocol ReleaseKey: AnyObject {
    /// Asks the system for the key; `pressed` runs at each press. Says whether the system gave it.
    func register(_ pressed: @escaping @MainActor () -> Void) -> Bool
    func unregister()
}

/// "The app registers it as a system-wide hot key, which needs no
/// permission, so it works with the window covered or another app active."
@MainActor
final class SystemReleaseKey: ReleaseKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var pressed: (@MainActor () -> Void)?

    func register(_ pressed: @escaping @MainActor () -> Void) -> Bool {
        unregister()
        self.pressed = pressed
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let key = Unmanaged<SystemReleaseKey>.fromOpaque(context).takeUnretainedValue()
            // The system delivers a hot key on the main thread, with the app's other events.
            MainActor.assumeIsolated { key.pressed?() }
            return noErr
        }, 1, &spec, context, &handler)
        guard installed == noErr else { return false }
        // 'OREL': the app's one hot key.
        let id = EventHotKeyID(signature: OSType(0x4F52_454C), id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_Escape), UInt32(cmdKey | optionKey | controlKey), id, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr || hotKey == nil {
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        pressed = nil
    }
}
