import Foundation
import UserNotifications
import os

/// Posts a system notification when the thermal governor engages — the
/// moment its cap is first breached after a quiet period — so the user
/// finds out the OS is being throttled even when Air Assist isn't visible.
///
/// Opt-in via the `notifications.governor` UserDefaults key. When the
/// user flips it on, `requestAuthorizationIfNeeded()` is the right
/// entry point: it triggers the system permission prompt only the first
/// time and is otherwise a no-op.
///
/// Posts on rising edge of `isTempThrottling || isCPUThrottling` and
/// respects a minimum re-trigger interval so quick on/off flapping
/// doesn't fire repeated banners.
@MainActor
final class GovernorNotifier {

    private static let logger = Logger(subsystem: "com.sjschillinger.airassist", category: "notify")
    private static let prefKey = "notifications.governor"
    private static let cooldown: TimeInterval = 60   // suppress re-fire within 1 min

    private weak var governor: ThermalGovernor?
    private var lastFiredAt: Date?
    private var lastObservedActive: Bool = false

    init(governor: ThermalGovernor) {
        self.governor = governor
    }

    /// User toggled the pref on. Triggers the macOS notification permission
    /// prompt the first time; subsequent calls are silently allowed/denied
    /// based on the cached choice.
    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { granted, error in
            if let error {
                Self.logger.error("authorization request failed: \(error.localizedDescription, privacy: .public)")
            } else {
                Self.logger.notice("authorization granted=\(granted)")
            }
        }
    }

    /// Drive a single observation tick. Call after each governor evaluation.
    /// Cheap when the pref is off — bails before any work.
    func evaluate() {
        guard UserDefaults.standard.bool(forKey: Self.prefKey) else {
            // pref off → forget edge state so we re-fire cleanly when re-enabled
            lastObservedActive = false
            return
        }
        guard let g = governor else { return }
        let active = g.isTempThrottling || g.isCPUThrottling
        defer { lastObservedActive = active }

        // Rising edge only.
        guard active && !lastObservedActive else { return }

        // Cooldown: avoid spamming if the governor flaps.
        if let last = lastFiredAt, Date().timeIntervalSince(last) < Self.cooldown {
            return
        }
        lastFiredAt = Date()
        post(reason: g.reason)
    }

    private func post(reason: String) {
        let content = UNMutableNotificationContent()
        content.title = "Air Assist is throttling"
        content.body = reason.isEmpty
            ? "A cap was just breached — slow processes are being paused to cool down."
            : reason
        content.sound = nil

        let req = UNNotificationRequest(
            identifier: "governor.engaged.\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req) { err in
            if let err {
                Self.logger.error("post failed: \(err.localizedDescription, privacy: .public)")
            }
        }
    }
}
