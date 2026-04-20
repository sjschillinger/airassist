import AppKit
import os

/// Watches for system sleep / wake transitions and keeps the throttling
/// subsystem honest across them.
///
/// Policy (decided 2026-04-18, see `docs/engineering-references.md` §3):
///
/// * **willSleep:** release every SIGSTOP'd PID immediately. Two reasons:
///     1. A process that's SIGSTOP'd at the instant the kernel suspends
///        will remain SIGSTOP'd on wake with no cycler running to resume it
///        (our cycler task is itself suspended during sleep, and wakes back
///        up mid-iteration — it may SIGCONT on the next loop, but the
///        timing is not guaranteed, and a stuck-stopped process is the
///        worst class of bug we can ship).
///     2. System-wide "pause for the duration of sleep" matches user
///        intuition — no one wants to wake up to a frozen Chrome.
///   The governor and rule engine are toggled into their paused state so
///   they don't re-apply stale duties between willSleep and actual sleep.
///
/// * **didWake:** un-pause the engines. They re-converge on the correct
///   duties on their next tick (within ~1s) based on fresh snapshots.
///
/// ### Power Nap caveat
///
/// `didWakeNotification` also fires for Power Nap wakes (macOS waking
/// briefly for background maintenance). The machine may re-sleep shortly
/// after. That's fine here: we just un-pause and let the next willSleep
/// pause us again. No expensive re-initialization.
///
/// ### Forced-sleep gotcha
///
/// A power-button / low-battery-emergency sleep can skip `willSleep`
/// entirely. The recovery path for that case is the
/// `SafetyCoordinator.recoverOnLaunch` dead-man's-switch file: on next
/// launch, any PID we left SIGSTOP'd gets SIGCONT'd before the app
/// initializes its engines.
///
/// Notifications are posted on **`NSWorkspace.shared.notificationCenter`**,
/// NOT `NotificationCenter.default`. Observers registered on the default
/// center never fire.
@MainActor
final class SleepWakeObserver {
    private let logger = Logger(subsystem: "com.sjschillinger.airassist",
                                category: "SleepWake")
    private let onWillSleep: () -> Void
    private let onDidWake:   () -> Void
    private var tokens: [NSObjectProtocol] = []

    init(onWillSleep: @escaping () -> Void,
         onDidWake:   @escaping () -> Void) {
        self.onWillSleep = onWillSleep
        self.onDidWake   = onDidWake
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        let willSleep = center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.logger.info("willSleep — releasing throttled PIDs")
                self.onWillSleep()
            }
        }
        let didWake = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.logger.info("didWake — resuming engines")
                self.onDidWake()
            }
        }

        // Screen sleep = lid close with an external display attached
        // (clamshell mode). On that path the system itself does NOT sleep,
        // so `willSleepNotification` never fires — but the user's
        // expectations still match sleep: no surprises, no frozen
        // background processes. We treat it the same as system sleep:
        // release all throttled pids, pause engines. `screensDidWake` is
        // the inverse.
        //
        // The display can also sleep under other conditions (idle timer,
        // Hot Corners, manual screen lock). Treating those as full-sleep
        // is a tiny bit over-aggressive (a screen lock on battery keeps
        // the machine running), but the failure mode is "throttle
        // resumes 2s later than it could have" — strictly safer than
        // "user's Chrome is frozen on the lock screen."
        let screensSleep = center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.logger.info("screensDidSleep — releasing throttled PIDs (clamshell / lock)")
                self.onWillSleep()
            }
        }
        let screensWake = center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.logger.info("screensDidWake — resuming engines")
                self.onDidWake()
            }
        }
        tokens = [willSleep, didWake, screensSleep, screensWake]
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        for t in tokens { center.removeObserver(t) }
        tokens.removeAll()
    }

    deinit {
        // Can't touch `tokens` from deinit under strict concurrency; rely on
        // explicit `stop()` from the owner. `ThermalStore.stop()` handles this.
    }
}
