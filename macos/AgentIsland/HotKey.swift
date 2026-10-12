import AppKit
import Carbon.HIToolbox

/// One global hotkey (default ⌥⌘I) via Carbon's RegisterEventHotKey: no Accessibility permission,
/// and only this exact chord is taken from other apps.
final class HotKey {
    static let shared = HotKey()
    var onPress: () -> Void = {}
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    static let defaultKeyCode = UInt32(kVK_ANSI_I)
    static let defaultModifiers = UInt32(cmdKey | optionKey)

    var keyCode: UInt32 { UInt32(UserDefaults.standard.object(forKey: "hotKeyCode") as? Int ?? Int(Self.defaultKeyCode)) }
    var modifiers: UInt32 { UInt32(UserDefaults.standard.object(forKey: "hotKeyModifiers") as? Int ?? Int(Self.defaultModifiers)) }

    func register() {
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.shared.onPress() }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: OSType(0x4149_534C), id: 1), GetApplicationEventTarget(), 0, &ref)
    }

    func set(keyCode: UInt32, modifiers: UInt32) {
        UserDefaults.standard.set(Int(keyCode), forKey: "hotKeyCode")
        UserDefaults.standard.set(Int(modifiers), forKey: "hotKeyModifiers")
        register()
    }

    /// Carbon modifier mask from an AppKit event.
    static func carbonModifiers(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    /// "⌥⌘I"
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        let src = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        guard let data = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let layout = unsafeBitCast(data, to: CFData.self)
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        let ptr = unsafeBitCast(CFDataGetBytePtr(layout), to: UnsafePointer<UCKeyboardLayout>.self)
        UCKeyTranslate(ptr, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        return String(utf16CodeUnits: chars, count: len).uppercased()
    }
}
