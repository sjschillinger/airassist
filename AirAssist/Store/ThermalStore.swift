import Foundation

@Observable
@MainActor
final class ThermalStore {
    let sensorService = SensorService()
    var thresholds = ThresholdPersistence.load()
    private let logger = HistoryLogger()
    private var logTask: Task<Void, Never>?

    // MARK: - Stay Awake
    let stayAwake = StayAwakeService()

    // MARK: - Sleep/wake
    private var sleepWakeObserver: SleepWakeObserver?

    // MARK: - Battery-aware auto-mode (#59)
    let batteryAware = BatteryAwareMode()

    /// User-facing API: change the stay-awake mode. Persists the choice
    /// so the selection survives a quit.
    func setStayAwakeMode(_ mode: StayAwakeService.Mode) {
        stayAwake.setMode(mode)
        StayAwakePersistence.save(mode)
    }

    // MARK: - CPU / Governor subsystem
    let processInspector = ProcessInspector()
    let processThrottler = ProcessThrottler()
    let safety = SafetyCoordinator()
    private var frontmostObserver: FrontmostAppObserver!
    let snapshots: ProcessSnapshotPublisher
    private(set) var governor: ThermalGovernor!
    private(set) var ruleEngine: ThrottleRuleEngine!
    /// Shared 1Hz driver — refreshes the snapshot publisher, then ticks both
    /// engines in deterministic order (rules first, governor second, so the
    /// governor can skip rule-covered PIDs on the same cycle).
    private var controlLoopTask: Task<Void, Never>?

    var governorConfig: GovernorConfig {
        didSet {
            GovernorConfigPersistence.save(governorConfig)
            governor?.updateConfig(governorConfig)
        }
    }
    var throttleRules: ThrottleRulesConfig {
        didSet {
            ThrottleRulesPersistence.save(throttleRules)
            ruleEngine?.updateConfig(throttleRules)
        }
    }

    /// Live view of currently throttled processes across both engines.
    var liveThrottledPIDs: [(pid: pid_t, duty: Double, name: String)] {
        processThrottler.throttledPIDs
    }

    /// If non-nil and in the future, throttling is paused until this date.
    /// Setting this applies/removes the pause on both engines immediately.
    /// A background task clears it automatically when the time elapses.
    private(set) var pausedUntil: Date?
    private var pauseExpiryTask: Task<Void, Never>?

    var isPauseActive: Bool {
        guard let p = pausedUntil else { return false }
        return p > Date()
    }

    /// Pause both throttling engines for a duration (nil = until next launch).
    func pauseThrottling(for duration: TimeInterval?) {
        pauseExpiryTask?.cancel()
        let expiry = duration.map { Date().addingTimeInterval($0) } ?? Date.distantFuture
        pausedUntil = expiry
        applyPauseState()
        if expiry != .distantFuture {
            pauseExpiryTask = Task { @MainActor [weak self] in
                let delay = max(0, expiry.timeIntervalSinceNow)
                try? await Task.sleep(for: .seconds(delay))
                guard let self else { return }
                if self.pausedUntil == expiry { self.resumeThrottling() }
            }
        }
    }

    func resumeThrottling() {
        pauseExpiryTask?.cancel()
        pauseExpiryTask = nil
        pausedUntil = nil
        applyPauseState()
    }

    private func applyPauseState() {
        let paused = isPauseActive
        governor?.isPaused   = paused
        ruleEngine?.isPaused = paused
        if paused { processThrottler.releaseAll() }
    }

    var sensors: [Sensor] { sensorService.sensors }

    var enabledSensors: [Sensor] {
        sensors.filter(\.isEnabled)
    }

    var sensorsByCategory: [(category: SensorCategory, sensors: [Sensor])] {
        let enabled = enabledSensors
        return SensorCategory.allCases.compactMap { cat in
            let group = enabled
                .filter { $0.category == cat }
                // Natural (human) sort so "CPU Die 2" comes before "CPU Die 10".
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            return group.isEmpty ? nil : (cat, group)
        }
    }

    var hottestSensor: Sensor? {
        enabledSensors
            .filter { $0.currentValue != nil }
            .max { a, b in stateRank(a) < stateRank(b) }
    }

    init() {
        self.governorConfig = GovernorConfigPersistence.load()
        self.throttleRules  = ThrottleRulesPersistence.load()
        self.processThrottler.safety = safety
        self.snapshots = ProcessSnapshotPublisher(inspector: processInspector)
        // Capture self weakly in the hottest-temp closure.
        self.governor = ThermalGovernor(
            snapshots: snapshots,
            throttler: processThrottler,
            config: governorConfig,
            hottestTempC: { [weak self] in
                self?.enabledSensors.compactMap(\.currentValue).max()
            }
        )
        self.ruleEngine = ThrottleRuleEngine(
            snapshots: snapshots,
            inspector: processInspector,
            throttler: processThrottler,
            config: throttleRules
        )
        // Governor asks the rule engine whether a PID is already rule-covered
        // so it never fights rules on the same PID.
        self.governor.isRuleCoveredPID = { [weak self] pid in
            self?.ruleEngine.managedPIDs.contains(pid) ?? false
        }
        // Foreground-app protection: the throttler uses this to clamp
        // effective duty up to `foregroundDutyFloor` for the active window.
        self.frontmostObserver = FrontmostAppObserver { [weak self] pid in
            self?.processThrottler.setForegroundPID(pid)
        }
        // Stay-awake intentionally does NOT auto-restore on launch —
        // users would be surprised if closing the lid once made every
        // future session pin the Mac awake. The persisted value is the
        // default mode the menu/prefs pre-select, nothing more.
    }

    func start() {
        safety.startWatchdog()
        frontmostObserver.start()
        // Apply the user's saved poll interval before starting the service
        // so the first poll respects the preference. UserDefaults.object(...)
        // distinguishes "never set" (→ use SensorService's 1s default) from
        // "explicitly set to some value".
        if let saved = UserDefaults.standard.object(forKey: "updateInterval") as? Double {
            sensorService.pollIntervalSeconds = saved
        }
        sensorService.start()
        // Release every throttled PID on sleep (#18). See SleepWakeObserver
        // for the full rationale — the short version is "a SIGSTOP'd process
        // at the moment of suspend can wake up still stopped."
        sleepWakeObserver = SleepWakeObserver(
            onWillSleep: { [weak self] in
                self?.processThrottler.releaseAll()
            },
            onDidWake: { [weak self] in
                // Engines re-arm naturally on their next 1Hz tick. Nothing
                // to do here beyond logging, which SleepWakeObserver does.
                _ = self
            }
        )
        sleepWakeObserver?.start()
        // Battery-aware preset swapping (#59). Opt-in; no-op if disabled.
        batteryAware.onApplyThresholds = { [weak self] settings in
            guard let self else { return }
            self.thresholds = settings
            ThresholdPersistence.save(settings)
        }
        batteryAware.start()
        logger.pruneOldEntries()
        logTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { break }
                self.logger.log(store: self)
            }
        }
        // Shared 1Hz control loop — single source of process data for both
        // engines, and a deterministic ordering (rules → governor) so the
        // governor sees up-to-date rule-coverage within the same cycle.
        controlLoopTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { break }
                self.snapshots.refresh()
                self.ruleEngine.tick()
                self.governor.tick()
            }
        }
    }

    func stop() {
        logTask?.cancel()
        logTask = nil
        controlLoopTask?.cancel()
        controlLoopTask = nil
        sleepWakeObserver?.stop()
        sleepWakeObserver = nil
        batteryAware.stop()
        frontmostObserver.stop()
        sensorService.stop()
        governor.stop()
        ruleEngine.stop()
        processThrottler.releaseAll()
        safety.stopWatchdog()
        stayAwake.shutdown()
    }

    /// Resolves a temperature from the two-part slot encoding stored in UserDefaults.
    /// - category: "none" | "highest" | "average" | "individual"
    /// - value:    "overall" | "all" | SensorCategory.rawValue | sensor.id
    func temperature(category: String, value: String) -> Double? {
        switch category {
        case "highest":
            if value == "overall" { return enabledSensors.compactMap(\.currentValue).max() }
            if let cat = SensorCategory(rawValue: value) { return highestTemp(in: cat) }
            return nil
        case "average":
            if value == "all" { return averageTemp() }
            if let cat = SensorCategory(rawValue: value) { return averageTemp(in: cat) }
            return nil
        case "individual":
            return enabledSensors.first { $0.id == value }?.currentValue
        default:
            return nil
        }
    }

    func highestTemp(in category: SensorCategory) -> Double? {
        enabledSensors
            .filter { $0.category == category }
            .compactMap(\.currentValue)
            .max()
    }

    func averageTemp(in category: SensorCategory) -> Double? {
        let vals = enabledSensors.filter { $0.category == category }.compactMap(\.currentValue)
        return vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
    }

    func averageTemp() -> Double? {
        let vals = enabledSensors.compactMap(\.currentValue)
        return vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count)
    }

    // MARK: - Manual throttle (menu-bar escape hatch)

    /// Fire-and-forget cap on a specific PID via the `.manual` source. Used
    /// by the "Throttle frontmost at X%" quick-menu action. Bypasses the
    /// foreground-duty floor because the whole point is to rein in the app
    /// the user is currently interacting with. Auto-releases after
    /// `duration` (default 1h) so the user can't accidentally leave
    /// something pegged forever. Re-invoking replaces the cap.
    func throttleFrontmost(pid: pid_t,
                           name: String,
                           duty: Double,
                           duration: TimeInterval = 60 * 60) {
        guard pid > 0, pid != getpid() else { return }
        processThrottler.setDuty(duty, for: pid, name: name, source: .manual)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            self?.processThrottler.clearDuty(source: .manual, for: pid)
        }
    }

    /// URL-scheme / Shortcuts entry point: throttle every PID currently
    /// matching `bundleID` (case-insensitive) via `.manual` duty. Like
    /// `throttleFrontmost` but identifies the target by bundle instead of
    /// PID, so it survives the app being killed and re-launched within the
    /// duration (the next matching snapshot picks it up again).
    /// Returns the number of PIDs affected.
    @discardableResult
    func throttleBundle(bundleID: String,
                        duty: Double,
                        duration: TimeInterval = 60 * 60) -> Int {
        let target = bundleID.lowercased()
        let pids = snapshots.latest.filter {
            ($0.bundleID?.lowercased() == target) && $0.id > 0 && $0.id != getpid()
        }
        for p in pids {
            processThrottler.setDuty(duty, for: p.id, name: p.name, source: .manual)
        }
        // Auto-release after the duration. Clear by bundle so we catch PIDs
        // that were spawned after the initial call too.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            self?.releaseBundle(bundleID: bundleID)
        }
        return pids.count
    }

    /// Release any manual throttles on processes matching `bundleID`.
    /// Called explicitly by URL scheme / Shortcuts, and automatically by
    /// the `throttleBundle` expiry timer.
    @discardableResult
    func releaseBundle(bundleID: String) -> Int {
        let target = bundleID.lowercased()
        let pids = snapshots.latest
            .filter { $0.bundleID?.lowercased() == target }
            .map { $0.id }
        for pid in pids {
            processThrottler.clearDuty(source: .manual, for: pid)
        }
        return pids.count
    }

    // MARK: - Rule management helpers (used by UI)

    /// Insert or replace a rule for a process. Keyed by bundleID when available.
    func upsertRule(for process: RunningProcess, duty: Double, enabled: Bool = true) {
        let key = ThrottleRule.key(for: process)
        var cfg = throttleRules
        if let idx = cfg.rules.firstIndex(where: { $0.id == key }) {
            cfg.rules[idx].duty = duty
            cfg.rules[idx].isEnabled = enabled
            cfg.rules[idx].displayName = process.displayName
        } else {
            cfg.rules.append(ThrottleRule(
                id: key,
                displayName: process.displayName,
                duty: duty,
                isEnabled: enabled
            ))
        }
        throttleRules = cfg
    }

    func removeRule(id: String) {
        var cfg = throttleRules
        cfg.rules.removeAll { $0.id == id }
        throttleRules = cfg
    }

    func setRulesEngineEnabled(_ enabled: Bool) {
        var cfg = throttleRules
        cfg.enabled = enabled
        throttleRules = cfg
    }

    private func stateRank(_ sensor: Sensor) -> Int {
        switch sensor.thresholdState(using: thresholds) {
        case .hot:     return 3
        case .warm:    return 2
        case .cool:    return 1
        case .unknown: return 0
        }
    }
}
