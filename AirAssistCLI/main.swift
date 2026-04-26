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
// the dashboard window is the right surface, exposed as `airassist
// open-dashboard`. A CLI table would just rot whenever the UI changes.
//
// Single file, no external deps. Intentionally low-magic.

// MARK: - Constants

let bundleID = "com.sjschillinger.airassist"
let scheme   = "airassist"
let version  = "0.12.1"

// Completion script literals are declared up-front because top-level
// `let` in main.swift initializes in source order; if they lived
// below the dispatch `switch`, the completions verb fired through
// uninitialized empty values and printed a single newline.

let zshCompletion = #"""
#compdef airassist
# zsh completion for airassist. Install with:
#   airassist completions zsh > ~/.zsh/completions/_airassist
#   # ensure the dir is on $fpath, e.g. in ~/.zshrc:
#   #   fpath=(~/.zsh/completions $fpath)
#   #   autoload -Uz compinit && compinit
_airassist() {
  local -a verbs
  verbs=(
    'pause:Pause governor + throttles'
    'resume:Undo pause'
    'throttle:Throttle a bundle ID'
    'release:Release CLI throttle on a bundle'
    'scenario:Apply a scenario preset'
    'status:Print persisted preferences'
    'completions:Emit shell completion script'
    'open-dashboard:Open the Dashboard window'
    'open-preferences:Open the Preferences window'
    'version:Print version'
    'help:Print help'
  )
  if (( CURRENT == 2 )); then
    _describe -t verbs 'airassist verb' verbs
    return
  fi
  case ${words[2]} in
    pause)       _values 'duration' 30s 1m 5m 15m 1h 4h forever ;;
    scenario)    _values 'preset' presenting quiet performance auto ;;
    completions) _values 'shell' zsh bash fish ;;
    throttle)
      if (( CURRENT == 3 )); then
        _message 'bundle id (e.g. com.apple.Safari)'
      else
        _values 'flag' --duty --duration
      fi ;;
    release)
      if (( CURRENT == 3 )); then _message 'bundle id'; fi ;;
    status)      _values 'flag' --json ;;
  esac
}
_airassist "$@"
"""#

let bashCompletion = #"""
# bash completion for airassist. Install with:
#   airassist completions bash > ~/.local/share/bash-completion/completions/airassist
_airassist_complete() {
    local cur prev verbs
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    verbs="pause resume throttle release scenario status completions open-dashboard open-preferences version help"
    if [ "$COMP_CWORD" -eq 1 ]; then
        COMPREPLY=( $(compgen -W "$verbs" -- "$cur") )
        return
    fi
    case "${COMP_WORDS[1]}" in
      pause)       COMPREPLY=( $(compgen -W "30s 1m 5m 15m 1h 4h forever" -- "$cur") ) ;;
      scenario)    COMPREPLY=( $(compgen -W "presenting quiet performance auto" -- "$cur") ) ;;
      completions) COMPREPLY=( $(compgen -W "zsh bash fish" -- "$cur") ) ;;
      throttle)    COMPREPLY=( $(compgen -W "--duty --duration" -- "$cur") ) ;;
      status)      COMPREPLY=( $(compgen -W "--json" -- "$cur") ) ;;
    esac
}
complete -F _airassist_complete airassist
"""#

let fishCompletion = #"""
# fish completion for airassist. Install with:
#   airassist completions fish > ~/.config/fish/completions/airassist.fish
complete -c airassist -f
complete -c airassist -n '__fish_use_subcommand' -a 'pause'       -d 'Pause governor + throttles'
complete -c airassist -n '__fish_use_subcommand' -a 'resume'      -d 'Undo pause'
complete -c airassist -n '__fish_use_subcommand' -a 'throttle'    -d 'Throttle a bundle ID'
complete -c airassist -n '__fish_use_subcommand' -a 'release'     -d 'Release CLI throttle'
complete -c airassist -n '__fish_use_subcommand' -a 'scenario'    -d 'Apply scenario preset'
complete -c airassist -n '__fish_use_subcommand' -a 'status'      -d 'Print persisted preferences'
complete -c airassist -n '__fish_use_subcommand' -a 'completions' -d 'Emit shell completion script'
complete -c airassist -n '__fish_use_subcommand' -a 'open-dashboard'   -d 'Open the Dashboard window'
complete -c airassist -n '__fish_use_subcommand' -a 'open-preferences' -d 'Open the Preferences window'
complete -c airassist -n '__fish_use_subcommand' -a 'version'     -d 'Print version'
complete -c airassist -n '__fish_use_subcommand' -a 'help'        -d 'Print help'

complete -c airassist -n '__fish_seen_subcommand_from pause'       -a 'forever 30s 1m 5m 15m 1h 4h'
complete -c airassist -n '__fish_seen_subcommand_from scenario'    -a 'presenting quiet performance auto'
complete -c airassist -n '__fish_seen_subcommand_from completions' -a 'zsh bash fish'
complete -c airassist -n '__fish_seen_subcommand_from throttle' -l duty     -d 'Cap percentage (e.g. 30%)'
complete -c airassist -n '__fish_seen_subcommand_from throttle' -l duration -d 'Throttle duration (e.g. 1h)'
complete -c airassist -n '__fish_seen_subcommand_from status'   -l json     -d 'Machine-readable output'
"""#

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
case "completions":        cmdCompletions(rest)
case "open-dashboard":     cmdOpen(rest, kind: "open-dashboard")
case "open-preferences":   cmdOpen(rest, kind: "open-preferences")
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
    var jsonOutput = false
    for a in args {
        switch a {
        case "--json": jsonOutput = true
        default:
            fputs("airassist status: unknown flag '\(a)'\n", stderr)
            exit(64)
        }
    }

    let scenario       = readPref("scenarioPreset.last") as? String ?? ""
    let batteryAware   = (readPref("batteryAware.enabled") as? Bool) ?? false
    let onboardingDone = (readPref("onboarding.hasCompleted") as? Bool) ?? false

    var governor: [String: Any] = [:]
    if let data = readPref("governorConfig.v1") as? Data,
       let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        governor = obj
    }

    if jsonOutput {
        // Schema is intentionally narrow — only the persisted fields
        // we already document via `status`. Live state is omitted.
        // `appRunning` is a simple sysctl/process check so scripts
        // can branch on whether IPC is available.
        let payload: [String: Any] = [
            "appRunning":    isAirAssistRunning(),
            "appVersion":    version,
            "scenario":      scenario.isEmpty ? NSNull() : (scenario as Any),
            "batteryAware":  batteryAware,
            "onboarding":    onboardingDone,
            "governor":      governor,
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            print(s)
        }
        return
    }

    print("Air Assist — persisted state")
    print("  scenario.last:  \(scenario.isEmpty ? "(unset)" : scenario)")
    print("  batteryAware:   \(batteryAware)")
    print("  onboarding:     \(onboardingDone ? "complete" : "not complete")")
    print("  appRunning:     \(isAirAssistRunning())")

    if !governor.isEmpty {
        print("  governor:")
        let keys = ["mode", "maxTempC", "maxCPUPercent",
                    "tempHysteresisC", "cpuHysteresisPercent",
                    "maxTargets", "minCPUForTargeting",
                    "onBatteryOnly", "respectOSThermalState"]
        for k in keys {
            if let v = governor[k] {
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

func cmdOpen(_ args: [String], kind: String) {
    // `airassist open-dashboard` / `airassist open-preferences`.
    // Both verbs are zero-arg — anything else is a typo.
    if !args.isEmpty {
        fputs("airassist \(kind): unexpected arguments: \(args.joined(separator: " "))\n", stderr)
        exit(64)
    }
    open("\(scheme)://\(kind)")
}

func cmdCompletions(_ args: [String]) {
    // Print a static completion script for the requested shell.
    // Hand-rolled because pulling in swift-argument-parser for one CLI
    // is overkill — the verb set is small and mostly stable.
    guard let shell = args.first?.lowercased() else {
        fputs("airassist completions: missing shell (zsh|bash|fish)\n", stderr)
        exit(64)
    }
    switch shell {
    case "zsh":
        print(zshCompletion)
    case "bash":
        print(bashCompletion)
    case "fish":
        print(fishCompletion)
    default:
        fputs("airassist completions: unsupported shell '\(shell)' (expected zsh|bash|fish)\n", stderr)
        exit(64)
    }
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

func isAirAssistRunning() -> Bool {
    // sysctl -based process scan. Cheap and synchronous; avoids
    // pulling in AppKit's NSWorkspace (which would force the CLI to
    // link AppKit just to check whether a sibling app is up).
    var name = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
    var size: size_t = 0
    if sysctl(&name, u_int(name.count), nil, &size, nil, 0) != 0 { return false }
    let count = size / MemoryLayout<kinfo_proc>.size
    let buf = UnsafeMutablePointer<kinfo_proc>.allocate(capacity: count)
    defer { buf.deallocate() }
    if sysctl(&name, u_int(name.count), buf, &size, nil, 0) != 0 { return false }
    let actual = size / MemoryLayout<kinfo_proc>.size
    for i in 0..<actual {
        var p = buf[i]
        let comm = withUnsafePointer(to: &p.kp_proc.p_comm) {
            $0.withMemoryRebound(to: CChar.self, capacity: 17) {
                String(cString: $0)
            }
        }
        if comm == "AirAssist" { return true }
    }
    return false
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
      status [--json]                       Print persisted preferences.
                                            With --json: machine-readable,
                                            includes appRunning + appVersion.
      completions <shell>                   Emit shell completion script
                                            (zsh | bash | fish).
                                            Pipe into your fpath / source.
      open-dashboard                        Open the Dashboard window.
      open-preferences                      Open the Preferences window.
      version                               Print version.
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

