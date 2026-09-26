import SwiftUI
import AppKit

/// ⌥← and ⌥→ for back and forward, beside ⌘[ and ⌘] on the menu.
///
/// A monitor rather than a menu shortcut, for the reason the space bar has one:
/// in a text field ⌥← jumps a word, and a menu item would take that away from
/// the composer, which holds the focus nearly all the time. So the keys belong
/// to the text while there is text to move through, and to the history while
/// the field is empty or nothing is typed into at all.
struct OptionArrowHistory: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard let forward = direction(of: event) else { return event }
                    let window = event.window
                    // As in QuickLookSpaceBar: only the verdict crosses back, not
                    // the event, which is not Sendable.
                    let taken = MainActor.assumeIsolated { () -> Bool in
                        guard !hasTextToMoveThrough(in: window) else { return false }
                        if forward { model.goForward() } else { model.goBack() }
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

    /// True for ⌥→, false for ⌥←, nil for anything else. The arrow keys carry
    /// the function and numeric-pad flags of their own, so only the modifiers a
    /// person holds are compared.
    private func direction(of event: NSEvent) -> Bool? {
        let held = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard held == .option else { return nil }
        switch event.keyCode {
        case 123: return false
        case 124: return true
        default: return nil
        }
    }

    /// A field with words in it keeps ⌥← for moving through them. An empty one
    /// has nothing to move through, and the composer is empty most of the time
    /// it has the focus.
    @MainActor
    private func hasTextToMoveThrough(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if let text = responder as? NSText { return !text.string.isEmpty }
        return responder is NSTextInputClient
    }
}

extension View {
    func optionArrowHistory() -> some View {
        modifier(OptionArrowHistory())
    }
}
