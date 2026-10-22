//
//  main.swift
//  Niri macOS GUI Launcher
//

import SwiftUI
import AppKit

@main
struct NiriApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Niri on macOS - Unified Manager", id: "main") {
            ContentView()
                .frame(minWidth: 920, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Compositor") {
                Button("Start All") {
                    AppCoordinator.shared.startAll()
                }
                .keyboardShortcut("r", modifiers: [.command])

                Button("Stop All") {
                    AppCoordinator.shared.stopAll()
                }
                .keyboardShortcut(".", modifiers: [.command])

                Divider()

                Button("Refresh Windows") {
                    CompositorManager.shared.refreshWindows()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppCoordinator.shared.stopAll()
    }
}
