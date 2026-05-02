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
        window.title = "Settings"
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
            return "\(minutes) min"
        } else if minutes % 60 == 0 {
            return "\(minutes / 60)h"
        } else {
            return "\(minutes / 60)h \(minutes % 60)min"
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
            Text("Detects Do Not Disturb, Reduce Interruptions, Work, and any custom Focus mode.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if !manager.focusFilesReadable {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("Hush can't read your Focus state. Grant Full Disk Access in System Settings, then re-toggle Hush in the FDA list after redeploying.")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Button("Open") { manager.openFullDiskAccessSettings() }
                        .controlSize(.small)
                }
                Text("Diagnostic: \(manager.focusReadError)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } else if manager.availableFocusModes.isEmpty {
            Text("No Focus modes configured on this Mac yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Trigger Hush when any of these are on:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(manager.availableFocusModes) { mode in
                    HStack(spacing: 6) {
                        Toggle(isOn: focusModeBinding(for: mode)) {
                            HStack(spacing: 6) {
                                Text(mode.name)
                                if manager.activeFocusModes.contains(mode.id) {
                                    Text("on")
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
                    Text("Hush")
                        .font(.title)
                    Text("Hush the noise. Reclaim your focus.")
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
                        .help("Build identifier, short git commit hash.")
                }
                .padding(.top, 24)

                Divider()

                Grid(alignment: .leadingFirstTextBaseline,
                     horizontalSpacing: 16,
                     verticalSpacing: 12) {
                    GridRow {
                        Text("Startup:")
                            .gridColumnAlignment(.trailing)
                            .foregroundStyle(.secondary)
                        LaunchAtLogin.Toggle()
                    }
                    GridRow {
                        Text("Idle time:")
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Picker("", selection: $minutesUntilClose) {
                                ForEach(timeOptions, id: \.self) { minutes in
                                    Text(formatMinutes(minutes)).tag(minutes)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 120)
                            Text("until quitting")
                                .foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        Text("Quit button:")
                            .foregroundStyle(.secondary)
                        Toggle("Show a button to quit apps manually",
                               isOn: $showCloseButton)
                    }
                    GridRow {
                        Text("Auto-check:")
                            .foregroundStyle(.secondary)
                        Toggle("Automatically check newly opened apps",
                               isOn: $autoCheckNewApps)
                    }
                    GridRow {
                        Text("On sleep:")
                            .foregroundStyle(.secondary)
                        Toggle("Quit checked apps when the display sleeps",
                               isOn: $quitOnDisplaySleep)
                    }
                    GridRow {
                        Text("Low battery:")
                            .foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Picker("", selection: $batteryAwareThresholdPercent) {
                                ForEach(batteryOptions, id: \.self) { pct in
                                    Text(pct == 0 ? "Off" : "\(pct)%").tag(pct)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 80)
                            Text(batteryAwareThresholdPercent == 0
                                 ? "ignore battery level"
                                 : "halve idle time when below this on battery")
                                .foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        Text("Unsaved data:")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Force-quit even apps with unsaved changes (may lose data)",
                                   isOn: $forceTerminateUnsaved)
                            Text("Also escalates to SIGKILL after ~4 s for stuck apps (e.g. Microsoft Office).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        Text("macOS Focus:")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle("Start a Hush focus session when a Mac Focus mode turns on",
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
                    Text("Built solo.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Link("Buy me a coffee.",
                         destination: URL(string: "https://buymeacoffee.com/hushapp")!)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .help("Hush is free and ad-hoc signed by a single developer. If it earned a place in your menu bar, a coffee is appreciated.")
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
