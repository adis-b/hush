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

                Picker("Low battery threshold:", selection: $batteryAwareThresholdPercent) {
                    ForEach(batteryOptions, id: \.self) { pct in
                        Text(pct == 0 ? "Off" : "\(pct)%").tag(pct)
                    }
                }
            }
            .padding(.horizontal, 24)

            Spacer()
        }
        .frame(width: 460, height: 380)
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView(manager: runningAppsManager)
    }
}
