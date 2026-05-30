//
//  TrackerAttentionNotifier.swift
//  MacosWidgetsStatsFromWebsite
//
//  Native notifications for broken trackers.
//

import Foundation
import UserNotifications

final class TrackerAttentionNotifier {
    static let shared = TrackerAttentionNotifier()

    static let categoryIdentifier = "TRACKER_NEEDS_ATTENTION"
    static let reidentifyActionIdentifier = "REIDENTIFY_TRACKER"

    private init() {}

    func configure() {
        let action = UNNotificationAction(
            identifier: Self.reidentifyActionIdentifier,
            title: "Re-identify Element",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [action],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyBrokenTracker(_ tracker: Tracker, failureCount: Int) {
        let configuration = AppGroupStore.loadSharedConfiguration()
        let title = "\(tracker.name.isEmpty ? "Tracker" : tracker.name) needs attention"
        let body = "The selector has failed \(failureCount) times. Open the app to re-identify the element."

        if configuration.preferences.notificationChannels.macosNative {
            sendNativeNotification(title: title, body: body, tracker: tracker)
        }

        if let webhookURL = configuration.preferences.notificationChannels.webhook {
            postWebhook(urlString: webhookURL, title: title, body: body, trackerID: tracker.id)
        }
    }

    // v0.21.74 — app-wide storage-write-failure alert. Distinct from
    // `notifyBrokenTracker` (which is per-tracker, selector-related). A write
    // fault (disk full / Group-Container permission denial / read-only volume)
    // affects ALL trackers because nothing can be persisted, so this is a
    // single generic notification driven by BackgroundScheduler once it sees a
    // run of consecutive write failures. Honours the same native + webhook
    // channel preferences as the broken-tracker path.
    func notifyStorageWriteFailure(failureCount: Int, detail: String) {
        let configuration = AppGroupStore.loadSharedConfiguration()
        let title = "Stats Widget can't save readings"
        let body = "The last \(failureCount) scrapes couldn't be written (\(detail)). Check disk space and the app's file permissions — widgets will show stale data until this is fixed."

        if configuration.preferences.notificationChannels.macosNative {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            // Stable identifier so repeated episodes replace rather than stack.
            content.threadIdentifier = "storage-write-failure"
            let request = UNNotificationRequest(
                identifier: "storage-write-failure",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }

        if let webhookURL = configuration.preferences.notificationChannels.webhook {
            postWebhook(urlString: webhookURL, title: title, body: body, trackerID: UUID())
        }
    }

    private func sendNativeNotification(title: String, body: String, tracker: Tracker) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = Self.categoryIdentifier
        content.sound = .default
        content.userInfo = ["trackerID": tracker.id.uuidString]
        content.threadIdentifier = "tracker-\(tracker.id.uuidString)"

        let request = UNNotificationRequest(
            identifier: "tracker-broken-\(tracker.id.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func postWebhook(urlString: String, title: String, body: String, trackerID: UUID) {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "title": title,
            "body": body,
            "severity": "broken",
            "trackerId": trackerID.uuidString
        ])

        URLSession.shared.dataTask(with: request).resume()
    }
}
