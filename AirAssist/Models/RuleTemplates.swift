import Foundation

/// Curated starter rules. Solves the blank-canvas problem (#57) — the
/// first time a user opens Throttling preferences they should be able
/// to pick obviously-correct defaults in one click rather than
/// enumerating every Chrome helper by hand.
///
/// **Curation policy.** Each template must be:
///   • A well-known resource hog (reputation, not speculation)
///   • Targetable by a stable bundle ID (survives version bumps)
///   • Safe to throttle — i.e. the app won't silently corrupt data or
///     drop messages when paused. Anything communication-critical
///     (VPNs, backup agents, password managers) is intentionally absent.
///
/// Duties are conservative. 60% keeps the app responsive enough that
/// a casual user won't blame AirAssist for "making Slack feel weird",
/// while still shaving real heat on a sustained-load day. Users who
/// want aggressive can just drag the slider after enabling.
///
/// Adding a template: add an entry here, don't ship a runtime default
/// list that auto-enables. Users enable individually — unexpected
/// throttling of an app the user didn't touch is the worst-review
/// material imaginable.
enum RuleTemplates {

    struct Template: Identifiable, Hashable {
        /// Stable UUID per template so preferences can track "user
        /// previously enabled this" across app launches without relying
        /// on the display name.
        let id: String
        let displayName: String
        /// Bundle identifier we'll match on. Preferred over executable
        /// name because bundle IDs are stable across Helper versions.
        let bundleID: String
        /// Default duty when enabled, in the `[minDuty, maxDuty]` range.
        let duty: Double
        /// One-line explanation of why this app is on the list.
        let rationale: String
    }

    /// The starter library. Alphabetical within each category; category
    /// comments explain why that app class is worth targeting.
    static let all: [Template] = [
        // --- Chat / collaboration (chronic Electron CPU use)
        Template(
            id: "tmpl.slack",
            displayName: "Slack",
            bundleID: "com.tinyspeck.slackmacgap",
            duty: 0.60,
            rationale: "Electron-based; high idle CPU, especially with many channels open."
        ),
        Template(
            id: "tmpl.discord",
            displayName: "Discord",
            bundleID: "com.hnc.Discord",
            duty: 0.60,
            rationale: "Electron-based; persistent background audio/video stack."
        ),
        Template(
            id: "tmpl.teams",
            displayName: "Microsoft Teams",
            bundleID: "com.microsoft.teams2",
            duty: 0.55,
            rationale: "Well-known for sustained background CPU on idle."
        ),

        // --- Browsers / Helpers (cap renderers, not the main frame)
        Template(
            id: "tmpl.chrome.helpers",
            displayName: "Chrome Helper (Renderer)",
            bundleID: "com.google.Chrome.helper.Renderer",
            duty: 0.70,
            rationale: "Per-tab renderer processes; background tabs can pin a core."
        ),
        Template(
            id: "tmpl.chrome.gpu",
            displayName: "Chrome Helper (GPU)",
            bundleID: "com.google.Chrome.helper.GPU",
            duty: 0.70,
            rationale: "GPU helper burning cycles on poorly-behaved pages."
        ),
        Template(
            id: "tmpl.edge.helpers",
            displayName: "Microsoft Edge Helper (Renderer)",
            bundleID: "com.microsoft.edgemac.Helper.Renderer",
            duty: 0.70,
            rationale: "Same pattern as Chrome; separate because bundle IDs differ."
        ),

        // --- Dev / virtualization (explicit: user likely knows what they're doing)
        Template(
            id: "tmpl.docker",
            displayName: "Docker Desktop",
            bundleID: "com.docker.docker",
            duty: 0.50,
            rationale: "Hyperkit VM eats battery even when no containers are running."
        ),

        // --- Video conferencing
        Template(
            id: "tmpl.zoom",
            displayName: "Zoom",
            bundleID: "us.zoom.xos",
            duty: 0.65,
            rationale: "Idle Zoom client consumes meaningful CPU between meetings."
        ),

        // --- System indexing (we don't throttle Spotlight itself but common culprits)
        Template(
            id: "tmpl.dropbox",
            displayName: "Dropbox",
            bundleID: "com.getdropbox.dropbox",
            duty: 0.65,
            rationale: "Sync + indexing loops on large shared folders."
        ),
        Template(
            id: "tmpl.onedrive",
            displayName: "OneDrive",
            bundleID: "com.microsoft.OneDrive",
            duty: 0.65,
            rationale: "Similar sync+indexing profile to Dropbox."
        ),
    ]

    /// Convert a template into a fresh `ThrottleRule`. Not auto-enabled;
    /// the UI decides whether to insert enabled or disabled.
    static func makeRule(from t: Template, enabled: Bool = true) -> ThrottleRule {
        ThrottleRule(
            id: ThrottleRule.bundleKey(t.bundleID),
            displayName: t.displayName,
            duty: t.duty,
            isEnabled: enabled,
            schedule: nil
        )
    }
}
