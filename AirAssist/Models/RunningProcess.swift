import Foundation

/// Snapshot of a running process at a moment in time.
/// Constructed by `ProcessInspector`; treated as an immutable value.
struct RunningProcess: Identifiable, Hashable {
    let id: pid_t                      // pid
    let name: String                   // executable name ("Google Chrome Helper (Renderer)")
    let bundleID: String?              // "com.google.Chrome.helper" if resolvable
    let executablePath: String?        // "/Applications/.../Chrome Helper"
    let parentPID: pid_t
    let uid: uid_t                     // owning user
    let isCurrentUser: Bool
    /// Cumulative user-space CPU time in nanoseconds at snapshot time.
    let cpuTimeNs: UInt64
    /// Running CPU percent (delta from prior snapshot / delta wall time), 0…∞.
    /// A process pegging one full core = 100%. Four cores = 400%.
    var cpuPercent: Double
    /// Resident memory bytes.
    let rssBytes: UInt64

    var displayName: String {
        // Prefer bundle display name if we can get it from the .app path.
        if let p = executablePath {
            // `/Applications/Foo.app/Contents/MacOS/Foo` → "Foo"
            if let range = p.range(of: ".app/", options: [.backwards]) {
                let before = p[..<range.lowerBound]
                if let appName = before.split(separator: "/").last {
                    return String(appName)
                }
            }
        }
        return name
    }
}
