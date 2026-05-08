//
//  AppDelegate.swift
//  MacosWidgetsStatsFromWebsite
//
//  v0.1 stub — see PLAN.md §4 for the full design.
//

import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        TrackerAttentionNotifier.shared.configure()
        UpdateController.shared.start()
        MCPServer.shared.startSocketServer()
        bringAppToFrontOnLaunch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        ChromeBrowserProfile.shared.terminateAppOwnedBrowsersOnAppExit()
        MCPServer.shared.stopSocketServer()
    }

    /// Single-window app behaviour: when the user (re)launches the app while
    /// another instance is already running, focus the existing window instead
    /// of opening a second one. macOS calls `applicationShouldHandleReopen`
    /// when the dock icon is clicked or the app is reopened with no visible
    /// windows; returning `true` lets AppKit run its default reopen logic
    /// (which makes the main window key and ordered front).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows where window.canBecomeKey {
                window.makeKeyAndOrderFront(nil)
            }
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "macos-widgets-stats-from-website" {
                openDeepLink(url)
            } else if url.pathExtension.lowercased() == SelectorPack.fileExtension {
                do {
                    _ = try SelectorPackImportCoordinator.importSelectorPack(at: url)
                } catch {
                    MCPInvocationLoggerProxy.logImportFailure(error)
                }
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let trackerIDString = response.notification.request.content.userInfo["trackerID"] as? String,
           let trackerID = UUID(uuidString: trackerIDString) {
            NSApp.activate(ignoringOtherApps: true)
            AppNavigationEvents.openTrackerSettings(trackerID: trackerID)
        }

        completionHandler()
    }

    private func openDeepLink(_ url: URL) {
        guard url.host == "tracker",
              let trackerIDString = url.pathComponents.dropFirst().first,
              let trackerID = UUID(uuidString: trackerIDString) else {
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        AppNavigationEvents.openTrackerSettings(trackerID: trackerID)
    }

    private func bringAppToFrontOnLaunch() {
        DispatchQueue.main.async {
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            NSApp.activate(ignoringOtherApps: true)

            for window in NSApp.windows where window.canBecomeKey {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}

private enum MCPInvocationLoggerProxy {
    static func logImportFailure(_ error: Error) {
        let directory = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/macOS Widgets Stats from Website", isDirectory: true)
        let url = directory.appendingPathComponent("selector-pack-import.log", isDirectory: false)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(error.localizedDescription)\n"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
                try handle.close()
            } else {
                try Data(line.utf8).write(to: url, options: .atomic)
            }
        } catch {}
    }
}
