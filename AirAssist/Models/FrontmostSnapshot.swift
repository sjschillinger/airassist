import Foundation

/// Snapshot of the frontmost app captured by `MenuBarController`
/// just before it opens the popover.
///
/// `NSWorkspace.shared.frontmostApplication` queried from inside the
/// popover returns Air Assist itself (the popover's `makeKey()`
/// activates us), so the "Throttle [frontmost]" button can't trust
/// a live query — it has to read from this captured value.
///
/// Lives on `ThermalStore` as `capturedFrontmost`; written by the
/// controller, read by the popover. Type lives at the model layer
/// because both writers and readers need it without depending on
/// each other.
struct FrontmostSnapshot: Sendable, Equatable {
    let pid: pid_t
    let name: String
}
