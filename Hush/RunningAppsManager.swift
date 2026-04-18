import SwiftUI
import AppKit
import Combine
import Darwin
import IOKit.ps
import UserNotifications
import Carbon.HIToolbox
import os.log

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

fileprivate func isOnBatteryBelow(percent threshold: Int) -> Bool {
    guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
        return false
    }
    for source in sources {
        guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
            continue
        }
        let state = info[kIOPSPowerSourceStateKey] as? String
        if state == kIOPSBatteryPowerValue,
           let current = info[kIOPSCurrentCapacityKey] as? Int,
           let max = info[kIOPSMaxCapacityKey] as? Int, max > 0 {
            let pct = Double(current) / Double(max) * 100.0
            return pct <= Double(threshold)
        }
    }
    return false
}

class RunningAppsManager: ObservableObject {
    @Published var runningApps: [NSRunningApplication: Date] = [:]
    @Published var toggleStatus: [String: Bool] = [:]
    @Published var focusSessionEndDate: Date?
    @Published var availableFocusModes: [FocusMode] = []
    @Published var activeFocusModes: Set<String> = []
    @Published var focusFilesReadable: Bool = true
    @Published var focusReadError: Int32?

    @AppStorage("minutesUntilClose") var minutesUntilClose: Int = 120
    @AppStorage("com.MagicQuit.toggleStatus") var toggleStatusData: Data = Data()
    @AppStorage("autoCheckNewApps") var autoCheckNewApps: Bool = false
    @AppStorage("quitOnDisplaySleep") var quitOnDisplaySleep: Bool = true
    // 0 = aus
    @AppStorage("batteryAwareThresholdPercent") var batteryAwareThresholdPercent: Int = 30
    @AppStorage("lastFocusDuration") var lastFocusDuration: Int = 25
    @AppStorage("mirrorMacFocus") var mirrorMacFocus: Bool = false
    @AppStorage("excludedFocusModesData") private var excludedFocusModesData: Data = Data()

    private let focusSessionGracePeriodSeconds = 30
    private let log = OSLog(subsystem: "com.hush.app", category: "manager")
    private var timer: Timer?
    private var focusHotkey: GlobalHotkey?
    private let focusMirror = FocusMirror()
    private var focusStartedByMacFocus = false

    var excludedFocusModes: Set<String> {
        get {
            (try? JSONDecoder().decode(Set<String>.self, from: excludedFocusModesData)) ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                excludedFocusModesData = data
            }
        }
    }

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
            self.applyAutoCheckIfNeeded(for: app)
        }
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.handleDisplaysWillSleep()
            }
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        // ⌥⌘H toggles focus from anywhere
        self.focusHotkey = GlobalHotkey(keyCode: UInt32(kVK_ANSI_H),
                                        modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.toggleFocusSession()
        }

        focusMirror.onChange = { [weak self] in
            DispatchQueue.main.async { self?.refreshFocusState() }
        }
        refreshFocusState()
        focusMirror.ensureWatching()

        self.timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        let now = Date()
        let popupOpen = NSApplication.shared.windows.contains { $0.isKeyWindow || $0.isMainWindow }
        let atMinuteBoundary = floor(now.timeIntervalSince1970.truncatingRemainder(dividingBy: 60)) == 0

        if popupOpen || atMinuteBoundary {
            checkOpenApps()
        }
        if mirrorMacFocus, atMinuteBoundary {
            // belt+braces falls DispatchSource ein Event verschluckt hat
            refreshFocusState()
            focusMirror.ensureWatching()
        }
        if let end = focusSessionEndDate, now >= end {
            endFocusSession(reason: .completed)
        }
    }

    private func refreshFocusState() {
        let snapshot = focusMirror.read()
        availableFocusModes = snapshot.availableModes
        activeFocusModes = snapshot.activeModeIDs
        focusFilesReadable = focusMirror.isReadable
        focusReadError = focusMirror.lastReadError
        reevaluateFocusMirror()
    }

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    private func reevaluateFocusMirror() {
        guard mirrorMacFocus else {
            if focusStartedByMacFocus, focusSessionEndDate != nil {
                endFocusSession(reason: .cancelled)
                focusStartedByMacFocus = false
            }
            return
        }
        let active = activeFocusModes.subtracting(excludedFocusModes)
        if !active.isEmpty {
            if focusSessionEndDate == nil {
                startFocusSession(minutes: lastFocusDuration, startedByMacFocus: true)
            }
        } else if focusStartedByMacFocus, focusSessionEndDate != nil {
            endFocusSession(reason: .cancelled)
            focusStartedByMacFocus = false
        }
    }

    private func effectiveThresholdSeconds() -> Int {
        if focusSessionEndDate != nil {
            return focusSessionGracePeriodSeconds
        }
        var seconds = minutesUntilClose * 60
        if batteryAwareThresholdPercent > 0,
           isOnBatteryBelow(percent: batteryAwareThresholdPercent) {
            seconds = max(60, seconds / 2)
        }
        return seconds
    }

    private func handleDisplaysWillSleep() {
        guard quitOnDisplaySleep else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        for app in runningApps.keys {
            guard !isBlockedApp(app),
                  toggleStatus[app.localizedName ?? ""] ?? false,
                  app.processIdentifier != frontmost?.processIdentifier else {
                continue
            }
            quit(app)
        }
    }

    enum FocusSessionEndReason {
        case completed, cancelled
    }

    func startFocusSession(minutes: Int, startedByMacFocus: Bool = false) {
        lastFocusDuration = minutes
        focusSessionEndDate = Date().addingTimeInterval(Double(minutes * 60))
        focusStartedByMacFocus = startedByMacFocus
        let frontmost = NSWorkspace.shared.frontmostApplication
        for app in runningApps.keys {
            guard !isBlockedApp(app),
                  toggleStatus[app.localizedName ?? ""] ?? false,
                  app.processIdentifier != frontmost?.processIdentifier else {
                continue
            }
            quit(app)
        }
    }

    func cancelFocusSession() {
        endFocusSession(reason: .cancelled)
    }

    func toggleFocusSession() {
        if focusSessionEndDate != nil {
            cancelFocusSession()
        } else {
            startFocusSession(minutes: lastFocusDuration)
        }
    }

    private func endFocusSession(reason: FocusSessionEndReason) {
        focusSessionEndDate = nil
        focusStartedByMacFocus = false
        guard reason == .completed else { return }
        let content = UNMutableNotificationContent()
        content.title = "Focus session complete"
        content.body = "Your Mac is a little quieter."
        let request = UNNotificationRequest(identifier: "hush.focus.complete",
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    @discardableResult
    private func quit(_ app: NSRunningApplication) -> Bool {
        return app.terminate()
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
            applyAutoCheckIfNeeded(for: app)
        }
    }

    private func applyAutoCheckIfNeeded(for app: NSRunningApplication) {
        guard autoCheckNewApps,
              let name = app.localizedName,
              toggleStatus[name] == nil else { return }
        toggleStatus[name] = true
        saveToggleStatus()
    }

    private func checkOpenApps() {
        let workspace = NSWorkspace.shared
        let liveApps = Set(workspace.runningApplications)
        let now = Date()
        let thresholdSeconds = Double(effectiveThresholdSeconds())

        runningApps = runningApps.filter { liveApps.contains($0.key) && !isBlockedApp($0.key) }

        if let activeApp = workspace.frontmostApplication, !isBlockedApp(activeApp) {
            runningApps[activeApp] = now
        }

        addCurrentRunningApps()

        for (app, startDate) in runningApps where now.timeIntervalSince(startDate) > thresholdSeconds {
            guard app.isFinishedLaunching,
                  toggleStatus[app.localizedName ?? ""] ?? false else { continue }
            if quit(app) {
                runningApps[app] = nil
                os_log("quit %{public}@", log: log, type: .info, app.localizedName ?? "?")
            }
        }
    }
}
