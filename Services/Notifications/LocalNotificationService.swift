import Foundation
import UserNotifications

@MainActor
protocol LocalNotificationServiceProtocol: AnyObject {
    func requestAuthorizationIfNeeded()
    func show(title: String, body: String)
}

@MainActor
final class UserLocalNotificationService: NSObject, LocalNotificationServiceProtocol, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    private var hasRequestedAuthorization = false

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
    }

    func requestAuthorizationIfNeeded() {
        guard !hasRequestedAuthorization else {
            return
        }

        hasRequestedAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func show(title: String, body: String) {
        center.getNotificationSettings { [weak self] settings in
            guard let self else {
                return
            }

            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                Task { @MainActor in
                    self.enqueue(title: title, body: body)
                }
            case .notDetermined:
                self.center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else {
                        return
                    }

                    Task { @MainActor in
                        self.enqueue(title: title, body: body)
                    }
                }
            case .denied:
                return
            @unknown default:
                return
            }
        }
    }

    private func enqueue(title: String, body: String) {
        hasRequestedAuthorization = true

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "dictaflow-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
