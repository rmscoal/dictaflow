import Foundation

struct InsertionTargetApplication: Equatable {
    let bundleIdentifier: String?
    let localizedName: String?
    let processIdentifier: pid_t

    var displayName: String {
        localizedName ?? bundleIdentifier ?? "Current App"
    }
}
