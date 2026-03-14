//
//  HushApp.swift
//  Hush
//

import SwiftUI

@main
struct HushApp: App {
    var body: some Scene {
        MenuBarExtra("Hush", systemImage: "circle.fill") {
            ContentView()
        }
        .menuBarExtraStyle(.window)
    }
}
