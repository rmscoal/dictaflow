import Carbon
import Foundation

@MainActor
protocol HotkeyServiceProtocol: AnyObject {
    func registerToggleHotkey(
        _ shortcut: GlobalShortcutDescriptor,
        handler: @escaping () -> Void
    ) throws
    func unregisterToggleHotkey()
}

enum HotkeyServiceError: LocalizedError {
    case unableToInstallHandler
    case invalidShortcut
    case unableToRegisterShortcut(shortcut: GlobalShortcutDescriptor, status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .unableToInstallHandler:
            return "DictaFlow could not install its global hotkey handler."
        case .invalidShortcut:
            return "Choose a shortcut with at least one modifier and a key."
        case .unableToRegisterShortcut(let shortcut, let status):
            return "DictaFlow could not register \(shortcut.displayValue) as a global shortcut. It may already be in use. (OSStatus \(status))."
        }
    }
}

@MainActor
final class CarbonHotkeyService: HotkeyServiceProtocol {
    private static let hotKeySignature = fourCharCode("DFHK")

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandlerRef: EventHandlerRef?
    private var handler: (() -> Void)?

    func registerToggleHotkey(
        _ shortcut: GlobalShortcutDescriptor,
        handler: @escaping () -> Void
    ) throws {
        guard shortcut.isValid else {
            throw HotkeyServiceError.invalidShortcut
        }

        unregisterToggleHotkey()

        self.handler = handler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let userData, let eventRef else {
                    return noErr
                }

                let service = Unmanaged<CarbonHotkeyService>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                service.handle(eventRef: eventRef)
                return noErr
            },
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &eventHandlerRef
        )

        guard installStatus == noErr else {
            self.handler = nil
            throw HotkeyServiceError.unableToInstallHandler
        }

        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: 1)
        let registerStatus = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifierFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard registerStatus == noErr, let hotKeyRef else {
            unregisterToggleHotkey()
            throw HotkeyServiceError.unableToRegisterShortcut(
                shortcut: shortcut,
                status: registerStatus
            )
        }

        hotKeyRefs = [hotKeyRef]
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
}

private func fourCharCode(_ string: String) -> FourCharCode {
    string.utf8.reduce(0) { partialResult, character in
        (partialResult << 8) + FourCharCode(character)
    }
}
