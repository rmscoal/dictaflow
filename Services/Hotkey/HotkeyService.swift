import Carbon
import Foundation

@MainActor
protocol HotkeyServiceProtocol: AnyObject {
    func registerToggleHotkey(handler: @escaping () -> Void) throws
    func unregisterToggleHotkey()
}

enum HotkeyServiceError: LocalizedError {
    case unableToInstallHandler
    case unableToRegisterShortcut
    case unableToResolveShortcutKey

    var errorDescription: String? {
        switch self {
        case .unableToInstallHandler:
            return "DictaFlow could not install its global hotkey handler."
        case .unableToRegisterShortcut:
            return "DictaFlow could not register Command + Shift + / as a global shortcut."
        case .unableToResolveShortcutKey:
            return "DictaFlow could not resolve the slash key for the current keyboard layout."
        }
    }
}

@MainActor
final class CarbonHotkeyService: HotkeyServiceProtocol {
    private static let hotKeyIdentifier: UInt32 = 1
    private static let hotKeySignature = fourCharCode("DFHK")

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var handler: (() -> Void)?

    func registerToggleHotkey(handler: @escaping () -> Void) throws {
        unregisterToggleHotkey()

        self.handler = handler

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let userData, let eventRef else {
                    return noErr
                }

                let service = Unmanaged<CarbonHotkeyService>.fromOpaque(userData).takeUnretainedValue()
                service.handle(eventRef: eventRef)
                return noErr
            },
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &eventHandlerRef
        )

        guard installStatus == noErr else {
            throw HotkeyServiceError.unableToInstallHandler
        }

        let slashKeyCode = try Self.currentSlashKeyCode()
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyIdentifier)
        let registerStatus = RegisterEventHotKey(
            slashKeyCode,
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard registerStatus == noErr else {
            unregisterToggleHotkey()
            throw HotkeyServiceError.unableToRegisterShortcut
        }
    }

    func unregisterToggleHotkey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }

        handler = nil
    }

    private func handle(eventRef: EventRef) {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr, hotKeyID.signature == Self.hotKeySignature, hotKeyID.id == Self.hotKeyIdentifier else {
            return
        }

        Task { @MainActor [handler] in
            handler?()
        }
    }

    private static func currentSlashKeyCode() throws -> UInt32 {
        guard
            let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let layoutDataPointer = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData)
        else {
            throw HotkeyServiceError.unableToResolveShortcutKey
        }

        let layoutData = unsafeBitCast(layoutDataPointer, to: CFData.self)
        guard let keyboardLayoutData = CFDataGetBytePtr(layoutData) else {
            throw HotkeyServiceError.unableToResolveShortcutKey
        }

        let keyboardLayout = keyboardLayoutData.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { $0 }
        let shiftedModifierState = UInt32(shiftKey) >> 8

        for keyCode in UInt16(0)...UInt16(UInt8.max) {
            if translatedString(
                for: keyCode,
                modifierState: shiftedModifierState,
                keyboardLayout: keyboardLayout
            ) == "/" {
                return UInt32(keyCode)
            }
        }

        throw HotkeyServiceError.unableToResolveShortcutKey
    }
}

private func fourCharCode(_ string: String) -> FourCharCode {
    string.utf8.reduce(0) { partialResult, character in
        (partialResult << 8) + FourCharCode(character)
    }
}

private func translatedString(
    for keyCode: UInt16,
    modifierState: UInt32,
    keyboardLayout: UnsafePointer<UCKeyboardLayout>
) -> String? {
    var deadKeyState: UInt32 = 0
    var translatedLength: Int = 0
    var characters = [UniChar](repeating: 0, count: 4)

    let status = UCKeyTranslate(
        keyboardLayout,
        keyCode,
        UInt16(kUCKeyActionDisplay),
        modifierState,
        UInt32(LMGetKbdType()),
        OptionBits(kUCKeyTranslateNoDeadKeysBit),
        &deadKeyState,
        characters.count,
        &translatedLength,
        &characters
    )

    guard status == noErr, translatedLength > 0 else {
        return nil
    }

    return String(utf16CodeUnits: characters, count: translatedLength)
}
