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

    // MARK: - Popover sparkline (#45)
    /// Ring buffer of the hottest enabled-sensor reading, one sample per
    /// control-loop tick (~1 Hz). Capped at `sparklineCapacity` (60 ≈ 1 min).
    /// Kept in-memory only — the on-disk `HistoryLogger` is the source of
    /// truth for the Dashboard's longer charts; this is just a cheap live
    /// strip for the menu bar popover.
    private(set) var sparklineSamples: [Double] = []
    static let sparklineCapacity: Int = 60

    private func appendSparklineSample() {
        if let t = enabledSensors.compactMap(\.currentValue).max() {
            sparklineSamples.append(t)
            if sparklineSamples.count > Self.sparklineCapacity {
                sparklineSamples.removeFirst(sparklineSamples.count - Self.sparklineCapacity)
            }
        }
    }

    // MARK: - CPU total history (#metric-arch v0.14)
    /// Rolling buffer of total system CPU% — the value the menu bar's
    /// `cpuTotal` metric shows. Captured at the same 1Hz cadence as
    /// the sparkline so the trend arrow has enough samples to compute
    /// a slope without extra polling. Capped at the same capacity.
    private(set) var cpuTotalHistory: [Double] = []

    private func appendCPUTotalSample() {
        let v = governor.lastTotalCPUPercent
        cpuTotalHistory.append(v)
        if cpuTotalHistory.count > Self.sparklineCapacity {
            cpuTotalHistory.removeFirst(cpuTotalHistory.count - Self.sparklineCapacity)
        }
    }

    /// User-facing API: change the stay-awake mode. Persists the choice
    /// so the selection survives a quit.
    func setStayAwakeMode(_ mode: StayAwakeService.Mode) {
        stayAwake.setMode(mode)
        StayAwakePersistence.save(mode)
    }

    /// Apply a one-click scenario preset. Bundles a governor config, a
    /// stay-awake mode, and the on-battery-only flag so the user can
    /// switch context (Presenting / Lap / Cool / Performance / Auto) without
    /// reaching into Preferences. Per-app rules are intentionally
    /// untouched — they represent persistent user intent.
    func applyScenario(_ scenario: ScenarioPreset) {
        var c = governorConfig
        switch scenario {
        case .presenting:
            c.mode = .off
            c.onBatteryOnly = false
            governorConfig = c
            setStayAwakeMode(.display)
        case .quiet:
            // "Lap / Cool" — keep the chassis comfortable on the skin
            // without throttling so early that normal use feels sluggish.
            //
            // Why these specific numbers:
            //   - Apple Silicon Air chassis temperature tracks the SoC.
            //     Below ~80°C SoC the palm rest stays in the ~32-35°C
            //     range (lap-comfortable). Above ~85°C it climbs into
            //     "noticeably warm." We aim for 78°C with 4°C
            //     hysteresis, so the actual hold band is 74-78°C —
            //     the comfortable zone, with 7-10°C of margin below
            //     macOS's own thermal management.
            //   - Mode is `.temperature` only (NOT `.both`). The CPU
            //     cap is the wrong instrument here: a parallel build
            //     using all 8 cores at moderate temperature shouldn't
            //     be paused. Heat is what makes a fanless Air
            //     uncomfortable; CPU% is just a proxy that misfires
            //     during well-cooled bursts.
            //   - maxCPUPercent stays in the config but is dormant
            //     while mode = .temperature; we set a generous 600%
            //     anyway so flipping the mode later doesn't surprise
            //     the user with a too-tight cap.
            c.mode                 = .temperature
            c.maxTempC             = 78
            c.tempHysteresisC      = 4
            c.maxCPUPercent        = 600
            c.cpuHysteresisPercent = 50
            c.maxTargets           = 5
            c.minCPUForTargeting   = 15
            c.onBatteryOnly        = false
            governorConfig = c
        case .performance:
            // Distinct from Presenting: governor stays *armed* with the
            // gentle preset — only intervenes at extreme temps, so a
            // long render or compile isn't gratuitously paused but the
            // Mac still has a safety net before it cooks itself.
            c = GovernorPreset.gentle.applied(to: c)
            c.mode = .both
            c.onBatteryOnly = false
            governorConfig = c
            setStayAwakeMode(.display)
        case .auto:
            c = GovernorPreset.balanced.applied(to: c)
            c.mode = .both
            c.onBatteryOnly = true
            governorConfig = c
            setStayAwakeMode(.off)
        }
        UserDefaults.standard.set(scenario.rawValue, forKey: "scenarioPreset.last")
    }

    // MARK: - CPU / Governor subsystem
    let processInspector = ProcessInspector()
    let processThrottler = ProcessThrottler()
    let throttleActivityLog = ThrottleActivityLog()
    /// Persistent NDJSON log of throttle events — the data source for the
    /// dashboard's "This week" panel. Distinct from `throttleActivityLog`,
    /// which is the in-memory ring buffer for the live "Recent activity".
    let throttleEventLog = ThrottleEventLog()
    /// Persistent NDJSON log of per-process CPU samples. Drives the
    /// dashboard's "habitual CPU consumers" panel. Sampled at the
    /// cadence below by `cpuActivityTask`; pruned on launch to a
    /// 7-day rolling window. Distinct from `throttleEventLog` —
    /// throttle log captures decisions; this captures observation.
    let cpuActivityLog = CPUActivityLog()
    /// Sampling cadence for `cpuActivityLog`. 60s is sparse enough
    /// to keep the on-disk file modest (≈50K lines / week worst
    /// case) while still giving the aggregator enough resolution
    /// for "actively running for hours" type queries.
    static let cpuActivitySampleIntervalSeconds: Double = 60
    /// Lower bound for sampling — processes below this don't get
    /// written. Lower than the aggregator's default activity
    /// threshold (10%) on purpose: the log keeps borderline cases
    /// so the dashboard can choose a stricter cutoff later without
    /// us having to rewrite history.
    static let cpuActivitySampleMinPercent: Double = 5
    /// How many top CPU processes per tick to write. Captures
    /// enough data for multi-helper apps (Chrome, Slack, Electron
    /// in general) to roll up correctly without bloating the log.
    static let cpuActivitySampleTopN: Int = 10
    private var cpuActivityTask: Task<Void, Never>?
    let safety = SafetyCoordinator()
    private var frontmostObserver: FrontmostAppObserver!
    let snapshots: ProcessSnapshotPublisher
    private(set) var governor: ThermalGovernor!
    private(set) var governorNotifier: GovernorNotifier?
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
        self.processThrottler.activityLog = throttleActivityLog
        self.processThrottler.eventLog = throttleEventLog
        // Trim ancient entries on launch — cheap (file is small) and keeps
        // the on-disk log bounded across months of use.
        throttleEventLog.pruneOldEntries()
        // CPU activity log gets a tighter retention since it's
        // dashboard-only: 7 days matches the panel's window. If we
        // ever add a longer view we can dial this back.
        cpuActivityLog.pruneOldEntries(keepDays: 7)
        self.snapshots = ProcessSnapshotPublisher(inspector: processInspector)
        // Wire the manual-throttle coordinator. It needs the
        // throttler (to apply / clear caps) and a way to read the
        // current snapshot (for the bundle-keyed APIs that target
        // every matching PID). Closed over the snapshot publisher
        // rather than holding a reference so the coordinator stays
        // ignorant of snapshot lifecycle.
        let publisher = self.snapshots
        self.manualThrottle = ManualThrottleCoordinator(
            throttler: processThrottler,
            snapshotProvider: { publisher.latest }
        )
        // Capture self weakly in the hottest-temp closure.
        self.governor = ThermalGovernor(
            snapshots: snapshots,
            throttler: processThrottler,
            config: governorConfig,
            hottestTempC: { [weak self] in
                self?.enabledSensors.compactMap(\.currentValue).max()
            },
            isOnBattery: { BatteryAwareMode.isOnBatteryPower() }
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
        self.governorNotifier = GovernorNotifier(governor: governor)
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
        // Wire up Stay Awake's own screen-sleep listener so the
        // `releaseOnScreenSleep` preference can drop / re-take the
        // assertion around lid close or screen lock. No-op if the
        // preference is off.
        stayAwake.startObservingScreenSleep()
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
                self.governorNotifier?.evaluate()
                self.appendSparklineSample()
                self.appendCPUTotalSample()
            }
        }
        // CPU activity sampler. Reads the governor's already-1Hz
        // process snapshot at a coarser cadence and writes the top-N
        // qualifying processes to the persistent activity log. Lives
        // in its own Task so the sampling cadence (60s) is decoupled
        // from the control loop's 1Hz cadence — and so cancelling
        // sampling on quit doesn't have to coordinate with the
        // control loop's lifecycle.
        cpuActivityTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.cpuActivitySampleIntervalSeconds))
                guard let self else { break }
                self.recordCPUActivitySample()
            }
        }
    }

    /// Take one CPU activity sample. Reads the governor's most
    /// recent process snapshot and writes the top-N qualifying
    /// processes to the activity log. Called from
    /// `cpuActivityTask` at the configured cadence.
    private func recordCPUActivitySample() {
        let now = Date()
        let candidates = governor.lastTopProcesses
            .filter { $0.cpuPercent >= Self.cpuActivitySampleMinPercent }
            .sorted { $0.cpuPercent > $1.cpuPercent }
            .prefix(Self.cpuActivitySampleTopN)
        let samples = candidates.map { p in
            CPUActivitySample(
                timestamp: now,
                bundleID: p.bundleID,
                name: p.name,
                displayName: p.displayName,
                cpuPercent: p.cpuPercent
            )
        }
        guard !samples.isEmpty else { return }
        cpuActivityLog.recordBatch(samples)
    }

    func stop() {
        logTask?.cancel()
        logTask = nil
        controlLoopTask?.cancel()
        controlLoopTask = nil
        cpuActivityTask?.cancel()
        cpuActivityTask = nil
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
        manualThrottle.shutdownAll()
    }

    /// Resolves a temperature from the two-part slot encoding stored in UserDefaults.
    /// - category: "none" | "highest" | "average" | "individual"
    /// - value:    "overall" | "all" | SensorCategory.rawValue | sensor.id
    ///
    /// Category-specific lookups fall back to hottest/average across all
    /// enabled sensors when the requested category is empty. This matters
    /// on hardware where `SensorCategorizer`'s heuristics didn't match any
    /// names (future SoC rev, MacBook Neo) and every sensor landed in
    /// `.other` — users with "Highest · CPU" as their default slot would
    /// otherwise see a blank menu bar. The fallback keeps the slot useful
    /// without silently lying: the highest-overall reading is still a
    /// meaningful number, just not category-filtered.
    /// Top-level slot resolver — branches on `metric` and routes to
    /// the appropriate underlying source (existing temperature path,
    /// new CPU total path, etc.). Use this instead of `resolveSlot`
    /// from new call sites; `resolveSlot` is kept as the temperature-
    /// only path so existing tests / call sites don't need to know
    /// about the metric concept.
    ///
    /// Implementation lives in `MenuBarSlotResolver` (Models/) — the
    /// store just hands over the live data the resolver needs and
    /// gets back a fully-baked state. `resolveSlot(category:value:)`
    /// below is the same path with `metric` defaulted to `.temperature`
    /// for back-compat with pre-v0.14 callers.
    func resolveSlotMetric(_ metric: SlotMetric,
                           category: String,
                           value: String) -> MenuBarSlotState {
        MenuBarSlotResolver.resolve(
            metric: metric,
            category: category,
            value: value,
            sensors: enabledSensors,
            thresholds: thresholds,
            cpuTotalPercent: governor.lastTotalCPUPercent,
            cpuTotalHistory: cpuTotalHistory
        )
    }

    /// Temperature-only resolver — pre-v0.14 entry point preserved
    /// for the few call sites that haven't migrated yet (mostly tests
    /// and the renderer's internal default).
    func resolveSlot(category: String, value: String) -> MenuBarSlotState {
        resolveSlotMetric(.temperature, category: category, value: value)
    }

    /// External callers (currently HistoryLogger) use this to log per-
    /// category peaks. Logic stays here rather than moving to the
    /// resolver because it doesn't relate to slot resolution.
    func highestTemp(in category: SensorCategory) -> Double? {
        enabledSensors
            .filter { $0.category == category }
            .compactMap(\.currentValue)
            .max()
    }

    // MARK: - Manual throttle (menu-bar escape hatch)
    //
    // The actual coordination lives in `ManualThrottleCoordinator`
    // (Services/). The methods on `ThermalStore` are thin pass-throughs
    // so existing call sites in the UI / URL scheme / Shortcuts layer
    // didn't need to change when this was extracted in the post-v0.14
    // refactor. New callers should read `manualThrottle` directly.

    /// Snapshot of the frontmost app captured by `MenuBarController`
    /// just before it opens the popover. Stored on the store rather
    /// than on the coordinator because it's a stash, not a piece of
    /// throttle coordination state — written by the controller, read
    /// by the popover's "Throttle [frontmost]" button.
    var capturedFrontmost: FrontmostSnapshot?

    /// The actual coordinator. Owned by the store so it can wire it
    /// up with the throttler and snapshot publisher in `init`.
    private(set) var manualThrottle: ManualThrottleCoordinator!

    /// Wall-clock deadlines for active manual throttles. Forwarded
    /// from the coordinator for back-compat with UI that read this
    /// directly off the store. New code should use
    /// `manualThrottle.manualExpiryDeadlines`.
    var manualExpiryDeadlines: [String: Date] {
        manualThrottle.manualExpiryDeadlines
    }

    /// Returns the wall-clock deadline (if any) for a manual throttle
    /// on this PID. UI uses this for the countdown badge.
    func manualThrottleDeadline(pid: pid_t) -> Date? {
        manualThrottle.manualThrottleDeadline(pid: pid)
    }

    /// Release a manual throttle on this PID and cancel its pending
    /// auto-release task.
    func releaseManualThrottle(pid: pid_t) {
        manualThrottle.releaseManualThrottle(pid: pid)
    }

    /// Fire-and-forget cap on a specific PID via the `.manual`
    /// source. See `ManualThrottleCoordinator.throttleFrontmost(...)`
    /// for the full contract.
    func throttleFrontmost(pid: pid_t,
                           name: String,
                           duty: Double,
                           duration: TimeInterval = 60 * 60) {
        manualThrottle.throttleFrontmost(pid: pid, name: name,
                                         duty: duty, duration: duration)
    }

    /// URL-scheme / Shortcuts entry point: throttle every PID
    /// currently matching `bundleID`. Returns the number of PIDs
    /// affected.
    @discardableResult
    func throttleBundle(bundleID: String,
                        duty: Double,
                        duration: TimeInterval = 60 * 60) -> Int {
        manualThrottle.throttleBundle(bundleID: bundleID,
                                      duty: duty, duration: duration)
    }

    /// Release any manual throttles on processes matching `bundleID`.
    /// Returns the number of PIDs released.
    @discardableResult
    func releaseBundle(bundleID: String) -> Int {
        manualThrottle.releaseBundle(bundleID: bundleID)
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
