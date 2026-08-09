import CoreAudio
import Foundation

protocol AudioOutputVolumeServiceProtocol: AnyObject, Sendable {
    func beginDucking() async throws
    func restoreDucking() async throws
    func restoreDuckingForTermination() throws
}

enum AudioOutputVolumeServiceError: LocalizedError {
    case defaultOutputDeviceUnavailable
    case noSettableOutputVolume
    case unableToReadVolume(OSStatus)
    case unableToSetVolume(OSStatus)

    var errorDescription: String? {
        switch self {
        case .defaultOutputDeviceUnavailable:
            return "The default audio output device is unavailable."
        case .noSettableOutputVolume:
            return "The default audio output device does not expose a software volume control."
        case .unableToReadVolume(let status):
            return "Core Audio could not read the output volume (status \(status))."
        case .unableToSetVolume(let status):
            return "Core Audio could not change the output volume (status \(status))."
        }
    }
}

final class SystemAudioOutputVolumeService: AudioOutputVolumeServiceProtocol, @unchecked Sendable {
    private struct VolumeControl {
        let deviceID: AudioDeviceID
        let address: AudioObjectPropertyAddress
    }

    private struct VolumeSnapshot {
        let controls: [VolumeControl]
        let originalVolumes: [Float32]
        let duckedVolumes: [Float32]
    }

    private var volumeSnapshot: VolumeSnapshot?
    private let queue = DispatchQueue(label: "com.dictaflow.audio-output-volume")
    private let duckingMultiplier: Float32 = 0.5
    private let restoreTolerance: Float32 = 0.01

    func beginDucking() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try beginDuckingOnQueue()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func restoreDucking() async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try restoreDuckingOnQueue()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func restoreDuckingForTermination() throws {
        try queue.sync { [self] in
            try restoreDuckingOnQueue()
        }
    }

    private func beginDuckingOnQueue() throws {
        guard volumeSnapshot == nil else {
            return
        }

        let deviceID = try defaultOutputDeviceID()
        let controls = try settableVolumeControls(for: deviceID)
        let originalVolumes = try controls.map(readVolume)
        let duckedVolumes = originalVolumes.map { volume in
            min(max(volume * duckingMultiplier, 0), 1)
        }

        do {
            for (control, volume) in zip(controls, duckedVolumes) {
                try setVolume(volume, on: control)
            }
        } catch {
            for (control, volume) in zip(controls, originalVolumes) {
                try? setVolume(volume, on: control)
            }
            throw error
        }

        volumeSnapshot = VolumeSnapshot(
            controls: controls,
            originalVolumes: originalVolumes,
            duckedVolumes: duckedVolumes
        )
    }

    private func restoreDuckingOnQueue() throws {
        guard let volumeSnapshot else {
            return
        }

        defer {
            self.volumeSnapshot = nil
        }

        var firstError: Error?

        for (index, control) in volumeSnapshot.controls.enumerated() {
            guard
                let currentVolume = try? readVolume(on: control),
                abs(currentVolume - volumeSnapshot.duckedVolumes[index]) <= restoreTolerance
            else {
                continue
            }

            do {
                try setVolume(volumeSnapshot.originalVolumes[index], on: control)
            } catch {
                firstError = firstError ?? error
            }
        }

        if let firstError {
            throw firstError
        }
    }

    private func defaultOutputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            throw AudioOutputVolumeServiceError.defaultOutputDeviceUnavailable
        }

        return deviceID
    }

    private func settableVolumeControls(for deviceID: AudioDeviceID) throws -> [VolumeControl] {
        let masterAddresses = [
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        ]

        for address in masterAddresses {
            let control = VolumeControl(deviceID: deviceID, address: address)
            if isSettableVolumeControl(control) {
                return [control]
            }
        }

        let channelControls = [
            AudioObjectPropertyElement(1),
            AudioObjectPropertyElement(2)
        ].compactMap { element -> VolumeControl? in
            let control = VolumeControl(
                deviceID: deviceID,
                address: AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyVolumeScalar,
                    mScope: kAudioObjectPropertyScopeOutput,
                    mElement: element
                )
            )

            return isSettableVolumeControl(control) ? control : nil
        }

        guard !channelControls.isEmpty else {
            throw AudioOutputVolumeServiceError.noSettableOutputVolume
        }

        return channelControls
    }

    private func isSettableVolumeControl(_ control: VolumeControl) -> Bool {
        var address = control.address
        guard AudioObjectHasProperty(control.deviceID, &address) else {
            return false
        }

        var isSettable = DarwinBoolean(false)
        guard AudioObjectIsPropertySettable(control.deviceID, &address, &isSettable) == noErr else {
            return false
        }

        guard isSettable.boolValue else {
            return false
        }

        return (try? readVolume(on: control)) != nil
    }

    private func readVolume(on control: VolumeControl) throws -> Float32 {
        var address = control.address
        var volume: Float32 = 0
        var dataSize = UInt32(MemoryLayout<Float32>.size)

        let status = AudioObjectGetPropertyData(
            control.deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &volume
        )

        guard status == noErr else {
            throw AudioOutputVolumeServiceError.unableToReadVolume(status)
        }

        return min(max(volume, 0), 1)
    }

    private func setVolume(_ volume: Float32, on control: VolumeControl) throws {
        var address = control.address
        var volume = min(max(volume, 0), 1)
        let dataSize = UInt32(MemoryLayout<Float32>.size)

        let status = AudioObjectSetPropertyData(
            control.deviceID,
            &address,
            0,
            nil,
            dataSize,
            &volume
        )

        guard status == noErr else {
            throw AudioOutputVolumeServiceError.unableToSetVolume(status)
        }
    }
}
