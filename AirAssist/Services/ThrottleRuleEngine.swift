import Foundation

/// Applies user-defined per-app `ThrottleRule`s each tick. For every running
/// process that matches an enabled rule, we push the rule's duty into the
/// `ProcessThrottler`. PIDs no longer matching any rule are released.
///
/// This is distinct from `ThermalGovernor`: rules are user-defined static
/// per-app caps ("always throttle Electron app X to 50%"), whereas the
/// governor reacts to live system signals. They share the same
/// `ProcessThrottler` but track their own target sets independently.
@MainActor
final class ThrottleRuleEngine {

    private let inspector: ProcessInspector
    private let throttler: ProcessThrottler

    /// Currently loaded user rules.
    var config: ThrottleRulesConfig

    /// PIDs the rule engine is currently managing.
    private var managedPIDs: Set<pid_t> = []

    /// Externally-set pause. When true the engine releases everything
    /// and skips its tick.
    var isPaused: Bool = false {
        didSet { if isPaused { releaseAll() } }
    }

    private var tickTask: Task<Void, Never>?

    init(inspector: ProcessInspector,
         throttler: ProcessThrottler,
         config: ThrottleRulesConfig) {
        self.inspector = inspector
        self.throttler = throttler
        self.config    = config
    }

    func start() {
        guard tickTask == nil else { return }
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { break }
                self.tick()
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
        releaseAll()
    }

    func updateConfig(_ newConfig: ThrottleRulesConfig) {
        self.config = newConfig
        if !newConfig.enabled { releaseAll() }
    }

    /// List all currently running processes with bundle info, for the UI's
    /// "Add rule for this app" flow. Filters obvious noise.
    func availableProcesses() -> [RunningProcess] {
        inspector.snapshot()
            .filter { $0.isCurrentUser }
            .filter { !ProcessInspector.excludedNames.contains($0.name) }
    }

    func tick() {
        if isPaused { return }
        guard config.enabled else {
            releaseAll()
            return
        }

        let procs = inspector.snapshot()
            .filter { $0.isCurrentUser }
            .filter { !ProcessInspector.excludedNames.contains($0.name) }

        var wanted: [pid_t: (duty: Double, name: String)] = [:]
        for p in procs {
            if let rule = config.rule(for: p) {
                wanted[p.id] = (rule.duty, p.name)
            }
        }

        // Release pids that no longer match a rule.
        for pid in managedPIDs where wanted[pid] == nil {
            throttler.release(pid: pid)
        }
        managedPIDs = Set(wanted.keys)

        for (pid, spec) in wanted {
            throttler.setDuty(spec.duty, for: pid, name: spec.name)
        }
    }

    private func releaseAll() {
        for pid in managedPIDs {
            throttler.release(pid: pid)
        }
        managedPIDs.removeAll()
    }
}
