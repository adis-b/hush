import SwiftUI
import AppKit
import Combine

fileprivate let blockedBundleIdentifiers: Set<String> = [
    "com.apple.loginwindow",
    "com.apple.systemuiserver",
    "com.apple.dock",
    "com.apple.finder",
    "com.apple.coreautha",
    "com.apple.Spotlight",
    "com.apple.notificationcenterui",
    "com.apple.Siri"
]

class RunningAppsManager: ObservableObject {
    @Published var runningApps: [NSRunningApplication: Date] = [:]
    @Published var toggleStatus: [String: Bool] = [:]

    @AppStorage("com.MagicQuit.toggleStatus") var toggleStatusData: Data = Data()

    init() {
        syncToggleStatus()
        addCurrentRunningApps()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification,
                                    object: nil,
                                    queue: .main) { [weak self] notification in
            guard let self = self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  !self.isBlockedApp(app) else { return }
            self.runningApps[app] = Date()
        }
    }

    private func syncToggleStatus() {
        if let status = try? JSONDecoder().decode([String: Bool].self, from: toggleStatusData) {
            toggleStatus = status
        }
    }

    func saveToggleStatus() {
        if let data = try? JSONEncoder().encode(toggleStatus) {
            toggleStatusData = data
        }
    }

    private func isBlockedApp(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy == .regular,
              let bundleId = app.bundleIdentifier,
              bundleId != Bundle.main.bundleIdentifier,
              !blockedBundleIdentifiers.contains(bundleId) else {
            return true
        }
        return false
    }

    private func addCurrentRunningApps() {
        let now = Date()
        for app in NSWorkspace.shared.runningApplications where !isBlockedApp(app) && runningApps[app] == nil {
            runningApps[app] = now
        }
    }
}
