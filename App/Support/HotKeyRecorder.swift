import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Lets you press the shortcut you want instead of picking from a list.
///
/// It uses a local key monitor rather than SwiftUI's key handling because the
/// Carbon hot key API wants a virtual key code, and `NSEvent.keyCode` is exactly
/// that — no lookup table that goes wrong on a non-US keyboard.
struct HotKeyRecorder: View {
    @Binding var combination: GlobalHotKey.Combination?
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                isRecording ? stop() : start()
            } label: {
                Text(label)
                    .font(.system(.body, design: .monospaced))
                    .frame(minWidth: 90)
            }
            if combination != nil, !isRecording {
                Button("Turn Off") { combination = nil }
                    .controlSize(.small)
            }
        }
        .onDisappear(perform: stop)
    }

    private var label: String {
        if isRecording { return String(localized: "Press keys…") }
        return combination?.displayString ?? String(localized: "Off")
    }

    private func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            guard event.type == .keyDown else { return nil }
            if event.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            let carbon = GlobalHotKey.Combination.carbonModifiers(from: event.modifierFlags)
            // A shortcut with no modifier would swallow that key everywhere.
            guard carbon != 0 else { return nil }
            combination = GlobalHotKey.Combination(keyCode: UInt32(event.keyCode), modifiers: carbon)
            stop()
            return nil
        }
    }

    private func stop() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
