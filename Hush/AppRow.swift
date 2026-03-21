import SwiftUI
import AppKit

struct AppRow: View {
    let app: (key: NSRunningApplication, value: Date)
    @ObservedObject var manager: RunningAppsManager
    @AppStorage("minutesUntilClose") var minutesUntilClose: Int = 120

    private var name: String { app.key.localizedName ?? "Unknown" }

    private var shouldQuit: Binding<Bool> {
        Binding(
            get: { manager.toggleStatus[name] ?? false },
            set: { newValue in
                manager.toggleStatus[name] = newValue
                manager.saveToggleStatus()
            }
        )
    }

    var body: some View {
        let totalSeconds = minutesUntilClose * 60
        let secondsUntilClose = totalSeconds - Int(Date().timeIntervalSince(app.value))
        let isCloseToExpiry = secondsUntilClose < totalSeconds / 4

        HStack {
            Toggle("", isOn: shouldQuit)
                .toggleStyle(CheckboxToggleStyle())
                .labelsHidden()

            if let nsIcon = app.key.icon {
                Image(nsImage: nsIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
            }

            Text(name)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fontWeight(isCloseToExpiry && shouldQuit.wrappedValue ? .bold : .regular)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(shouldQuit.wrappedValue ? .primary : .gray)

            if shouldQuit.wrappedValue {
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
        }
    }

    private func formatTime(seconds: Int) -> String {
        if seconds >= 3600 { return "\(seconds / 3600)h left" }
        if seconds >= 60 { return "\(seconds / 60)m left" }
        return "\(seconds)s left"
    }
}
