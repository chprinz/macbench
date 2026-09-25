import SwiftUI
import AppKit

/// The space bar, the way the Finder does it.
///
/// A local event monitor rather than a button carrying a keyboard shortcut: a
/// key equivalent without a modifier is offered the keystroke before the focused
/// text field is, so a hidden button holding the space bar would take the space
/// bar out of the composer and the search field. The monitor asks who has focus
/// and steps aside for anything that accepts text.
struct QuickLookSpaceBar: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard isPlainSpace(event) else { return event }
                    let window = event.window
                    // The event itself cannot cross into the actor — it is not
                    // Sendable — so what crosses back is the one bit of it that
                    // matters: whether this keystroke was taken.
                    let taken = MainActor.assumeIsolated { () -> Bool in
                        guard !isTyping(in: window) else { return false }
                        model.toggleQuickLookForSelection()
                        return true
                    }
                    return taken ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }

    private func isPlainSpace(_ event: NSEvent) -> Bool {
        event.charactersIgnoringModifiers == " "
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .isDisjoint(with: [.command, .option, .control, .shift, .function])
    }

    /// Anything that takes typing keeps its space. `NSTextInputClient` covers the
    /// field editor behind a SwiftUI text field as well as a text view of its own.
    @MainActor
    private func isTyping(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        return responder is NSText || responder is NSTextInputClient
    }
}

extension View {
    /// Space previews what the middle column points at, and puts the preview away
    /// again. Applied where a file can be selected, not app-wide.
    func quickLookOnSpaceBar() -> some View {
        modifier(QuickLookSpaceBar())
    }
}
