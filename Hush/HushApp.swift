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

    init() {
        // Normalize AppleLanguages to bare two-letter ISO 639 codes (e.g. "en" instead of "en-US").
        // This prevents system frameworks like GenerativeModelsAvailability from logging
        // "Initialized with invalid language code: en-US" (and similar for other regions).
        // The launch args in the Xcode schemes do the same for debug runs; this makes it
        // robust even for direct launches and for all localized languages we support.
        if let languages = UserDefaults.standard.array(forKey: "AppleLanguages") as? [String] {
            let normalized = languages.map { $0.components(separatedBy: "-").first ?? $0 }
            UserDefaults.standard.set(normalized, forKey: "AppleLanguages")
        }
    }

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
