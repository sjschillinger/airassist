import AppKit
import Foundation
import Sparkle
import os

/// Thin wrapper around Sparkle's `SPUStandardUpdaterController` that
/// refuses to start unless the app is actually configured to receive
/// updates. Personal / ad-hoc builds (`SUFeedURL` blank, `SUPublicEDKey`
/// blank, or ad-hoc signature) turn every API on this type into a no-op.
///
/// **Why the gate exists:**
///   - Sparkle logs noisily on every launch when `SUFeedURL` is missing.
///   - Sparkle's installer relies on a Developer-ID-signed app; attempting
///     an update on an ad-hoc build surfaces a cryptic alert ("update
///     failed to validate") that confuses users who were never going to
///     update in the first place.
///   - Hiding the "Check for Updates…" menu item and skipping scheduled
///     checks keeps the UI honest: we don't advertise a feature the
///     current build can't deliver.
///
/// **Enabling updates:**
///   1. Generate EdDSA keys with Sparkle's `generate_keys` tool.
///   2. Paste the public key into `SUPublicEDKey` in `project.yml`.
///   3. Set `SUFeedURL` to your https://… appcast URL.
///   4. Sign the app with a Developer ID certificate.
/// `UpdateService.isConfigured` then returns true and the updater starts
/// automatically on next launch. The Sparkle SPM checkout ships a CLI
/// (`generate_keys`) that spits out the EdDSA keypair in one step.
@MainActor
final class UpdateService: NSObject {
    static let shared = UpdateService()

    private let logger = Logger(subsystem: "com.sjschillinger.airassist",
                                category: "Update")

    private var controller: SPUStandardUpdaterController?

    /// True when the app has a non-blank feed URL AND a non-blank public
    /// EdDSA key. A further runtime check (`isDeveloperIDSigned`) gates the
    /// actual start. We split the two so the UI can distinguish
    /// "not configured" from "configured but running unsigned".
    static var isConfigured: Bool {
        !feedURL.isEmpty && !publicKey.isEmpty
    }

    /// True when the running binary carries a Developer ID signature.
    /// Sparkle's installer refuses to apply updates to ad-hoc builds, so
    /// there's no point even starting the updater in that case.
    static var isDeveloperIDSigned: Bool {
        // Inspect our own code-signing requirements by asking the runtime.
        // `SecCodeCheckValidity` is heavier than we need here — we just
        // want the signing identity string. `SecCodeCopySigningInformation`
        // returns a dictionary that includes "teamid" and "signing-info".
        guard let selfCode = try? currentCodeObjectStatic() else { return false }
        var infoCF: CFDictionary?
        // SecCodeCopySigningInformation accepts SecStaticCode; SecCode is
        // toll-free bridged via `as SecStaticCode` (the concrete type is
        // shared underneath but the Swift overlay exposes them distinctly).
        let status = SecCodeCopySigningInformation(
            selfCode as! SecStaticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &infoCF
        )
        guard status == errSecSuccess, let info = infoCF as? [String: Any] else {
            return false
        }
        // Ad-hoc signatures have an empty or nil teamid AND the
        // "flags" dictionary contains `adhoc`. Developer ID signatures
        // always carry a non-empty team identifier.
        if let teamID = info["teamid"] as? String, !teamID.isEmpty {
            return true
        }
        return false
    }

    /// Start the updater if configured. Safe to call on every launch —
    /// does nothing when gates aren't met.
    func startIfConfigured() {
        guard Self.isConfigured else {
            logger.info("updates disabled: SUFeedURL or SUPublicEDKey missing")
            return
        }
        guard Self.isDeveloperIDSigned else {
            logger.info("updates disabled: app is not Developer-ID-signed")
            return
        }
        guard controller == nil else { return }

        // `startingUpdater: true` kicks off the background check scheduler
        // honoring `SUEnableAutomaticChecks` / `SUScheduledCheckInterval`
        // from Info.plist. We pass `updaterDelegate: self` so we can log
        // failures that would otherwise go to Console silently.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        logger.info("Sparkle updater started (feed=\(Self.feedURL, privacy: .public))")
    }

    /// Action target for the "Check for Updates…" menu item.
    /// Presents the standard Sparkle UI with the "Install and Relaunch"
    /// prompt flow. When not configured, shows an alert explaining why
    /// — never silently fails (the user clicked a menu item; they
    /// deserve feedback).
    @objc func checkForUpdates(_ sender: Any?) {
        guard Self.isConfigured, Self.isDeveloperIDSigned else {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Updates are not enabled in this build."
            alert.informativeText = """
            This Air Assist binary was built without a configured update \
            feed. To get updates, install the signed release from the \
            project's Releases page.
            """
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        controller?.checkForUpdates(sender)
    }

    /// True when the "Check for Updates…" menu item should be visible.
    /// Builds without any update configuration hide it entirely (no point
    /// offering a feature we can't deliver).
    static var shouldShowMenuItem: Bool {
        isConfigured
    }

    // MARK: - Info.plist accessors

    private static var feedURL: String {
        (Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static var publicKey: String {
        (Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: - Signing introspection

    private static func currentCodeObjectStatic() throws -> SecCode {
        var code: SecCode?
        let status = SecCodeCopySelf(SecCSFlags(rawValue: 0), &code)
        guard status == errSecSuccess, let code else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return code
    }
}

extension UpdateService: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater,
                             didAbortWithError error: Error) {
        // MainActor hop so we can use the isolated logger. This fires on
        // network errors, missing appcast, signature mismatch — all things
        // we want in the log but not in the user's face.
        Task { @MainActor in
            self.logger.warning("Sparkle aborted: \(String(describing: error), privacy: .public)")
        }
    }

    nonisolated func updater(_ updater: SPUUpdater,
                             didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                             error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            self.logger.info("Sparkle cycle ended with error: \(String(describing: error), privacy: .public)")
        }
    }
}
