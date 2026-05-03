import Foundation
import ServiceManagement
import os

/// Registers the bundled `airassist-rescue` LaunchAgent with the system
/// so it runs once per user login. Paired with `AirAssistRescue/main.swift`
/// and `AirAssist/Resources/LaunchAgents/com.sjschillinger.airassist.rescue.plist`.
///
/// **Why this exists:** AirAssist's in-app `SafetyCoordinator.recoverOnLaunch`
/// only runs when *AirAssist itself* is launched. If the app crashes with
/// pids SIGSTOP'd and the user doesn't notice for a week, those pids stay
/// frozen for a week. The LaunchAgent fires on every login regardless of
/// whether the user opens AirAssist, so the worst-case recovery latency
/// drops from "until next manual launch" to "until next login."
///
/// The agent is idempotent: if there's no inflight file (clean previous
/// session), it exits silently. No wasted cycles, no Console.app spam.
///
/// Registration uses `SMAppService.agent(plistName:)` (macOS 13+), which
/// presents as a normal Login Items & Extensions entry the user can
/// disable if they want to. Registration is automatic on first launch and
/// idempotent across subsequent launches.
@MainActor
enum RescueAgentRegistrar {
    private static let plistName = "com.sjschillinger.airassist.rescue.plist"
    private static let logger = Logger(subsystem: "com.sjschillinger.airassist",
                                       category: "RescueAgent")

    /// Attempt to register the rescue LaunchAgent. Safe to call on every
    /// launch — `SMAppService.register()` is idempotent when the service
    /// is already in the user's approved state.
    ///
    /// Silent failure is acceptable here: worst case is the LaunchAgent
    /// doesn't run and we fall back to in-app `recoverOnLaunch`. This
    /// path is defense-in-depth, not critical-path.
    static func registerIfNeeded() {
        let service = SMAppService.agent(plistName: plistName)
        switch service.status {
        case .enabled:
            logger.debug("rescue agent already enabled")
            return
        case .requiresApproval:
            logger.info("rescue agent awaiting user approval in System Settings")
            return
        case .notFound:
            // The plist isn't bundled where SMAppService expects it — this
            // is a build configuration bug, not a user problem. Don't
            // attempt to register; log loudly so it surfaces in TestFlight
            // / beta builds before it hits end users.
            logger.error("rescue agent plist '\(plistName, privacy: .public)' not found in Contents/Library/LaunchAgents")
            return
        case .notRegistered:
            break
        @unknown default:
            logger.warning("rescue agent status unknown (\(service.status.rawValue))")
        }

        do {
            try service.register()
            logger.info("rescue agent registered (will run once per login)")
        } catch {
            // Common non-fatal failures: app running from a path that
            // can't host a login item (DerivedData during `xcodebuild`),
            // user in Managed Apple ID context with login items locked.
            // In both cases the in-app recoverOnLaunch still works; this
            // is defense-in-depth, not a hard requirement.
            logger.warning("rescue agent register failed: \(String(describing: error), privacy: .public)")
        }
    }
}
