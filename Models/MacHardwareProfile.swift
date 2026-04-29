import Foundation

struct MacHardwareProfile: Equatable, Sendable {
    let physicalMemoryBytes: UInt64
    let availableModelStorageBytes: Int64?

    var physicalMemoryGB: Int {
        Int(physicalMemoryBytes / 1_073_741_824)
    }

    static func current(
        modelsDirectoryURL: URL,
        fileManager: FileManager = .default
    ) -> MacHardwareProfile {
        MacHardwareProfile(
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            availableModelStorageBytes: availableStorageBytes(for: modelsDirectoryURL, fileManager: fileManager)
        )
    }

    private static func availableStorageBytes(for url: URL, fileManager: FileManager) -> Int64? {
        let volumeURL = existingVolumeURL(for: url, fileManager: fileManager)
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey
        ]

        guard let values = try? volumeURL.resourceValues(forKeys: keys) else {
            return nil
        }

        if let importantUsageCapacity = values.volumeAvailableCapacityForImportantUsage {
            return importantUsageCapacity
        }

        if let availableCapacity = values.volumeAvailableCapacity {
            return Int64(availableCapacity)
        }

        return nil
    }

    private static func existingVolumeURL(for url: URL, fileManager: FileManager) -> URL {
        var candidate = url

        while !fileManager.fileExists(atPath: candidate.path) {
            let parent = candidate.deletingLastPathComponent()
            guard parent.path != candidate.path else {
                break
            }
            candidate = parent
        }

        return candidate
    }
}
