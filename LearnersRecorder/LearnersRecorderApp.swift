//
//  LeanersRecorderApp.swift
//  LeanersRecorder
//
//  Created by dpc on 2025-10-11.
//

import SwiftUI
import AppKit

// MARK: - App
@main
struct LeanersRecorderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        
        // Add a custom command group for the About menu
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Leaner's Recorder") {
                    let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "LeanersRecorder"
                    let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
                    let appBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"

                    let alert = NSAlert()
                    alert.messageText = "About \(appName)"
                    alert.informativeText = "Version: \(appVersion) (Build \(appBuild))\nSource code: \nhttps://github.com/vpnry/learners_recorder"
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }
}

