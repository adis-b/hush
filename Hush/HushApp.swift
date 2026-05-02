//
//  HushApp.swift
//  Hush
//
//  Created by Janis Berneker on 30.06.23.
//

import SwiftUI
import AppKit

let runningAppsManager = RunningAppsManager()

@main
struct HushApp: App {
    @ObservedObject private var manager = runningAppsManager

    var body: some Scene {
        MenuBarExtra {
            ContentView(manager: manager)
        } label: {
            // tiny dot idle, slightly bigger + accent while focused
            let isFocus = manager.focusSessionEndDate != nil
            Image(systemName: "circle.fill")
                .font(.system(size: isFocus ? 8 : 6))
                .foregroundStyle(isFocus ? Color.accentColor : Color.primary)
        }
        .menuBarExtraStyle(.window)
    }
}
