import AppKit
import Foundation
import Security
import UserNotifications
import os.log

// Without this, macOS often swallows banners while Hush is active (popover open).
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// macOS ignores notification permission prompts for unsigned bundles.
enum NotificationRegistration {
    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "NotificationRegistration")
    private static let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    static var isUnsignedOrInvalid: Bool {
        let path = Bundle.main.bundleURL.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--verify", "--deep", "--strict", path]
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                return true
            }
        } catch {
            return true
        }
        var code: SecStaticCode?
        let url = Bundle.main.bundleURL as CFURL
        guard SecStaticCodeCreateWithPath(url, [], &code) == errSecSuccess, let code else {
            return true
        }
        return SecStaticCodeCheckValidity(code, [], nil) != errSecSuccess
    }

    // lsregister -u/-f fixes stale LaunchServices entries after reinstall (Sonoma+).
    static func repairLaunchServices() {
        let path = Bundle.main.bundleURL.path
        runLsregister(["-u", path])
        runLsregister(["-f", path])
    }

    private static func runLsregister(_ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsregister)
        process.arguments = args
        do {
            try process.run()
            process.waitUntilExit()
            os_log("lsregister %{public}@ exit %{public}d",
                   log: log, type: .info, args.joined(separator: " "), process.terminationStatus)
        } catch {
            os_log("lsregister failed %{public}@", log: log, type: .error, error.localizedDescription)
        }
    }

    static func presentAccessFailureAlert(error: Error?, stillNeedsPrompt: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if isUnsignedOrInvalid {
            alert.messageText = String(localized: "settings.notifications.alert.unsigned.title",
                                       comment: "Alert title when app unsigned")
            alert.informativeText = String(localized: "settings.notifications.alert.unsigned.body",
                                          comment: "Alert body when app unsigned")
        } else if stillNeedsPrompt {
            alert.messageText = String(localized: "settings.notifications.alert.noDialog.title",
                                       comment: "Alert title when prompt did not appear")
            alert.informativeText = String(localized: "settings.notifications.alert.noDialog.body",
                                          comment: "Alert body when prompt did not appear")
        } else {
            alert.messageText = String(localized: "settings.notifications.denied",
                                       comment: "Notification permission denied")
            alert.informativeText = error?.localizedDescription ?? ""
        }
        alert.addButton(withTitle: String(localized: "settings.notifications.open",
                                          comment: "Open notification settings"))
        alert.addButton(withTitle: String(localized: "settings.notifications.alert.dismiss",
                                          comment: "Dismiss alert"))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let urls = [
                "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
                "x-apple.systempreferences:com.apple.preference.notifications",
            ]
            for raw in urls {
                if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
            }
        }
    }
}
