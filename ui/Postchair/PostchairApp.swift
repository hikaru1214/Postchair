//
//  PostchairApp.swift
//  Postchair
//
//  Created by 筒井光 on 2026/03/19.
//

import AppKit
import SwiftUI

@main
struct PostchairApp: App {
    @NSApplicationDelegateAdaptor(PostchairAppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        Window("Postchair", id: "dashboard") {
            DashboardWindowView()
                .environmentObject(appState)
                .task {
                    await appState.prepareIfNeeded()
                    PostchairAppDelegate.sharedAppState = appState
                }
                .frame(minWidth: 800, minHeight: 547)
        }
        .defaultSize(width: 947, height: 613)

        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(appState)
                .task {
                    await appState.prepareIfNeeded()
                    PostchairAppDelegate.sharedAppState = appState
                }
        } label: {
            Label(appState.menuBarTitle, systemImage: appState.menuBarSymbol)
        }
    }
}

final class PostchairAppDelegate: NSObject, NSApplicationDelegate {
    static weak var sharedAppState: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task {
            await PostchairAppDelegate.sharedAppState?.shutdown()
        }
    }
}
