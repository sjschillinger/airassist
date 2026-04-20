import AppKit
import Foundation
import Observation
import os

/// Lightweight update notifier, backed by the GitHub Releases API.
///
/// ## Why this instead of Sparkle
///
/// `docs/releasing.md` commits Air Assist to ad-hoc signing permanently:
/// Homebrew is the canonical install path (no quarantine, no Gatekeeper
/// friction), and the direct-download path asks users to run a one-time
/// `xattr` command. Sparkle's auto-installer requires a Developer-ID
/// signature to replace the running binary cleanly — it can't honor
/// that promise on an ad-hoc build, so shipping it would be a UX lie.
///
/// Instead, we do the minimum that actually works without signing:
///
///   1. Once a day, ask GitHub's API for the `latest` release.
///   2. Compare its tag (minus the leading `v`) to our own
///      `CFBundleShortVersionString` using a plain semver comparator.
///   3. If newer: surface a menu-bar nudge that opens the release page.
///      Homebrew users can then `brew upgrade --cask airassist`; manual
///      users download the new zip and repeat the right-click / xattr
///      dance they did on first install.
///
/// No binary replacement, no signature verification, no installer
/// daemon. Just "a new version exists, here's where it lives."
///
/// ## Observables
///
/// The service is `@Observable` so AppMainMenu and the status-bar drawing
/// code can react to `latestVersion` changes without a Combine layer.
///
/// ## Privacy
///
/// The only network call this app makes in normal operation is to
/// `api.github.com`, once per day. The request carries a User-Agent
/// (`AirAssist/<version>`) as GitHub requires, and no other identifying
/// data. Users can turn the check off entirely via Preferences — the
/// `automaticUpdateChecksEnabled` toggle gates the scheduler; the
/// manual "Check for Updates…" menu item always works.
@MainActor
@Observable
final class UpdateCheckService {
    static let shared = UpdateCheckService()

    // MARK: - Tunables

    /// Repo coordinates. The endpoint and release URL derive from these.
    /// If you fork, change these — nothing else in the file cares.
    private static let owner = "sjschillinger"
    private static let repo  = "airassist"

    /// Seconds between automatic checks. GitHub's unauth rate limit is
    /// 60 req/hour/IP; one per day is comfortably under that even with
    /// the occasional manual check.
    private static let checkInterval: TimeInterval = 86_400

    /// Delay before the first automatic check after launch. Gives the
    /// app time to finish its own startup I/O before issuing a network
    /// request we don't strictly need.
    private static let launchDelay: TimeInterval = 5

    /// HTTP timeout. GitHub's API is fast when reachable and fails fast
    /// when not; we don't need a long tail.
    private static let httpTimeout: TimeInterval = 15

    // MARK: - UserDefaults keys

    private enum DefaultsKey {
        /// Bool. When false, the background scheduler never fires.
        /// Manual checks still work. Default: true.
        static let automaticChecks = "update.automaticChecksEnabled"
        /// ISO-8601 Date. Last time a check completed (success OR failure),
        /// used to decide whether the next scheduled tick is due.
        static let lastCheckedAt   = "update.lastCheckedAt"
        /// String (semver). Last known latest release tag, without the
        /// leading `v`. Persisted so the nudge survives relaunches.
        static let latestVersion   = "update.latestVersion"
    }

    // MARK: - Observable state (read by UI)

    /// Latest release tag seen on GitHub (stripped of any leading `v`).
    /// `nil` means "no known newer version" — either we haven't checked,
    /// the check failed, or the release is ≤ our own version.
    private(set) var latestVersion: String?

    /// Wall-clock time of the last completed check, for the "Last
    /// checked: 3h ago" affordance in Preferences.
    private(set) var lastCheckedAt: Date?

    /// True while a check is in flight. Lets the UI show a spinner /
    /// disable the menu item to prevent double-taps.
    private(set) var isChecking = false

    // MARK: - Settings passthroughs

    var automaticChecksEnabled: Bool {
        get { UserDefaults.standard.object(forKey: DefaultsKey.automaticChecks) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: DefaultsKey.automaticChecks)
            // Don't start/stop the scheduler on toggle — it's cheap and
            // the next tick's `guard` reads the flag fresh. Keeps the
            // state machine trivially simple.
        }
    }

    // MARK: - Internals

    private let logger = Logger(subsystem: "com.sjschillinger.airassist",
                                category: "UpdateCheck")
    private var schedulerTask: Task<Void, Never>?
    private var hasStarted = false

    private init() {
        // Rehydrate from UserDefaults so the menu can show a pending
        // nudge immediately on launch without waiting for a network call.
        let d = UserDefaults.standard
        self.latestVersion = d.string(forKey: DefaultsKey.latestVersion)
        self.lastCheckedAt = d.object(forKey: DefaultsKey.lastCheckedAt) as? Date
        // If the persisted "latest" is ≤ current version (e.g. user just
        // upgraded via brew), clear it so the stale nudge doesn't linger.
        if let persisted = latestVersion,
           Self.compare(persisted, Self.currentVersion) != .orderedDescending {
            self.latestVersion = nil
            d.removeObject(forKey: DefaultsKey.latestVersion)
        }
    }

    // MARK: - Public API

    /// Kick off the background scheduler. Safe to call once per launch;
    /// subsequent calls are no-ops.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        schedulerTask = Task { [weak self] in
            // Sleep the launch delay, then loop forever: check if the
            // toggle is on AND enough time has passed, then wait one
            // full interval. We re-check the toggle every tick so
            // turning it off takes effect on the next cycle.
            try? await Task.sleep(for: .seconds(Self.launchDelay))
            while !Task.isCancelled {
                await self?.tickIfDue()
                try? await Task.sleep(for: .seconds(Self.checkInterval))
            }
        }
    }

    /// Stop the background scheduler. Currently unused — there's no
    /// lifecycle event that warrants stopping automatic checks — but
    /// kept symmetric with `start()` for testability and future needs.
    func stop() {
        schedulerTask?.cancel()
        schedulerTask = nil
        hasStarted = false
    }

    /// Run a check right now. Returns when the request completes.
    /// Surfaces its result via `latestVersion` / `lastCheckedAt`; callers
    /// read those rather than using a return value, so a manual "Check
    /// for Updates…" flow and a scheduler tick use the exact same path.
    func checkNow() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        await performCheck()
    }

    /// Open the GitHub release page for the latest known version (or the
    /// `/releases/latest` redirect if we haven't checked yet).
    func openReleasePage() {
        let url = URL(string: "https://github.com/\(Self.owner)/\(Self.repo)/releases/latest")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Semver (exposed for tests)

    /// Three-component semver compare. Strips a single leading `v` on
    /// either side, splits on `.`, pads with zeros, ignores trailing
    /// suffixes (e.g. `0.9.0-beta.1` → `0.9.0`). Good enough for our
    /// release cadence; formal semver libraries exist but would be a
    /// disproportionate dependency for one function.
    nonisolated static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let l = components(lhs)
        let r = components(rhs)
        for i in 0..<max(l.count, r.count) {
            let a = i < l.count ? l[i] : 0
            let b = i < r.count ? r[i] : 0
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
        }
        return .orderedSame
    }

    nonisolated private static func components(_ s: String) -> [Int] {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.first == "v" || t.first == "V" { t.removeFirst() }
        // Drop pre-release / build metadata suffix: `0.9.0-beta.1+abc` → `0.9.0`.
        if let cut = t.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            t = String(t[..<cut])
        }
        return t.split(separator: ".").compactMap { Int($0) }
    }

    nonisolated static var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? "0.0.0"
    }

    // MARK: - Private

    private func tickIfDue() async {
        guard automaticChecksEnabled else { return }
        // Throttle: if the last completed check is younger than the
        // interval minus a minute of jitter, skip. Handles the case
        // where the user toggles on/off/on and we don't want to spam.
        if let last = lastCheckedAt,
           Date().timeIntervalSince(last) < (Self.checkInterval - 60) {
            return
        }
        await checkNow()
    }

    /// Shape of the single field we care about from the GitHub Releases API.
    /// Everything else in the response is ignored — Codable drops unknown
    /// keys by default. Defined here rather than in Models/ because it
    /// isn't a domain concept, it's a wire format this one service owns.
    private struct GitHubRelease: Decodable {
        let tag_name: String
        let html_url: String?
    }

    private func performCheck() async {
        let url = URL(string: "https://api.github.com/repos/\(Self.owner)/\(Self.repo)/releases/latest")!
        var req = URLRequest(url: url, timeoutInterval: Self.httpTimeout)
        req.setValue("AirAssist/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                logger.info("update check: HTTP \(code, privacy: .public)")
                recordCheckedNow()
                return
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let tag = release.tag_name

            // Newer-than-us? Only then set `latestVersion`.
            if Self.compare(tag, Self.currentVersion) == .orderedDescending {
                let normalized = Self.normalize(tag)
                self.latestVersion = normalized
                UserDefaults.standard.set(normalized, forKey: DefaultsKey.latestVersion)
                logger.info("update available: \(normalized, privacy: .public)")
            } else {
                // Same or older: clear any stale nudge (user just upgraded
                // or GitHub got confused during a rollback).
                self.latestVersion = nil
                UserDefaults.standard.removeObject(forKey: DefaultsKey.latestVersion)
            }
            recordCheckedNow()
        } catch {
            logger.info("update check failed: \(String(describing: error), privacy: .public)")
            recordCheckedNow()
        }
    }

    private func recordCheckedNow() {
        let now = Date()
        self.lastCheckedAt = now
        UserDefaults.standard.set(now, forKey: DefaultsKey.lastCheckedAt)
    }

    /// Normalize a GitHub tag for display + comparison. Strips leading
    /// `v`/`V` and trims whitespace. Does NOT strip pre-release
    /// suffixes — those are meaningful to show the user if a `-beta`
    /// release is published, we just ignore them when comparing.
    nonisolated private static func normalize(_ tag: String) -> String {
        var t = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.first == "v" || t.first == "V" { t.removeFirst() }
        return t
    }
}
