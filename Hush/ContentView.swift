import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var manager: RunningAppsManager
    @State private var settingsWindowController: SettingsWindowController?

    // master toggle for all currently-running apps
    private var selectAllBinding: Binding<Bool> {
        Binding<Bool>(
            get: {
                let names = manager.runningApps.keys.compactMap { $0.localizedName }
                guard !names.isEmpty else { return false }
                return names.allSatisfy { manager.toggleStatus[$0] ?? false }
            },
            set: { newValue in
                for app in manager.runningApps.keys {
                    if let name = app.localizedName {
                        manager.toggleStatus[name] = newValue
                    }
                }
                manager.saveToggleStatus()
            }
        )
    }

    private var sortedApps: [(key: NSRunningApplication, value: Date)] {
        manager.runningApps.sorted { lhs, rhs in
            (lhs.key.localizedName ?? "").localizedCompare(rhs.key.localizedName ?? "") == .orderedAscending
        }
    }

    // HACK: MenuBarExtra(.window) keeps the max height it has ever shown,
    // leaves white space above/below when the list shrinks. Shrink it manually.
    private func resizeMenuBarWindowToFit() {
        DispatchQueue.main.async {
            for window in menuBarPopupWindows() {
                let fitting = window.contentView?.fittingSize ?? .zero
                if fitting.height > 0, fitting.height != window.frame.size.height {
                    window.setContentSize(fitting)
                }
            }
        }
    }

    private func dismissMenuBarPopup() {
        for window in menuBarPopupWindows() {
            window.orderOut(nil)
        }
    }

    // SwiftUI MenuBarExtra popup = visible, untitled, NSHosting content
    private func menuBarPopupWindows() -> [NSWindow] {
        NSApp.windows.filter { window in
            window.isVisible &&
            window.title.isEmpty &&
            window.contentView.map { String(describing: type(of: $0)).contains("NSHosting") } == true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                FocusSessionView(manager: manager)
                    .padding(.bottom, 5)

                Divider()
                    .padding(.bottom, 5)

                HStack {
                    Toggle("", isOn: selectAllBinding)
                        .toggleStyle(CheckboxToggleStyle())
                        .labelsHidden()
                        .disabled(manager.runningApps.isEmpty)

                    Text("content.select.all", comment: "Master checkbox label in the popover")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundColor(manager.runningApps.isEmpty ? .gray : .primary)
                }
                .padding(.vertical, 2)

                Divider()
                    .padding(.vertical, 3)

                ForEach(sortedApps, id: \.key) { app in
                    AppRow(app: app, manager: manager)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 5)

            Divider()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)

            MenuItemButton(title: String(localized: "content.menu.settings", comment: "Opens Settings window"), action: openSettings)
            MenuItemButton(title: String(localized: "content.menu.quit", comment: "Quits the Hush app itself")) { NSApplication.shared.terminate(nil) }
        }
        .frame(width: 314)
        .padding(5)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { resizeMenuBarWindowToFit() }
        .onChange(of: manager.runningApps.count) { _ in resizeMenuBarWindowToFit() }
        .onChange(of: manager.focusSessionEndDate) { _ in resizeMenuBarWindowToFit() }
    }

    private func openSettings() {
        dismissMenuBarPopup()
        if let existing = SettingsWindowController.current {
            existing.window?.makeKeyAndOrderFront(nil)
        } else {
            let controller = SettingsWindowController(rootView: SettingsView(manager: manager))
            settingsWindowController = controller
            controller.showWindow(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

// transparent normally, accent fill on hover. mimics native menu items.
private struct MenuItemButton: View {
    let title: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundColor(isHovered ? .white : .primary)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isHovered ? Color.accentColor : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(manager: runningAppsManager)
    }
}
