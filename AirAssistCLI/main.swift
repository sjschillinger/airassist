import Foundation

// `airassist` — command-line bridge to the running Air Assist menu bar app.
//
// Why a separate binary, when Shortcuts.app + the AppIntents already
// cover automation? Three reasons:
//
//   1. Terminal users want `airassist pause` not a GUI workflow.
//   2. Scripts (Hammerspoon, fish/zsh hooks, Makefiles, CI runners
//      on a developer laptop) need a stable executable path, not a
//      shortcut name that can be renamed.
//   3. `--help` / discoverability — Shortcuts is a black box; a CLI
//      with `--help` is greppable, scriptable, and self-documenting.
//
// Implementation: the CLI is a thin wrapper. Every write action
// dispatches to the running app via the `airassist://` URL scheme
// (the same surface AppIntents use), executed through `/usr/bin/open`
// so the OS handles "is the app running? launch it if not." Read
// actions (`status`) hit UserDefaults via CFPreferences APIs against
// the `com.sjschillinger.airassist` bundle, which works whether the
// app is currently running or not — persisted state only.
//
// Live runtime state (active throttles, paused-until timestamp, the
// instantaneous governor decision) is *not* persisted, so the CLI
// can't show it without IPC. We deliberately don't add IPC for that:
// the dashboard window is the right surface, and `airassist
// open-dashboard` (TODO) is a saner UX than a CLI table.
//
// Single file, no external deps. Intentionally low-magic.

// MARK: - Constants

let bundleID = "com.sjschillinger.airassist"
let scheme   = "airassist"
let version  = "0.12.0-dev"

// MARK: - Entry

let argv = CommandLine.arguments
guard argv.count >= 2 else {
    printUsage()
    exit(64)  // EX_USAGE
}

let verb = argv[1].lowercased()
let rest = Array(argv.dropFirst(2))

switch verb {
case "pause":              cmdPause(rest)
case "resume":             cmdResume(rest)
case "throttle":           cmdThrottle(rest)
case "release":            cmdRelease(rest)
case "scenario":           cmdScenario(rest)
case "status":             cmdStatus(rest)
case "help", "-h", "--help":
    printUsage()
case "version", "-v", "--version":
    print("airassist \(version)")
default:
    fputs("airassist: unknown command '\(verb)'\n", stderr)
    printUsage()
    exit(64)
}

// MARK: - Commands

func cmdPause(_ args: [String]) {
    // `airassist pause [<duration>]`
    // Default: forever (until quit), matching the Shortcuts intent.
    var url = "\(scheme)://pause"
    if let dur = args.first {
        url += "?duration=\(percentEscape(dur))"
    }
    open(url)
}

func cmdResume(_ args: [String]) {
    // No flags. Reject extras so a typo doesn't get silently swallowed.
    if !args.isEmpty {
        fputs("airassist resume: unexpected arguments: \(args.joined(separator: " "))\n", stderr)
        exit(64)
    }
    open("\(scheme)://resume")
}

func cmdThrottle(_ args: [String]) {
    // `airassist throttle <bundle> [--duty N] [--duration D]`
    // Duty default: matches the URL handler's default (no duty = error,
    // we require it explicitly here too rather than picking a magic value).
    var positional: [String] = []
    var flags: [String: String] = [:]
    var i = 0
    while i < args.count {
        let a = args[i]
        if a == "--duty", i + 1 < args.count {
            flags["duty"] = args[i + 1]; i += 2
        } else if a == "--duration", i + 1 < args.count {
            flags["duration"] = args[i + 1]; i += 2
        } else if a.hasPrefix("--duty=") {
            flags["duty"] = String(a.dropFirst(7)); i += 1
        } else if a.hasPrefix("--duration=") {
            flags["duration"] = String(a.dropFirst(11)); i += 1
        } else {
            positional.append(a); i += 1
        }
    }
    guard let bundle = positional.first else {
        fputs("airassist throttle: missing <bundle> (e.g. com.apple.Safari)\n", stderr)
        exit(64)
    }
    guard let duty = flags["duty"] else {
        fputs("airassist throttle: missing --duty (e.g. --duty 30%)\n", stderr)
        exit(64)
    }
    var url = "\(scheme)://throttle?bundle=\(percentEscape(bundle))&duty=\(percentEscape(duty))"
    if let dur = flags["duration"] {
        url += "&duration=\(percentEscape(dur))"
    }
    open(url)
}

func cmdRelease(_ args: [String]) {
    guard let bundle = args.first else {
        fputs("airassist release: missing <bundle>\n", stderr)
        exit(64)
    }
    open("\(scheme)://release?bundle=\(percentEscape(bundle))")
}

func cmdScenario(_ args: [String]) {
    guard let name = args.first?.lowercased() else {
        fputs("airassist scenario: missing <name> (presenting|quiet|performance|auto)\n", stderr)
        exit(64)
    }
    open("\(scheme)://scenario?name=\(percentEscape(name))")
}

func cmdStatus(_ args: [String]) {
    // Reads only persisted state — anything live (active throttles,
    // current sensor reads) requires IPC we deliberately don't expose.
    if !args.isEmpty {
        fputs("airassist status: unexpected arguments: \(args.joined(separator: " "))\n", stderr)
        exit(64)
    }

    let scenario = readPref("scenarioPreset.last") as? String ?? "(unset)"
    let batteryAware = (readPref("batteryAware.enabled") as? Bool) ?? false
    let onboardingDone = (readPref("onboarding.hasCompleted") as? Bool) ?? false

    print("Air Assist — persisted state")
    print("  scenario.last:  \(scenario)")
    print("  batteryAware:   \(batteryAware)")
    print("  onboarding:     \(onboardingDone ? "complete" : "not complete")")

    if let data = readPref("governorConfig.v1") as? Data,
       let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        print("  governor:")
        let keys = ["mode", "maxTempC", "maxCPUPercent",
                    "tempHysteresisC", "cpuHysteresisPercent",
                    "maxTargets", "minCPUForTargeting",
                    "onBatteryOnly", "respectOSThermalState"]
        for k in keys {
            if let v = obj[k] {
                print("    \(k): \(v)")
            }
        }
    } else {
        print("  governor:       (defaults — never customized)")
    }

    print("")
    print("Note: live throttle state and sensor readings are not")
    print("persisted; open the dashboard to view them.")
}

// MARK: - Helpers

func open(_ url: String) {
    // Use `/usr/bin/open` rather than NSWorkspace so we don't link
    // AppKit into a 30-line CLI. `open` correctly resolves the
    // `airassist://` scheme to the registered bundle and launches it
    // if needed. We don't add `-g` (background) — the user is firing
    // an action that may show transient UI feedback (toast, popover),
    // and the menu bar app won't steal focus from a normal app anyway
    // because it's LSUIElement.
    let task = Process()
    task.launchPath = "/usr/bin/open"
    task.arguments = [url]
    do {
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            fputs("airassist: `open \(url)` exited with status \(task.terminationStatus)\n", stderr)
            exit(Int32(task.terminationStatus))
        }
    } catch {
        fputs("airassist: failed to launch `open`: \(error)\n", stderr)
        exit(70)  // EX_SOFTWARE
    }
}

func percentEscape(_ s: String) -> String {
    // urlQueryAllowed keeps `&` and `=` legal, which would corrupt our
    // own query string — strip them out of that set explicitly.
    var allowed = CharacterSet.urlQueryAllowed
    allowed.remove(charactersIn: "&=?#")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
}

func readPref(_ key: String) -> Any? {
    // CFPreferencesCopyAppValue reads from the *target* bundle's
    // domain rather than the CLI's own (which would be empty). This
    // is the same path `defaults read com.sjschillinger.airassist`
    // takes. Falls back to UserDefaults' shared suite for the very
    // unlikely case that the binaries somehow share a domain.
    if let v = CFPreferencesCopyAppValue(key as CFString, bundleID as CFString) {
        return v as Any
    }
    return UserDefaults(suiteName: bundleID)?.object(forKey: key)
}

func printUsage() {
    let usage = """
    airassist \(version) — control the Air Assist menu bar app.

    USAGE:
      airassist <command> [args]

    COMMANDS:
      pause [<duration>]                    Pause governor + active throttles.
                                            Duration: 30s | 15m | 1h | forever (default).
      resume                                Undo pause.
      throttle <bundle> --duty <N> [--duration <D>]
                                            Throttle a bundle ID's processes.
                                            Duty: 0.5 or 50% (5%–100%).
                                            Default duration: 1h.
      release <bundle>                      Release CLI-issued throttle on a bundle.
      scenario <name>                       Apply preset: presenting | quiet
                                            | performance | auto.
      status                                Print persisted preferences.
      version                                Print version.
      help                                  Print this message.

    EXAMPLES:
      airassist pause 15m
      airassist throttle com.apple.Safari --duty 30% --duration 1h
      airassist scenario presenting
      airassist status

    Actions are dispatched to the running app via airassist:// URLs.
    The app launches automatically if not already running.
    """
    print(usage)
}
