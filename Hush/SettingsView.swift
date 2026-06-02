import SwiftUI
import AppKit
import LaunchAtLogin

class SettingsWindowController: NSWindowController {
    static var current: SettingsWindowController?

    convenience init(rootView: SettingsView) {
        let hostingController = NSHostingController(rootView: rootView)
        // FIXME: macOS 26 crashes if hostingController.sizingOptions drives
        // sizing on a Grid (reentrant layout). Fixed size + ScrollView, manuell
        // resizebar, nicht angreifen.
        let initialSize = NSSize(width: 540, height: 640)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = String(localized: "settings.window.title", comment: "Settings window title")
        window.contentMinSize = NSSize(width: 540, height: 320)
        window.center()
        self.init(window: window)
        SettingsWindowController.current = self
    }

    deinit {
        SettingsWindowController.current = nil
    }
}

struct SettingsView: View {
    @ObservedObject var manager: RunningAppsManager
    @AppStorage("minutesUntilClose") var minutesUntilClose: Int = 120
    @AppStorage("showCloseButton") var showCloseButton: Bool = false
    @AppStorage("autoCheckNewApps") var autoCheckNewApps: Bool = false
    @AppStorage("quitOnDisplaySleep") var quitOnDisplaySleep: Bool = true
    @AppStorage("batteryAwareThresholdPercent") var batteryAwareThresholdPercent: Int = 30
    @AppStorage("forceTerminateUnsaved") var forceTerminateUnsaved: Bool = false
    @AppStorage("mirrorMacFocus") var mirrorMacFocus: Bool = false

    private let timeOptions = [15, 30, 45, 60, 90, 120, 240, 480, 720, 1440, 2880, 4320]
    private let batteryOptions = [0, 10, 20, 30, 40, 50] // 0 = off

    private func formatMinutes(_ minutes: Int) -> String {
        if minutes < 60 {
            return String(format: String(localized: "settings.idle.minutes"), minutes)
        } else if minutes % 60 == 0 {
            return String(format: String(localized: "settings.idle.hours"), minutes / 60)
        } else {
            let h = minutes / 60
            let m = minutes % 60
            return String(format: String(localized: "settings.idle.hoursAndMinutes"), h, m)
        }
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    private var appBuildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }

    @ViewBuilder
    private var macFocusStatusLine: some View {
        if !mirrorMacFocus {
            Text("settings.focus.mirror.desc", comment: "Focus mirror description")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if !manager.focusFilesReadable {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("settings.focus.fda.error", comment: "Full Disk Access error for Focus mirror")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button(String(localized: "settings.focus.fda.button", comment: "Open FDA settings")) { manager.openFullDiskAccessSettings() }
                        .controlSize(.small)
                }
                Text("\(String(localized: "settings.focus.diagnostic", comment: "Diagnostic label")) \(manager.focusReadError)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } else if manager.availableFocusModes.isEmpty {
            Text("settings.focus.no.modes", comment: "No Focus modes message")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("settings.focus.trigger.desc", comment: "Focus trigger intro")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(manager.availableFocusModes) { mode in
                    HStack(spacing: 6) {
                        Toggle(isOn: focusModeBinding(for: mode)) {
                            HStack(spacing: 6) {
                                Text(mode.name)
                                if manager.activeFocusModes.contains(mode.id) {
                                    Text("settings.focus.mode.on.badge", comment: "Active mode badge")
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(
                                            Capsule().fill(Color.accentColor.opacity(0.18))
                                        )
                                }
                            }
                        }
                        .toggleStyle(CheckboxToggleStyle())
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private func focusModeBinding(for mode: FocusMode) -> Binding<Bool> {
        Binding(
            get: { !manager.excludedFocusModes.contains(mode.id) },
            set: { included in
                var set = manager.excludedFocusModes
                if included { set.remove(mode.id) } else { set.insert(mode.id) }
                manager.excludedFocusModes = set
            }
        )
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(spacing: 4) {
                    Image("Image")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 96, height: 96)
                    Text("settings.header.appname", comment: "App name in header")
                        .font(.title)
                    Text("settings.header.slogan", comment: "Slogan in header")
                        .font(.callout)
                        .italic()
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 2)
                    Text("\(appVersion) · \(appBuildNumber)")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                        .monospacedDigit()
                        .padding(.top, 2)
                        .help(String(localized: "settings.version.help", comment: "Version tooltip"))
                }
                .padding(.top, 24)

                Divider()

                Grid(alignment: .leadingFirstTextBaseline,
                     horizontalSpacing: 16,
                     verticalSpacing: 12) {
                    GridRow {
                        Text("settings.startup.label", comment: "Settings row label")
                            .gridColumnAlignment(.trailing)
                            .foregroundStyle(.secondary)
                        LaunchAtLogin.Toggle {
                            Text("settings.toggle.launchatlogin", comment: "Label inside the Launch at Login toggle")
                        }
                    }
                    GridRow {
                        Text("settings.idle.label", comment: "Settings row label")
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Picker("", selection: $minutesUntilClose) {
                                ForEach(timeOptions, id: \.self) { minutes in
                                    Text(formatMinutes(minutes)).tag(minutes)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 120)
                            Text("settings.until.quitting", comment: "After idle picker")
                                .foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        Text("settings.quitbutton.label", comment: "Settings row label")
                            .foregroundStyle(.secondary)
                        Toggle(String(localized: "settings.toggle.show.close", comment: "Show close button toggle"),
                               isOn: $showCloseButton)
                    }
                    GridRow {
                        Text("settings.autocheck.label", comment: "Settings row label")
                            .foregroundStyle(.secondary)
                        Toggle(String(localized: "settings.toggle.autocheck", comment: "Auto check toggle"),
                               isOn: $autoCheckNewApps)
                    }
                    GridRow {
                        Text("settings.sleep.label", comment: "Settings row label")
                            .foregroundStyle(.secondary)
                        Toggle(String(localized: "settings.toggle.sleep", comment: "Sleep quit toggle"),
                               isOn: $quitOnDisplaySleep)
                    }
                    GridRow {
                        Text("settings.battery.label", comment: "Settings row label")
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Picker("", selection: $batteryAwareThresholdPercent) {
                                ForEach(batteryOptions, id: \.self) { pct in
                                    Text(pct == 0 ? String(localized: "settings.battery.off", comment: "Battery off") : "\(pct)%").tag(pct)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 80)
                            Text(batteryAwareThresholdPercent == 0
                                 ? String(localized: "settings.battery.ignore", comment: "Battery ignore")
                                 : String(localized: "settings.battery.halve", comment: "Battery halve"))
                                .foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        Text("settings.unsaved.label", comment: "Settings row label")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(String(localized: "settings.toggle.forcequit", comment: "Force quit toggle"),
                                   isOn: $forceTerminateUnsaved)
                            Text(String(localized: "settings.forcequit.explanation", comment: "Force quit explanation"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        Text("settings.focus.label", comment: "Settings row label")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(String(localized: "settings.toggle.mirror", comment: "Mirror macOS Focus toggle"),
                                   isOn: $mirrorMacFocus)
                                .onChange(of: mirrorMacFocus) { _ in manager.reevaluateFocusMirror() }
                            macFocusStatusLine
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)

                // tip jar, single line, no nag
                HStack(spacing: 6) {
                    Image(systemName: "cup.and.saucer.fill")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(String(localized: "settings.tip.built", comment: "Tip jar built solo"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Link(String(localized: "settings.tip.coffee", comment: "Buy coffee link"),
                         destination: URL(string: "https://buymeacoffee.com/hushapp")!)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .help(String(localized: "settings.tip.help", comment: "Tip jar help text"))
                .padding(.bottom, 18)

                Spacer(minLength: 0)
            }
        }
        .frame(minWidth: 520, minHeight: 480)
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView(manager: runningAppsManager)
    }
}
