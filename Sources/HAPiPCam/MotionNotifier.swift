import Foundation
import OSLog
import UserNotifications

enum MotionNotifier {
    private static let log = Logger(subsystem: "io.github.hapipcam.HAPiPCam", category: "notify")

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                log.error("notification authorization failed: \(error.localizedDescription, privacy: .public)")
            } else {
                log.info("notification authorization granted=\(granted)")
            }
        }
    }

    static func post(cameraName: String, motionTime: String?) {
        let content = UNMutableNotificationContent()
        content.title = "Motion detected · \(cameraName)"
        content.body = motionTime.map { "Event at \($0)" } ?? "Camera reported new motion"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "hapipcam-motion", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                log.error("motion notification failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
