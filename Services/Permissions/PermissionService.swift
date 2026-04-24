import AppKit
import AVFoundation
import ApplicationServices
import Foundation

@MainActor
protocol PermissionServiceProtocol: AnyObject {
    func currentMicrophonePermissionStatus() -> MicrophonePermissionState
    func requestMicrophonePermissionIfNeeded() async -> MicrophonePermissionState
    func isAccessibilityPermissionGranted() -> Bool
    func requestAccessibilityPermission() -> Bool
    func openAccessibilitySettings()
}

@MainActor
final class SystemPermissionService: PermissionServiceProtocol {
    func currentMicrophonePermissionStatus() -> MicrophonePermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined:
            return .undetermined
        case .authorized:
            return .granted
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .restricted
        }
    }

    func requestMicrophonePermissionIfNeeded() async -> MicrophonePermissionState {
        let currentState = currentMicrophonePermissionStatus()

        guard currentState == .undetermined else {
            return currentState
        }

        let granted = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }

        return granted ? .granted : currentMicrophonePermissionStatus()
    }

    func isAccessibilityPermissionGranted() -> Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }

        NSWorkspace.shared.open(url)
    }
}
