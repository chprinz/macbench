import AppKit
import Carbon.HIToolbox

/// A system-wide shortcut for the quick capture window.
///
/// Carbon's hot key API is used deliberately: it needs no accessibility
/// permission and works from inside the sandbox, unlike a global event monitor.
@MainActor
final class GlobalHotKey {
    struct Combination: Codable, Equatable, Sendable {
        var keyCode: UInt32
        var modifiers: UInt32

        /// ⌃⌥⌘N. Deliberately not ⌥⌘Space or ⇧⌘Space: those belong to Spotlight,
        /// Alfred and Raycast on most machines, and a launcher that stops working
        /// is a worse first impression than a shortcut nobody finds.
        static let `default` = Combination(keyCode: UInt32(kVK_ANSI_N),
                                           modifiers: UInt32(controlKey | optionKey | cmdKey))

        static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
            var carbon: UInt32 = 0
            if flags.contains(.control) { carbon |= UInt32(controlKey) }
            if flags.contains(.option) { carbon |= UInt32(optionKey) }
            if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
            if flags.contains(.command) { carbon |= UInt32(cmdKey) }
            return carbon
        }

        var displayString: String {
            var text = ""
            if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
            if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
            if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
            if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
            return text + Combination.keyName(for: keyCode)
        }

        /// Asks the keyboard layout what this key prints, so a German keyboard
        /// shows Z where a US one shows Y.
        static func keyName(for keyCode: UInt32) -> String {
            switch Int(keyCode) {
            case kVK_Space: return "Space"
            case kVK_Return, kVK_ANSI_KeypadEnter: return "↩"
            case kVK_Tab: return "⇥"
            case kVK_Escape: return "⎋"
            case kVK_LeftArrow: return "←"
            case kVK_RightArrow: return "→"
            case kVK_UpArrow: return "↑"
            case kVK_DownArrow: return "↓"
            default: break
            }
            guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
                  let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            else { return "Key \(keyCode)" }
            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
            var deadKeys: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 4)
            let status = data.withUnsafeBytes { raw -> OSStatus in
                guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self)
                else { return -1 }
                return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                      UInt32(LMGetKbdType()), UInt32(kUCKeyTranslateNoDeadKeysBit),
                                      &deadKeys, characters.count, &length, &characters)
            }
            guard status == noErr, length > 0 else { return "Key \(keyCode)" }
            return String(utf16CodeUnits: characters, count: length).uppercased()
        }
    }

    /// Wrapper so that "no shortcut at all" is a value that can be stored, rather
    /// than the absence of a setting — which would be indistinguishable from
    /// never having chosen one.
    struct StoredCombination: Codable, Sendable {
        var combination: Combination?
    }

    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?
    private static let signature = OSType(0x4D424348)  // 'MBCH'

    func register(_ combination: Combination, action: @escaping () -> Void) {
        unregister()
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context else { return noErr }
            let key = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            var identifier = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard identifier.signature == GlobalHotKey.signature else { return noErr }
            DispatchQueue.main.async { key.action?() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)

        let identifier = EventHotKeyID(signature: GlobalHotKey.signature, id: 1)
        RegisterEventHotKey(combination.keyCode, combination.modifiers, identifier,
                            GetApplicationEventTarget(), 0, &reference)
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    // No deinit: this object lives for the whole run of the app, and the system
    // reclaims the hot key when the process ends. `unregister()` covers rebinding.
}
