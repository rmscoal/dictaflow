import Carbon
import Foundation

@MainActor
protocol HotkeyServiceProtocol: AnyObject {
    func registerToggleHotkey(handler: @escaping () -> Void) throws
    func unregisterToggleHotkey()
}

enum HotkeyServiceError: LocalizedError {
    case unableToInstallHandler
    case unableToRegisterShortcut(statuses: [String])
    case unableToResolveShortcutKey

    var errorDescription: String? {
        switch self {
        case .unableToInstallHandler:
            return "DictaFlow could not install its global hotkey handler."
        case .unableToRegisterShortcut(let statuses):
            return "DictaFlow could not register Command + Shift + \\ as a global shortcut. \(statuses.joined(separator: " "))"
        case .unableToResolveShortcutKey:
            return "DictaFlow could not resolve the slash key for the current keyboard layout."
        }
    }
}

@MainActor
final class CarbonHotkeyService: HotkeyServiceProtocol {
    private static let hotKeySignature = fourCharCode("DFHK")
    private static let modifierFlags = UInt32(cmdKey | shiftKey)

    private var hotKeyRefs: [EventHotKeyRef] = []
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

        let candidates = try Self.shortcutCandidates()
        var failedRegistrations: [String] = []

        for candidate in candidates {
            var hotKeyRef: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: candidate.id)
            let registerStatus = RegisterEventHotKey(
                candidate.keyCode,
                Self.modifierFlags,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )

            if registerStatus == noErr, let hotKeyRef {
                hotKeyRefs.append(hotKeyRef)
            } else {
                failedRegistrations.append("\(candidate.displayName): OSStatus \(registerStatus).")
            }
        }

        guard !hotKeyRefs.isEmpty else {
            unregisterToggleHotkey()
            throw HotkeyServiceError.unableToRegisterShortcut(statuses: failedRegistrations)
        }
    }

    func unregisterToggleHotkey() {
        for hotKeyRef in hotKeyRefs {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs = []

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

        guard status == noErr, hotKeyID.signature == Self.hotKeySignature else {
            return
        }

        Task { @MainActor [handler] in
            handler?()
        }
    }

    private static func shortcutCandidates() throws -> [(id: UInt32, displayName: String, keyCode: UInt32)] {
        [
            (id: 1, displayName: "Command + Shift + \\", keyCode: UInt32(kVK_ANSI_Backslash)),
            (id: 2, displayName: "Command + Shift + /", keyCode: try currentSlashKeyCode())
        ]
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
        for keyCode in UInt16(0)...UInt16(UInt8.max) {
            if translatedString(
                for: keyCode,
                modifierState: 0,
                keyboardLayout: keyboardLayout
            ) == "/" {
                return UInt32(keyCode)
            }
        }

        return UInt32(kVK_ANSI_Slash)
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
