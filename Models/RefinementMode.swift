import Foundation

nonisolated enum RefinementMode: String, Codable, Equatable, CaseIterable {
    // Keep the stored identifier compatible with earlier preferences and history.
    case smartCleanup, professionalFormal, casualMessaging, technicalEngineering, diy

    var title: String {
        switch self {
        case .smartCleanup: "Normal Cleanup"
        case .professionalFormal: "Professional Formal"
        case .casualMessaging: "Casual Text Messaging"
        case .technicalEngineering: "Technical and Engineering"
        case .diy: "DIY (Do It Yourself)"
        }
    }
    var detailText: String { title }
    var writingExample: String {
        switch self {
        case .smartCleanup: "Hey, can you review the auth PR by Wednesday? It might fix the login issue, but we still need to test it."
        case .professionalFormal: "Could you please review the authentication PR by Wednesday?\n\nIt may resolve the login issue. Further testing is still required."
        case .casualMessaging: "hey, can u review the auth PR by Wed? might fix the login issue, but we still need to test it."
        case .technicalEngineering: "Please review the authentication PR by Wednesday.\n\nIt may fix the login issue. Testing is still required."
        case .diy: ""
        }
    }
}
