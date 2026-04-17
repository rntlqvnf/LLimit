import Foundation
import UserNotifications
import SwiftUI

/// Fires a local notification the first time a usage window crosses the
/// user-configured threshold within a single reset cycle. The "cycle" is
/// keyed by `(accountId, windowLabel, resetsAt)` so a fresh notification
/// arrives after every reset, not on every poll.
@MainActor
final class UsageNotifier: ObservableObject {
    static let shared = UsageNotifier()

    private var notified: Set<String> = []

    private init() {}

    func requestAuthorization() {
        guard Self.isBundled else { return }
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }
    }

    /// `UNUserNotificationCenter.current()` aborts when the host process
    /// has no Info.plist bundle identifier (e.g. raw `swift run` build).
    /// In that case, silently skip notifications.
    private static let isBundled: Bool = {
        Bundle.main.bundleIdentifier != nil
    }()

    /// Inspect a freshly loaded snapshot and post one notification per
    /// window that newly crossed the threshold this cycle.
    func evaluate(account: Account, snapshot: UsageSnapshot) {
        guard Self.isBundled else { return }
        let threshold = UserDefaults.standard.double(forKey: "warnAtPercent")
        let pct = threshold > 0 ? threshold : 80
        let limit = pct / 100.0

        for w in snapshot.windows {
            guard let p = w.usedPercent, p >= limit else { continue }
            let resetTag = w.resetsAt.map { String(Int($0.timeIntervalSince1970)) } ?? "noreset"
            let key = "\(account.id.uuidString)|\(w.label)|\(resetTag)"
            if notified.contains(key) { continue }
            notified.insert(key)
            post(account: account, window: w, percent: p)
        }
    }

    private func post(account: Account, window: UsageWindow, percent: Double) {
        let content = UNMutableNotificationContent()
        content.title = "\(account.name) · \(window.label) at \(Int((percent * 100).rounded()))%"
        if let r = window.resetsAt {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .short
            content.body = "Resets \(f.localizedString(for: r, relativeTo: Date()))"
        } else {
            content.body = "Threshold reached."
        }
        content.sound = .default

        let req = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }
}
