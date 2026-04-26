import SwiftUI
import AppKit
import LaunchAtLogin

class SettingsWindowController: NSWindowController {
    static var current: SettingsWindowController?

    convenience init(rootView: SettingsView) {
        let hostingController = NSHostingController(rootView: rootView)
        hostingController.sizingOptions = [.preferredContentSize]
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 460, height: 380)),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.title = "Settings"
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
    @AppStorage("autoCheckNewApps") var autoCheckNewApps: Bool = false
    @AppStorage("quitOnDisplaySleep") var quitOnDisplaySleep: Bool = true
    @AppStorage("batteryAwareThresholdPercent") var batteryAwareThresholdPercent: Int = 30
    @AppStorage("forceTerminateUnsaved") var forceTerminateUnsaved: Bool = false
    @AppStorage("showCloseButton") var showCloseButton: Bool = false

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

    var body: some View {
        VStack(spacing: 16) {
            Text("Hush").font(.title).padding(.top, 16)
            Divider()

            Form {
                LaunchAtLogin.Toggle()

                Picker("Idle time:", selection: $minutesUntilClose) {
                    ForEach(timeOptions, id: \.self) { minutes in
                        Text(formatMinutes(minutes)).tag(minutes)
                    }
                }

                Toggle("Automatically check newly opened apps", isOn: $autoCheckNewApps)

                Toggle("Quit checked apps when display sleeps", isOn: $quitOnDisplaySleep)

                Toggle("Force-quit apps with unsaved data", isOn: $forceTerminateUnsaved)

                Toggle("Show ✕ next to each app", isOn: $showCloseButton)

                Picker("Low battery threshold:", selection: $batteryAwareThresholdPercent) {
                    ForEach(batteryOptions, id: \.self) { pct in
                        Text(pct == 0 ? "Off" : "\(pct)%").tag(pct)
                    }
                }

                Divider()

                Toggle("Start focus when macOS Focus is on", isOn: $manager.mirrorMacFocus)

                if manager.mirrorMacFocus {
                    if manager.focusFilesReadable {
                        if manager.availableFocusModes.isEmpty {
                            Text("No Focus modes set up yet.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(manager.availableFocusModes) { mode in
                                Toggle(mode.name, isOn: focusModeBinding(for: mode.id))
                                    .padding(.leading, 16)
                            }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Hush needs Full Disk Access to read your Focus modes.")
                                .font(.caption).foregroundStyle(.secondary)
                            if let err = manager.focusReadError {
                                Text("errno \(err)").font(.caption2).foregroundStyle(.secondary)
                            }
                            Button("Open System Settings", action: manager.openFullDiskAccessSettings)
                                .controlSize(.small)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)

            Spacer()
        }
        .frame(width: 460, height: 420)
    }

    private func focusModeBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { !manager.excludedFocusModes.contains(id) },
            set: { include in
                var set = manager.excludedFocusModes
                if include { set.remove(id) } else { set.insert(id) }
                manager.excludedFocusModes = set
            }
        )
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView(manager: runningAppsManager)
    }
}
