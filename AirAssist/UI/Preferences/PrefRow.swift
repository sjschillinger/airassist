import SwiftUI

/// Reusable row for a Preferences `Form { Section { … } }`. A `LabeledContent`
/// with an optional info button next to the title that opens a popover with
/// long-form help.
///
/// Two reasons this exists rather than reaching for `.help()` directly:
///
///   1. **Discoverability.** `.help()` only fires after a hover delay on the
///      exact element; new users have no signal that help even exists. The
///      `info.circle` glyph announces "there's more here if you want it"
///      without forcing the user to hunt.
///   2. **Density.** A clickable popover can carry 2-3 sentences without
///      bloating the row — much better than a long tooltip that the system
///      may truncate or position awkwardly.
///
/// The popover anchors off the info button itself, so it always lands next
/// to the option it explains regardless of window size.
struct PrefRow<Control: View>: View {
    let title: String
    /// Long-form help. nil hides the info button entirely (use this for
    /// rows whose meaning is obvious from the control alone).
    let info: String?
    @ViewBuilder var control: () -> Control

    init(_ title: String,
         info: String? = nil,
         @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.info = info
        self.control = control
    }

    var body: some View {
        LabeledContent {
            control()
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if let info {
                    InfoButton(text: info)
                }
            }
        }
    }
}

/// Small `info.circle` button that opens a popover with help text. Used
/// inside `PrefRow` but exposed independently so other surfaces (e.g.
/// inline help inside complex composite controls) can reuse it.
struct InfoButton: View {
    let text: String
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "info.circle")
                .imageScale(.small)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(text) // belt-and-braces: hover still works for keyboard users
        .accessibilityLabel("More information about \(text)")
        .popover(isPresented: $showing, arrowEdge: .trailing) {
            Text(text)
                // Match the system's menu/tooltip body type so the
                // popover feels like a native help bubble, not a
                // miniature window.
                .font(.system(size: 12))
                .padding(12)
                .frame(maxWidth: 280)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
