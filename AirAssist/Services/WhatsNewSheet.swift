import AppKit
import Foundation

/// Per-version "what's new" sheet, shown once after an upgrade.
///
/// Distinct from `FirstRunDisclosure` (legal/safety, shown once ever
/// on the first launch). This one only fires when the app version
/// differs from the last version the user has acknowledged here, so
/// brand-new installs see the disclosure and *not* this sheet (their
/// `lastSeenVersion` is seeded to the current version on first launch).
///
/// Highlights live in the static `entries` table — one tuple per
/// version we want to flag. Adding a new release is a one-line edit.
@MainActor
enum WhatsNewSheet {

    private static let lastSeenKey = "whatsNew.lastSeenVersion"

    /// Ordered newest → oldest. Add a new entry at the top each release.
    /// Showing more than one version at a time covers users who skipped
    /// an intermediate release.
    private static let entries: [(version: String, title: String, bullets: [String])] = [
        (
            "0.11.0",
            "What's new in 0.11",
            [
                "Never-throttle list — apps you protect explicitly, never paused",
                "Status bar icon now shows three states: idle / armed / throttling",
                "Scenario presets — Presenting, Quiet, Performance, Auto",
                "Recent throttle activity panel on the dashboard",
                "Show in Activity Monitor from the popover context menu",
                "Opt-in system notifications when the governor engages"
            ]
        ),
        (
            "0.10.0",
            "What's new in 0.10",
            [
                "Stay Awake quick picker in the popover",
                "Governor master toggle and \"on battery only\" inline",
                "Throttle frontmost button with click-to-release",
                "Quick throttles strip showing live countdowns"
            ]
        ),
    ]

    /// Current app version, read from Info.plist.
    private static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Call after `FirstRunDisclosure.presentIfNeeded()`. On the very first
    /// launch the disclosure runs and we silently seed `lastSeenVersion` so
    /// the new user doesn't get a "what's new" sheet for an app they just
    /// installed. Subsequent launches compare versions and fire the sheet
    /// at most once per upgrade.
    static func presentIfNeeded() {
        let last = UserDefaults.standard.string(forKey: lastSeenKey)
        let current = currentVersion
        defer { UserDefaults.standard.set(current, forKey: lastSeenKey) }

        guard let last else {
            // First launch ever (or first launch since this key was added).
            // Don't show a sheet — just seed the marker.
            return
        }
        guard last != current else { return }

        // Pick all entries newer than `last`. Simple string compare suffices
        // for our SemVer range (0.x.y); when 1.0 lands, swap to a real
        // comparator.
        let toShow = entries.filter { $0.version > last && $0.version <= current }
        guard let topmost = toShow.first else { return }

        present(entry: topmost, more: toShow.count - 1)
    }

    private static func present(entry: (version: String, title: String, bullets: [String]),
                                more: Int) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = entry.title
        var body = entry.bullets.map { "•  \($0)" }.joined(separator: "\n")
        if more > 0 {
            body += "\n\n(\(more) earlier release\(more == 1 ? "" : "s") since you last opened the app — see the full changelog on GitHub.)"
        }
        alert.informativeText = body
        alert.addButton(withTitle: "Got it")
        alert.addButton(withTitle: "View Changelog")

        if alert.runModal() == .alertSecondButtonReturn {
            if let url = URL(string: "https://github.com/sjschillinger/airassist/blob/main/CHANGELOG.md") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
