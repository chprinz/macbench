import SwiftUI

extension View {
    /// Return sends, Shift-Return breaks the line. The common action gets the
    /// plain key.
    ///
    /// The line break is put in by hand rather than left to the field: letting
    /// Shift-Return through was supposed to have the field insert it, and in the
    /// field that edits a message it did nothing at all. This goes to the text
    /// being edited, at the cursor, wherever that is.
    func onReturnKey(perform action: @escaping () -> Void) -> some View {
        onKeyPress(keys: [.return], phases: .down) { press in
            if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
                                 to: nil, from: nil)
                return .handled
            }
            action()
            return .handled
        }
    }
}
