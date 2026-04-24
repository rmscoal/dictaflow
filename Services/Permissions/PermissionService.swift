import AVFoundation
import Foundation

@MainActor
protocol PermissionServiceProtocol: AnyObject {
    func currentMicrophonePermissionStatus() -> MicrophonePermissionState
    func requestMicrophonePermissionIfNeeded() async -> MicrophonePermissionState
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
}
