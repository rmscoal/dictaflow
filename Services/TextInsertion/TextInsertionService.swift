import AppKit
import ApplicationServices
import Foundation

@MainActor
protocol TextInsertionServiceProtocol: AnyObject {
    func insertText(
        _ text: String,
        targetApplication: InsertionTargetApplication?,
        allowAccessibilityFeatures: Bool
    ) async -> TextInsertionResult

    func copyTextToPasteboard(_ text: String)
}

@MainActor
final class SystemTextInsertionService: TextInsertionServiceProtocol {
    private let pasteboard: NSPasteboard
    private let copyFallbackPanelCoordinator: CopyFallbackPanelCoordinator

    init(
        pasteboard: NSPasteboard = .general,
        copyFallbackPanelCoordinator: CopyFallbackPanelCoordinator? = nil
    ) {
        self.pasteboard = pasteboard
        self.copyFallbackPanelCoordinator = copyFallbackPanelCoordinator ?? CopyFallbackPanelCoordinator()
    }

    func insertText(
        _ text: String,
        targetApplication: InsertionTargetApplication?,
        allowAccessibilityFeatures: Bool
    ) async -> TextInsertionResult {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetApplicationName = targetApplication?.localizedName ?? NSWorkspace.shared.frontmostApplication?.localizedName

        if allowAccessibilityFeatures {
            await activateTargetApplicationIfNeeded(targetApplication)

            if insertViaAccessibility(trimmedText, targetApplication: targetApplication) {
                return TextInsertionResult(
                    text: trimmedText,
                    method: .accessibilityDirect,
                    targetApplicationName: targetApplicationName,
                    completedAt: Date()
                )
            }

            switch await insertViaPaste(trimmedText, targetApplication: targetApplication) {
            case .confirmed, .posted:
                return TextInsertionResult(
                    text: trimmedText,
                    method: .clipboardPaste,
                    targetApplicationName: targetApplicationName,
                    completedAt: Date()
                )
            case .notPosted:
                break
            }

            if insertViaSimulatedTyping(trimmedText) {
                return TextInsertionResult(
                    text: trimmedText,
                    method: .simulatedTyping,
                    targetApplicationName: targetApplicationName,
                    completedAt: Date()
                )
            }
        }

        copyTextToPasteboard(trimmedText)
        copyFallbackPanelCoordinator.show(text: trimmedText, targetApplicationName: targetApplicationName)

        return TextInsertionResult(
            text: trimmedText,
            method: .copyPanel,
            targetApplicationName: targetApplicationName,
            completedAt: Date()
        )
    }

    func copyTextToPasteboard(_ text: String) {
        _ = PrivatePasteboardWriter.write(text, to: pasteboard)
    }

    private func activateTargetApplicationIfNeeded(_ targetApplication: InsertionTargetApplication?) async {
        guard
            let targetApplication,
            let runningApplication = runningApplication(for: targetApplication),
            runningApplication.bundleIdentifier != Bundle.main.bundleIdentifier
        else {
            return
        }

        runningApplication.activate(options: [.activateIgnoringOtherApps])
        try? await Task.sleep(nanoseconds: 350_000_000)
    }

    private func runningApplication(for targetApplication: InsertionTargetApplication) -> NSRunningApplication? {
        if let runningApplication = NSRunningApplication(processIdentifier: targetApplication.processIdentifier) {
            return runningApplication
        }

        guard let bundleIdentifier = targetApplication.bundleIdentifier else {
            return nil
        }

        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    }

    private func insertViaAccessibility(_ text: String, targetApplication: InsertionTargetApplication?) -> Bool {
        guard let focusedApplication = focusedApplicationElement(), let focusedElement = focusedElement() else {
            return false
        }

        if let targetApplication {
            var focusedProcessIdentifier: pid_t = 0
            AXUIElementGetPid(focusedApplication, &focusedProcessIdentifier)

            guard focusedProcessIdentifier == targetApplication.processIdentifier else {
                return false
            }
        }

        return replaceSelection(with: text, in: focusedElement)
    }

    private func focusedApplicationElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedApplicationAttribute as CFString, &value)

        guard result == .success, let value else {
            return nil
        }

        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private func focusedElement() -> AXUIElement? {
        let systemWideElement = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &value)

        guard result == .success, let value else {
            return nil
        }

        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private func replaceSelection(with insertedText: String, in element: AXUIElement) -> Bool {
        var isValueSettable = DarwinBoolean(false)
        let isValueSettableResult = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &isValueSettable)
        guard isValueSettableResult == .success, isValueSettable.boolValue else {
            return false
        }

        if let currentValue = stringAttribute(kAXValueAttribute as CFString, from: element) {
            let currentNSString = currentValue as NSString
            let selectedRange = selectedTextRange(in: element, textLength: currentNSString.length)
            let updatedValue = currentNSString.replacingCharacters(in: selectedRange, with: insertedText)

            guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, updatedValue as CFTypeRef) == .success else {
                return false
            }

            let caretLocation = selectedRange.location + (insertedText as NSString).length
            setSelectedTextRange(location: caretLocation, in: element)
            return true
        }

        return AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, insertedText as CFTypeRef) == .success
    }

    private func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }

        return value as? String
    }

    private func selectedTextRange(in element: AXUIElement, textLength: Int) -> NSRange {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID()
        else {
            return NSRange(location: textLength, length: 0)
        }

        let selectedRangeValue = axValue as! AXValue
        guard AXValueGetType(selectedRangeValue) == .cfRange else {
            return NSRange(location: textLength, length: 0)
        }

        var selectedRange = CFRange()
        guard AXValueGetValue(selectedRangeValue, .cfRange, &selectedRange) else {
            return NSRange(location: textLength, length: 0)
        }

        let safeLocation = min(max(0, selectedRange.location), textLength)
        let safeLength = min(max(0, selectedRange.length), textLength - safeLocation)
        return NSRange(location: safeLocation, length: safeLength)
    }

    private func setSelectedTextRange(location: Int, in element: AXUIElement) {
        var isRangeSettable = DarwinBoolean(false)
        let result = AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &isRangeSettable)
        guard result == .success, isRangeSettable.boolValue else {
            return
        }

        var selectedRange = CFRange(location: location, length: 0)
        guard let axRange = AXValueCreate(.cfRange, &selectedRange) else {
            return
        }

        _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange)
    }

    private func insertViaPaste(_ text: String, targetApplication: InsertionTargetApplication?) async -> PasteInsertionOutcome {
        let prePasteSnapshot = focusedElementSnapshot(targetApplication: targetApplication)
        let snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        guard PrivatePasteboardWriter.write(text, to: pasteboard) else {
            snapshot?.restore(to: pasteboard)
            return .notPosted
        }
        let insertedPasteboardChangeCount = pasteboard.changeCount

        guard postCommandV() else {
            snapshot?.restore(to: pasteboard)
            return .notPosted
        }

        try? await Task.sleep(nanoseconds: 1_000_000_000)

        let postPasteSnapshot = focusedElementSnapshot(targetApplication: targetApplication)
        let pasteWasConfirmed = pasteWasObserved(insertedText: text, before: prePasteSnapshot, after: postPasteSnapshot)

        if pasteWasConfirmed, pasteboard.changeCount == insertedPasteboardChangeCount {
            snapshot?.restore(to: pasteboard)
        }

        return pasteWasConfirmed ? .confirmed : .posted
    }

    private func postCommandV() -> Bool {
        let commandKeyCode: CGKeyCode = 55
        let vKeyCode: CGKeyCode = 9

        guard
            let source = CGEventSource(stateID: .hidSystemState),
            let commandDown = CGEvent(keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: true),
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false),
            let commandUp = CGEvent(keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: false)
        else {
            return false
        }

        commandDown.flags = .maskCommand
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        for event in [commandDown, vDown, vUp, commandUp] {
            event.post(tap: .cghidEventTap)
        }

        return true
    }

    private func insertViaSimulatedTyping(_ text: String) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            return false
        }

        for character in text {
            let utf16Scalars = Array(String(character).utf16)

            guard
                let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else {
                return false
            }

            keyDown.keyboardSetUnicodeString(stringLength: utf16Scalars.count, unicodeString: utf16Scalars)
            keyUp.keyboardSetUnicodeString(stringLength: utf16Scalars.count, unicodeString: utf16Scalars)
            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }

        return true
    }

    private func focusedElementSnapshot(targetApplication: InsertionTargetApplication?) -> FocusedElementSnapshot? {
        guard let focusedApplication = focusedApplicationElement(), let focusedElement = focusedElement() else {
            return nil
        }

        var processIdentifier: pid_t = 0
        AXUIElementGetPid(focusedApplication, &processIdentifier)

        if let targetApplication, processIdentifier != targetApplication.processIdentifier {
            return nil
        }

        return FocusedElementSnapshot(
            processIdentifier: processIdentifier,
            value: stringAttribute(kAXValueAttribute as CFString, from: focusedElement),
            selectedRange: selectedTextRangeIfAvailable(in: focusedElement)
        )
    }

    private func selectedTextRangeIfAvailable(in element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let axValue = value,
              CFGetTypeID(axValue) == AXValueGetTypeID()
        else {
            return nil
        }

        let selectedRangeValue = axValue as! AXValue
        guard AXValueGetType(selectedRangeValue) == .cfRange else {
            return nil
        }

        var selectedRange = CFRange()
        guard AXValueGetValue(selectedRangeValue, .cfRange, &selectedRange) else {
            return nil
        }

        return NSRange(location: selectedRange.location, length: selectedRange.length)
    }

    private func pasteWasObserved(
        insertedText: String,
        before: FocusedElementSnapshot?,
        after: FocusedElementSnapshot?
    ) -> Bool {
        guard let after else {
            return false
        }

        if let before {
            if before.processIdentifier != after.processIdentifier {
                return false
            }

            if before.value != after.value {
                return true
            }

            if before.selectedRange != after.selectedRange {
                return true
            }

            return false
        }

        guard let afterValue = after.value else {
            return false
        }

        return afterValue.contains(insertedText)
    }
}

private struct PasteboardSnapshot {
    private let items: [NSPasteboardItem]

    init?(pasteboard: NSPasteboard) {
        guard let pasteboardItems = pasteboard.pasteboardItems else {
            return nil
        }

        self.items = pasteboardItems.compactMap { item in
            let copy = NSPasteboardItem()
            var hasData = false

            for type in item.types {
                guard let data = item.data(forType: type) else {
                    continue
                }

                hasData = true
                copy.setData(data, forType: type)
            }

            return hasData ? copy : nil
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()

        guard !items.isEmpty else {
            return
        }

        pasteboard.writeObjects(items)
    }
}

private struct FocusedElementSnapshot {
    let processIdentifier: pid_t
    let value: String?
    let selectedRange: NSRange?
}

private enum PasteInsertionOutcome {
    case notPosted
    case posted
    case confirmed
}

enum PrivatePasteboardWriter {
    @discardableResult
    static func write(_ text: String, to pasteboard: NSPasteboard) -> Bool {
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string),
              item.setData(Data(), forType: .dictaFlowTransient),
              item.setData(Data(), forType: .dictaFlowConcealed),
              item.setData(Data(), forType: .dictaFlowAutoGenerated) else {
            return false
        }

        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}

private extension NSPasteboard.PasteboardType {
    static let dictaFlowTransient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let dictaFlowConcealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let dictaFlowAutoGenerated = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
}
