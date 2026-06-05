import SwiftUI
import AppKit
import Combine
import Darwin
import IOKit.ps
import UserNotifications
import Carbon.HIToolbox
import os.log


// system stuff we never touch even if ticked
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


fileprivate func residentMemory(forPid pid: pid_t) -> UInt64? {
    var info = proc_taskinfo()
    let size = MemoryLayout<proc_taskinfo>.stride
    let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(size))
    guard result == Int32(size) else { return nil }
    return info.pti_resident_size
}

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


// TODO: split this monster into a couple of smaller managers someday
class RunningAppsManager: ObservableObject {
    @Published var runningApps: [NSRunningApplication: Date] = [:]
    @Published var toggleStatus: [String: Bool] = [:]
    @Published var focusSessionEndDate: Date?

    // pids of apps that started after focus began. keyed by pid not bundle
    // so a relaunch gets the exemption but a stale pre-session instance doesn't.
    @Published private(set) var focusSessionExemptPIDs: Set<pid_t> = []
    @Published var memoryUsage: [pid_t: UInt64] = [:]
    @Published var activeFocusModes: Set<String> = []
    @Published var availableFocusModes: [FocusMode] = []
    @Published var focusFilesReadable: Bool = false
    @Published var focusReadError: String = ""
    @Published var focusModesParseNote: String = ""

    @AppStorage("minutesUntilClose") var minutesUntilClose: Int = 120
    @AppStorage("com.MagicQuit.toggleStatus") var toggleStatusData: Data = Data()
    @AppStorage("autoCheckNewApps") var autoCheckNewApps: Bool = false
    @AppStorage("quitOnDisplaySleep") var quitOnDisplaySleep: Bool = true
    // 0 = aus
    @AppStorage("batteryAwareThresholdPercent") var batteryAwareThresholdPercent: Int = 30
    @AppStorage("lastFocusDuration") var lastFocusDuration: Int = 25
    @AppStorage("forceTerminateUnsaved") var forceTerminateUnsaved: Bool = false
    @AppStorage("mirrorMacFocus") var mirrorMacFocus: Bool = false
    @AppStorage("logFocusToCalendar") var logFocusToCalendar: Bool = false
    // JSON [String] of mode ids the user opted out from
    @AppStorage("excludedFocusModes") var excludedFocusModesData: Data = Data()

    @Published var calendarAccessDenied: Bool = false
    // nil = alerts OK; non-nil = localized settings key for the issue
    @Published var notificationIssueKey: String?
    // true while macOS will still show the allow/deny sheet (notDetermined)
    @Published private(set) var notificationNeedsPrompt: Bool = false

    private var focusSessionStartDate: Date?
    private var focusSessionAnchorAppName: String?
    private var calendarLogger: Any?
    private let calendarMinLogSeconds: TimeInterval = 300
    private let focusSessionGracePeriodSeconds = 30
    private let memorySamplingInterval: TimeInterval = 3
    private var lastMemorySample: Date = .distantPast
    private var timer: Timer?
    private var focusHotkey: GlobalHotkey?
    // only auto-end sessions we auto-started
    private var focusStartedByMacFocus = false
    private var focusMirror: FocusMirror?

    private let log = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "RunningAppsManager")
    
    init() {
        let defaults = UserDefaults.standard
        // Migration: hoursUntilClose -> minutesUntilClose
        if defaults.object(forKey: "minutesUntilClose") == nil,
           let oldHours = defaults.object(forKey: "hoursUntilClose") as? Int {
            defaults.set(oldHours * 60, forKey: "minutesUntilClose")
            defaults.removeObject(forKey: "hoursUntilClose")
            minutesUntilClose = oldHours * 60
        }
        // Migration: altes Bool -> Int %-Schwelle
        if defaults.object(forKey: "batteryAwareThresholdPercent") == nil,
           let oldBool = defaults.object(forKey: "batteryAwareThreshold") as? Bool {
            batteryAwareThresholdPercent = oldBool ? 30 : 0
            defaults.removeObject(forKey: "batteryAwareThreshold")
        }

        syncToggleStatus()
        addCurrentRunningApps()

        focusMirror = FocusMirror { [weak self] in self?.refreshFocusState() }
        refreshFocusState()

        // user often grants FDA in System Settings then returns here
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.focusMirror?.ensureWatching(force: true)
            self.refreshFocusState()
            self.refreshNotificationStatus()
            self.refreshCalendarStatus()
        }

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
        // app launched while focused = deliberate, exempt
        workspaceCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                    object: nil,
                                    queue: .main) { [weak self] notification in
            guard let self = self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  !self.isBlockedApp(app) else { return }
            if self.focusSessionEndDate != nil {
                self.focusSessionExemptPIDs.insert(app.processIdentifier)
            }
        }
        // lid close / display sleep / menu Sleep
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.handleDisplaysWillSleep()
            }
        }

        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        refreshNotificationStatus()
        // defer prompt to Settings "Allow" or first focus end; init request was easy to miss

        // ⌥⌘H toggles focus from anywhere
        self.focusHotkey = GlobalHotkey(keyCode: UInt32(kVK_ANSI_H),
                                        modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.toggleFocusSession()
        }

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
        if (popupOpen && now.timeIntervalSince(lastMemorySample) >= memorySamplingInterval) || atMinuteBoundary {
            refreshMemoryUsage()
            lastMemorySample = now
        }
        if let end = focusSessionEndDate, now >= end {
            endFocusSession(reason: .completed)
        }
        // backstop in case the DispatchSource dropped an event
        if mirrorMacFocus, atMinuteBoundary {
            refreshFocusState()
        }
    }

    // default terminate() is the data-safe macOS path. forceTerminateUnsaved
    // opts in to forceTerminate + SIGKILL fallback (Office-helper fressen
    // terminate(), drum SIGKILL).
    @discardableResult
    private func quit(_ app: NSRunningApplication) -> Bool {
        if forceTerminateUnsaved {
            let pid = app.processIdentifier
            let label = app.localizedName ?? app.bundleIdentifier ?? "?"
            let ok = app.forceTerminate()
            scheduleSigkillFallback(pid: pid, label: label, after: 4.0)
            return ok
        }
        return app.terminate()
    }

    // x-button: user explicitly wants this dead, ignore the unsaved setting
    func forceQuit(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        let label = app.localizedName ?? app.bundleIdentifier ?? "?"
        _ = app.forceTerminate()
        scheduleSigkillFallback(pid: pid, label: label, after: 4.0)
        runningApps[app] = nil
    }

    // FIXME: 4s is arbitrary, just felt right on a fresh MBP
    private func scheduleSigkillFallback(pid: pid_t, label: String, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            // signal 0 = probe; 0 alive, -1 gone
            guard kill(pid, 0) == 0 else { return }
            os_log("sigkill %{public}@ %d", log: self.log, type: .info, label, pid)
            _ = kill(pid, SIGKILL)
        }
    }

    // MARK: - macOS Focus mirroring

    var excludedFocusModes: Set<String> {
        get {
            (try? JSONDecoder().decode([String].self, from: excludedFocusModesData))
                .map(Set.init) ?? []
        }
        set {
            excludedFocusModesData = (try? JSONEncoder().encode(Array(newValue).sorted())) ?? Data()
            objectWillChange.send()
            // re-evaluate, don't wait for next FS change
            refreshFocusState()
        }
    }

    func openFullDiskAccessSettings() {
        let urls = [
            // macOS 13+ System Settings
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
            // Ventura fallback
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    func refreshNotificationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                self.notificationNeedsPrompt = settings.authorizationStatus == .notDetermined
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    if settings.alertSetting == .disabled {
                        self.notificationIssueKey = "settings.notifications.alertsOff"
                    } else {
                        self.notificationIssueKey = nil
                    }
                case .notDetermined:
                    self.notificationIssueKey = "settings.notifications.notDetermined"
                case .denied:
                    self.notificationIssueKey = "settings.notifications.denied"
                @unknown default:
                    self.notificationIssueKey = "settings.notifications.denied"
                }
            }
        }
    }

    // user gesture: shows the system sheet when still notDetermined; registers Hush in Notifications.
    func requestNotificationAccess() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            NotificationRegistration.repairLaunchServices()

            let priorPolicy = NSApp.activationPolicy()
            if priorPolicy == .accessory {
                NSApp.setActivationPolicy(.regular)
            }
            NSApp.activate(ignoringOtherApps: true)
            SettingsWindowController.current?.window?.makeKeyAndOrderFront(nil)

            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                DispatchQueue.main.async {
                    if priorPolicy == .accessory {
                        NSApp.setActivationPolicy(.accessory)
                    }
                    if let error {
                        os_log("notification auth request failed %{public}@",
                               log: self.log, type: .error, error.localizedDescription)
                    }
                    self.refreshNotificationStatus()
                    if granted {
                        os_log("notification auth granted", log: self.log, type: .info)
                        return
                    }
                    let stillNeeds = self.notificationNeedsPrompt
                    if stillNeeds || self.notificationIssueKey == "settings.notifications.denied" {
                        NotificationRegistration.presentAccessFailureAlert(error: error, stillNeedsPrompt: stillNeeds)
                    }
                }
            }
        }
    }

    func openNotificationSettings() {
        let bundleId = Bundle.main.bundleIdentifier ?? "com.MagicQuit"
        let urls = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleId)",
            "x-apple.systempreferences:com.apple.preference.notifications?id=\(bundleId)",
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    func openCalendarSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Calendars",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars",
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    func requestCalendarAccess(completion: ((Bool) -> Void)? = nil) {
        guard #available(macOS 14, *) else {
            completion?(false)
            return
        }
        ensureCalendarLogger()
        guard let logger = calendarLogger as? CalendarLogger else {
            completion?(false)
            return
        }

        switch logger.access {
        case .writeOnlyOrBetter:
            calendarAccessDenied = false
            completion?(true)
        case .denied:
            // can't prompt again once denied, point the user at System Settings
            calendarAccessDenied = true
            completion?(false)
        case .notDetermined:
            // EventKit shows the TCC sheet fine for accessory apps. Do NOT flip
            // activation policy here, it orders the Settings window out on Sequoia.
            logger.requestAccess { [weak self] granted in
                self?.calendarAccessDenied = !granted
                completion?(granted)
            }
        }
    }

    func refreshCalendarStatus() {
        guard #available(macOS 14, *) else { return }
        ensureCalendarLogger()
        guard let logger = calendarLogger as? CalendarLogger else { return }
        // only flag denied while the user actually wants logging
        calendarAccessDenied = logFocusToCalendar && logger.access == .denied
    }

    private func ensureCalendarLogger() {
        if #available(macOS 14, *), calendarLogger == nil {
            calendarLogger = CalendarLogger()
        }
    }

    private func anchorName(for app: NSRunningApplication?) -> String? {
        guard let app,
              let bundleId = app.bundleIdentifier,
              bundleId != Bundle.main.bundleIdentifier,
              bundleId != "com.apple.finder" else {
            return nil
        }
        return app.localizedName
    }

    private func refreshFocusState() {
        guard let mirror = focusMirror else { return }
        mirror.ensureWatching()

        focusFilesReadable = mirror.checkFilesAccessible()
        focusReadError = mirror.lastReadError
        availableFocusModes = mirror.availableModes()
        focusModesParseNote = mirror.lastModesParseNote
        let nowActive = mirror.activeModeIdentifiers()
        if nowActive != activeFocusModes { activeFocusModes = nowActive }

        guard mirrorMacFocus else { return }
        let triggering = nowActive.subtracting(excludedFocusModes)
        let shouldBeFocused = !triggering.isEmpty

        if shouldBeFocused, focusSessionEndDate == nil {
            startFocusSession(minutes: lastFocusDuration, startedByMacFocus: true)
        } else if !shouldBeFocused, focusStartedByMacFocus, focusSessionEndDate != nil {
            cancelFocusSession()
        }
    }

    func reevaluateFocusMirror() { refreshFocusState() }

    func focusMirrorRearmAndRefresh() {
        focusMirror?.ensureWatching(force: true)
        refreshFocusState()
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

    // MARK: - Focus session

    enum FocusSessionEndReason {
        case completed, cancelled
    }

    func startFocusSession(minutes: Int, startedByMacFocus: Bool = false) {
        focusStartedByMacFocus = startedByMacFocus
        lastFocusDuration = minutes
        focusSessionEndDate = Date().addingTimeInterval(Double(minutes * 60))
        focusSessionExemptPIDs = [] // alles offene = fair game
        let frontmost = NSWorkspace.shared.frontmostApplication
        focusSessionStartDate = Date()
        focusSessionAnchorAppName = anchorName(for: frontmost)
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
        let now = Date()
        let sessionStart = focusSessionStartDate
        let anchorApp = focusSessionAnchorAppName
        let plannedSeconds = Double(lastFocusDuration * 60)
        let elapsed = sessionStart.map { now.timeIntervalSince($0) } ?? 0

        if logFocusToCalendar, #available(macOS 14, *), let sessionStart,
           now.timeIntervalSince(sessionStart) >= calendarMinLogSeconds {
            ensureCalendarLogger()
            (calendarLogger as? CalendarLogger)?.log(start: sessionStart, end: now, appName: anchorApp)
        }

        focusSessionStartDate = nil
        focusSessionAnchorAppName = nil
        focusSessionEndDate = nil
        focusStartedByMacFocus = false
        focusSessionExemptPIDs = []

        // Stop / ⌥⌘H ends as .cancelled; still notify if they were in the last ~90s
        let shouldNotify = reason == .completed
            || (reason == .cancelled && elapsed >= plannedSeconds - 90)
        guard shouldNotify else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "notification.focus.complete.title", comment: "Notification title")
        content.body = (lastFocusDuration == 25)
            ? String(localized: "notification.focus.pomodoro.body", comment: "Pomodoro completion message")
            : String(localized: "notification.focus.complete.body", comment: "Generic focus completion message")
        UNUserNotificationCenter.current().getNotificationSettings { [log] settings in
            guard settings.authorizationStatus == .authorized,
                  settings.alertSetting == .enabled else {
                os_log("notification skipped: auth=%{public}d alert=%{public}d",
                       log: log, type: .info,
                       settings.authorizationStatus.rawValue,
                       settings.alertSetting.rawValue)
                return
            }
            let request = UNNotificationRequest(identifier: "hush.focus.complete.\(now.timeIntervalSince1970)",
                                                content: content,
                                                trigger: nil)
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    os_log("notification add failed %{public}@",
                           log: log, type: .error, error.localizedDescription)
                }
            }
        }
    }

    private func refreshMemoryUsage() {
        var snapshot: [pid_t: UInt64] = [:]
        for app in runningApps.keys {
            let pid = app.processIdentifier
            guard pid > 0 else { continue }
            if let bytes = residentMemory(forPid: pid) {
                snapshot[pid] = bytes
            }
        }
        if snapshot != memoryUsage {
            memoryUsage = snapshot
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
        let inFocus = focusSessionEndDate != nil
        for app in NSWorkspace.shared.runningApplications where !isBlockedApp(app) && runningApps[app] == nil {
            runningApps[app] = now
            applyAutoCheckIfNeeded(for: app)
            // belt+braces: didLaunchApplicationNotification can drop under load
            if inFocus {
                focusSessionExemptPIDs.insert(app.processIdentifier)
            }
        }
    }

    func isExemptDuringFocus(_ app: NSRunningApplication) -> Bool {
        focusSessionEndDate != nil && focusSessionExemptPIDs.contains(app.processIdentifier)
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

        // drop dead/blocked entries in one filter pass = one @Published mutation
        runningApps = runningApps.filter { liveApps.contains($0.key) && !isBlockedApp($0.key) }

        // bump the active app's timestamp so the countdown rolls forward
        if let activeApp = workspace.frontmostApplication, !isBlockedApp(activeApp) {
            runningApps[activeApp] = now
        }

        addCurrentRunningApps()

        for (app, startDate) in runningApps where now.timeIntervalSince(startDate) > thresholdSeconds {
            guard app.isFinishedLaunching,
                  toggleStatus[app.localizedName ?? ""] ?? false,
                  !isExemptDuringFocus(app) else { continue }
            if quit(app) {
                runningApps[app] = nil
            }
        }
    }
}
