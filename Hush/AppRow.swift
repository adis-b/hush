import SwiftUI
import AppKit

struct AppRow: View {
    let app: (key: NSRunningApplication, value: Date)
    @ObservedObject var manager: RunningAppsManager
    @AppStorage("minutesUntilClose") var minutesUntilClose: Int = 120
    @AppStorage("showCloseButton") var showCloseButton: Bool = false

    private var name: String { app.key.localizedName ?? String(localized: "approw.unknown", comment: "Unknown app name fallback") }

    private var shouldQuit: Binding<Bool> {
        Binding(
            get: { manager.toggleStatus[name] ?? false },
            set: { newValue in
                manager.toggleStatus[name] = newValue
                manager.saveToggleStatus()
            }
        )
    }

    private var residentBytes: UInt64? { manager.memoryUsage[app.key.processIdentifier] }

    // nil = no dot, calm apps stay quiet
    private var resourceColor: Color? {
        guard let bytes = residentBytes else { return nil }
        let mb = Double(bytes) / 1_048_576.0
        switch mb {
        case ..<300: return nil
        case 300..<1_000: return .green.opacity(0.55)
        case 1_000..<3_000: return .orange.opacity(0.65)
        default: return .red.opacity(0.75)
        }
    }

    private var resourceTooltip: String {
        guard let bytes = residentBytes else { return "" }
        let mb = Double(bytes) / 1_048_576.0
        return mb >= 1_024
            ? String(format: String(localized: "ram.gb", comment: "GB RAM tooltip"), mb / 1_024)
            : String(format: String(localized: "ram.mb", comment: "MB RAM tooltip"), mb)
    }

    var body: some View {
        let totalSeconds = minutesUntilClose * 60
        let secondsUntilClose = totalSeconds - Int(Date().timeIntervalSince(app.value))
        let isCloseToExpiry = secondsUntilClose < totalSeconds / 4
        let isExempt = manager.isExemptDuringFocus(app.key)

        HStack {
            Toggle("", isOn: shouldQuit)
                .toggleStyle(CheckboxToggleStyle())
                .labelsHidden()

            // .icon is cached by NSRunningApplication, no disk hit
            if let nsIcon = app.key.icon {
                Image(nsImage: nsIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
            }

            Circle()
                .fill(resourceColor ?? .clear)
                .frame(width: 6, height: 6)
                .help(resourceTooltip)

            Text(name)
                .frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
                .fontWeight(isCloseToExpiry && shouldQuit.wrappedValue && !isExempt ? .bold : .regular)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(shouldQuit.wrappedValue ? .primary : .gray)

            if isExempt {
                Text("approw.exempt.label", comment: "Short status for apps launched during focus")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help(String(localized: "approw.exempt.help", comment: "Help for exempt badge"))
            } else if shouldQuit.wrappedValue {
                Text(formatTime(seconds: secondsUntilClose))
                    .fontWeight(isCloseToExpiry ? .bold : .regular)
            }

            Button {
                manager.runningApps[app.key] = Date()
            } label: {
                Image(systemName: "arrow.uturn.backward.circle")
            }
            .buttonStyle(.plain)
            .disabled(!shouldQuit.wrappedValue)

            if showCloseButton {
                Button {
                    manager.forceQuit(app.key)
                } label: {
                    Image(systemName: "x.circle")
                }
                .buttonStyle(.plain)
                .disabled(!shouldQuit.wrappedValue)
            }
        }
    }

    private func formatTime(seconds: Int) -> String {
        if seconds >= 3600 {
            return String(format: String(localized: "timer.hours.left", comment: "Hours left format"), seconds / 3600)
        }
        if seconds >= 60 {
            return String(format: String(localized: "timer.minutes.left", comment: "Minutes left format"), seconds / 60)
        }
        return String(format: String(localized: "timer.seconds.left", comment: "Seconds left format"), seconds)
    }
}
