import SwiftUI
import AppKit

struct AppRow: View {
    let app: (key: NSRunningApplication, value: Date)
    @ObservedObject var manager: RunningAppsManager

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
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundColor(shouldQuit.wrappedValue ? .primary : .gray)
        }
    }
}
