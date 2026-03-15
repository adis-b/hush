//
//  ContentView.swift
//  Hush
//

import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var manager: RunningAppsManager

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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("", isOn: selectAllBinding)
                    .toggleStyle(CheckboxToggleStyle())
                    .labelsHidden()
                    .disabled(manager.runningApps.isEmpty)

                Text("Select All")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 2)

            Divider().padding(.vertical, 3)

            ForEach(sortedApps, id: \.key) { app in
                AppRow(app: app, manager: manager)
            }

            Divider().padding(.vertical, 5)

            Button("Quit Hush") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
        }
        .padding(10)
        .frame(width: 314)
    }
}
