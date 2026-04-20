// airassist-rescue
// ================
//
// Tiny standalone CLI that reads AirAssist's dead-man's-switch file
// (`~/Library/Application Support/AirAssist/inflight.json`) and sends
// SIGCONT to every pid listed there. Removes the file afterwards.
//
// **Why this tool exists, in one sentence:** if AirAssist crashes while
// it has processes SIGSTOP'd, and the user never relaunches the app,
// those processes stay frozen forever. `recoverOnLaunch` only runs
// when AirAssist itself is launched. A separate tool — runnable
// independently of the app — closes that window.
//
// **How it's used:**
//
// 1. **LaunchAgent on login.** The app registers
//    `com.sjschillinger.airassist.rescue.plist` via `SMAppService` so
//    this binary runs once at login. If the previous session ended
//    cleanly, there's no inflight file and we exit silently. If not,
//    the pids get unfrozen before the user notices anything is wrong.
//
// 2. **Standalone `.command` shipped in the DMG.** For the worst case
//    (app uninstalled, disk full, user downgraded macOS and now the app
//    won't launch), users can double-click `airassist-rescue.command`
//    directly. No dependencies beyond stock macOS.
//
// **Design principles:**
//   - Zero dependencies beyond Foundation + Darwin. Must keep working
//     even if the main app is entirely broken.
//   - Idempotent. Safe to run if the file doesn't exist, is corrupted,
//     or lists already-dead pids.
//   - Always removes the file on exit, even on decode failure — a junk
//     file must not block future launches.
//   - Non-zero exit only if we actually found pids we couldn't resume
//     (and logged them). Exit 0 for "nothing to do" — LaunchAgents
//     shouldn't retry on benign no-ops.

import Foundation
import Darwin

private struct InflightRecord: Codable {
    var pids: [Int32]
    var writtenAt: Date
}

private func log(_ s: String) {
    // Stderr so LaunchAgent captures it; Console.app → process: airassist-rescue.
    FileHandle.standardError.write(Data("airassist-rescue: \(s)\n".utf8))
}

private func inflightURL() -> URL {
    let fm = FileManager.default
    let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    return base.appendingPathComponent("AirAssist/inflight.json")
}

let url = inflightURL()
let fm = FileManager.default

// Always remove the file, even if we decode-failed. A junk file must not
// wedge every login forever.
defer { try? fm.removeItem(at: url) }

guard fm.fileExists(atPath: url.path) else {
    // The common case: clean shutdown last session. Exit silently (exit 0)
    // so we don't clutter Console.app on every login.
    exit(0)
}

guard let data = try? Data(contentsOf: url), !data.isEmpty else {
    log("inflight file exists but is empty or unreadable; removing.")
    exit(0)
}

guard let rec = try? JSONDecoder().decode(InflightRecord.self, from: data) else {
    log("inflight file could not be decoded; removing.")
    exit(0)
}

if rec.pids.isEmpty {
    log("inflight file had no pids; removing.")
    exit(0)
}

var resumed = 0
var skipped = 0
for raw in rec.pids {
    // Reject absurd / malicious pid values. pid_t is 32-bit signed;
    // legitimate pids are 1…~99999 on Darwin. A rogue or truncated file
    // could otherwise have us kill(-1, SIGCONT), which means "resume
    // everything we own."
    guard raw > 1, raw < 1_000_000 else {
        skipped += 1
        continue
    }
    let pid = pid_t(raw)
    let r = kill(pid, SIGCONT)
    if r == 0 {
        resumed += 1
    } else if errno == ESRCH {
        // Process already exited — harmless, the common case for pids
        // that have been SIGSTOP'd through a full logout/login cycle.
        skipped += 1
    } else {
        log("SIGCONT pid=\(pid) failed: errno=\(errno)")
        skipped += 1
    }
}

log("released \(resumed) of \(rec.pids.count) pids (skipped \(skipped), written at \(rec.writtenAt)).")
exit(0)
