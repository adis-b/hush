//
//  HushApp.swift
//  Hush
//

import SwiftUI
import AppKit

let runningAppsManager = RunningAppsManager()

@main
struct HushApp: App {
    @ObservedObject private var manager = runningAppsManager

    var body: some Scene {
        MenuBarExtra("Hush", systemImage: "circle.fill") {
            ContentView(manager: manager)
        }
        .menuBarExtraStyle(.window)
    }
}
