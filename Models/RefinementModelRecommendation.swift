import Foundation

struct RefinementModelSupport: Equatable, Sendable {
    let isSupported: Bool
    let unsupportedReason: String?

    static let supported = RefinementModelSupport(isSupported: true, unsupportedReason: nil)

    static func unsupported(_ reason: String) -> RefinementModelSupport {
        RefinementModelSupport(isSupported: false, unsupportedReason: reason)
    }
}

struct RefinementModelRecommendation: Equatable, Sendable {
    static let downloadStorageBufferBytes: Int64 = 1_000_000_000

    let hardwareProfile: MacHardwareProfile
    let preparedModels: Set<RefinementModelDescriptor>
    let bestModel: RefinementModelDescriptor
    let recommendedModel: RefinementModelDescriptor

    init(
        hardwareProfile: MacHardwareProfile,
        preparedModels: Set<RefinementModelDescriptor>
    ) {
        self.hardwareProfile = hardwareProfile
        self.preparedModels = preparedModels
        self.bestModel = .bestQualityDefault
        self.recommendedModel = Self.recommendedModel(
            hardwareProfile: hardwareProfile,
            preparedModels: preparedModels
        )
    }

    func support(for model: RefinementModelDescriptor) -> RefinementModelSupport {
        Self.support(for: model, hardwareProfile: hardwareProfile, isPrepared: preparedModels.contains(model))
    }

    private static func recommendedModel(
        hardwareProfile: MacHardwareProfile,
        preparedModels: Set<RefinementModelDescriptor>
    ) -> RefinementModelDescriptor {
        RefinementModelDescriptor.allCases
            .filter { support(for: $0, hardwareProfile: hardwareProfile, isPrepared: preparedModels.contains($0)).isSupported }
            .max { $0.qualityRank < $1.qualityRank } ?? .qwen25HalfB
    }

    private static func support(
        for model: RefinementModelDescriptor,
        hardwareProfile: MacHardwareProfile,
        isPrepared: Bool
    ) -> RefinementModelSupport {
        if hardwareProfile.physicalMemoryGB < model.minimumMemoryGB {
            return .unsupported("Needs at least \(model.minimumMemoryGB) GB memory.")
        }

        if !isPrepared,
           let availableModelStorageBytes = hardwareProfile.availableModelStorageBytes,
           availableModelStorageBytes - downloadStorageBufferBytes < model.approximateDiskSizeBytes {
            return .unsupported("Not enough free disk space to download.")
        }

        return .supported
    }
}
