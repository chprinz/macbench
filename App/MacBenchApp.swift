import SwiftUI
import UserNotifications
import MacBenchCore

@main
struct MacBenchApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup(id: AppDelegate.mainWindowID) {
            RootView()
                .environment(model)
                .background(WindowReader { delegate.adopt($0) })
                // No minimum frame around the split view. A flexible frame here
                // is not the window's minimum size - it is a demand the split
                // view has to meet from inside, and when the inspector was shown
                // the three columns together asked for more than the window had.
                // Nothing gave way, so the layout hung over both edges instead.
                // The window's minimum comes from the columns' own minimums.
                .frame(minHeight: 520)
                .task {
                    delegate.model = model
                    model.quickCaptureAction = {
                        NSApp.activate(ignoringOtherApps: true)
                        openWindow(id: "quick-capture")
                    }
                    await model.start()
                    model.installHotKey()
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands { MacBenchCommands(model: model) }

        Window("Quick Note", id: "quick-capture") {
            QuickCaptureView()
                .environment(model)
        }
        .defaultSize(width: 460, height: 190)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Getting Started", id: GettingStartedView.windowID) {
            GettingStartedView()
                .environment(model)
        }
        .defaultSize(width: 640, height: 720)
        .defaultPosition(.center)

        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 620, height: 460)
        }
    }
}

/// The app is a background process that has a window, not a window that has a
/// background process.
///
/// It only knows who changed a file if it is running on the Mac where that
/// happened, and it was closed most of the time because a window and a Dock icon
/// were in the way of the day. So the window is the only thing that makes it
/// visible: while one is open there is a Dock icon and a menu bar, and once it is
/// closed both go and the watching carries on. Started at login, it starts out of
/// sight. Opening the app again — from the Finder, Spotlight or a notification —
/// brings the window back.
///
/// Quitting has work to do.
///
/// A quiet change is gathered for twenty minutes before it becomes an entry, and
/// there is no second chance at it: the index has not recorded that version of
/// the file yet either, so nothing would ever mention it again. Everything still
/// in flight is therefore written out before the process is allowed to end.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static let mainWindowID = "main"

    var model: AppModel?
    private var hasReplied = false
    /// Launched by the login item — or with `--background`, which is the same
    /// start without logging out to see it.
    private var startsHidden = false
    private var hasPlacedFirstWindow = false
    private var observers: [NSObjectProtocol] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        startsHidden = CommandLine.arguments.contains("--background") || Self.wasLaunchedAtLogin
        if startsHidden { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The open-application event is being handled right now, so this is the
        // moment it can be read. Earlier it may not be there yet.
        if !startsHidden, Self.wasLaunchedAtLogin {
            startsHidden = true
            NSApp.setActivationPolicy(.accessory)
        }
        UNUserNotificationCenter.current().delegate = self
        let names = [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                // After the fact: a closing window is still visible while it
                // says it is about to close.
                DispatchQueue.main.async { MainActor.assumeIsolated { AppDelegate.updateDockPresence() } }
            }
        }
    }

    private static var wasLaunchedAtLogin: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Every main window passes through here once it has one. The first one, on a
    /// start that is meant to stay out of sight, is put away before it is drawn:
    /// it is kept rather than closed, because it is what runs the start-up.
    func adopt(_ window: NSWindow) {
        guard !hasPlacedFirstWindow else { return }
        hasPlacedFirstWindow = true
        guard startsHidden else { return }
        window.alphaValue = 0
        DispatchQueue.main.async {
            window.orderOut(nil)
            window.alphaValue = 1
            Self.updateDockPresence()
        }
    }

    /// Opening the app while it runs in the background. A window put away at
    /// launch is still there and is brought back; otherwise SwiftUI opens a new one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.showMainWindow()
    }

    /// A click on a notification is a request to see what it was about.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        await MainActor.run { _ = Self.showMainWindow() }
    }

    /// Returns whether a new window still has to be opened.
    @discardableResult
    static func showMainWindow() -> Bool {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        if let window = NSApp.windows.first(where: { isMainWindow($0) && !$0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
            return false
        }
        return !NSApp.windows.contains { isMainWindow($0) && $0.isVisible }
    }

    /// A Dock icon while there is a window worth switching to — the main window,
    /// Settings or the guide, minimised ones included, since the Dock is the only
    /// way back to those. The quick note is not one: it comes and goes with its
    /// shortcut.
    static func updateDockPresence() {
        let wantsDock = NSApp.windows.contains { window in
            (isMainWindow(window) || isSettingsWindow(window) || isGuideWindow(window))
                && (window.isVisible || window.isMiniaturized)
        }
        let policy: NSApplication.ActivationPolicy = wantsDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    private static func isMainWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix(mainWindowID) == true
    }

    private static func isGuideWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix(GettingStartedView.windowID) == true
    }

    private static func isSettingsWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.contains("Settings") == true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        Task { @MainActor in
            await model.stop()
            reply()
        }
        // A quit that hangs is worse than a lost line: whatever has not been
        // flushed by now is at least still on disk to be compared against.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            reply()
        }
        return .terminateLater
    }

    private func reply() {
        guard !hasReplied else { return }
        hasReplied = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}

/// Hands the window a SwiftUI view ends up in to whoever needs the AppKit side of
/// it.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReaderView: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}

struct MacBenchCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Project Folder…") { chooseFolder() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("Quick Note") { openWindow(id: "quick-capture") }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
        // The two columns either side of the files, by their place on screen:
        // ⌘1 left, ⌘2 right. Replacing the system's own sidebar item, which
        // would otherwise sit above this one with ⌃⌘S.
        CommandGroup(replacing: .sidebar) {
            Button("Toggle Sidebar") {
                NSApp.sendAction(#selector(NSSplitViewController.toggleSidebar(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("1", modifiers: .command)
            Button(model.isStreamVisible ? "Hide Messages" : "Show Messages") {
                model.isStreamVisible.toggle()
            }
            .keyboardShortcut("2", modifiers: .command)
            Divider()
            // The letters follow the words, so they differ by language: ⇧⌘A for
            // Aufgaben, ⇧⌘T for Tasks.
            Button("Tasks") { model.selection = .openTasks }
                .keyboardShortcut(Shortcut.key(String(localized: "shortcut.tasks", defaultValue: "t")), modifiers: [.command, .shift])
            Button("Latest activity") { model.selection = .activity }
                .keyboardShortcut(Shortcut.key(String(localized: "shortcut.activity", defaultValue: "l")), modifiers: [.command, .shift])
            Divider()
            // ⌘[ and ⌘], as in the Finder and Safari.
            Button("Back") { model.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!model.canGoBack)
            Button("Forward") { model.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!model.canGoForward)
            Divider()
        }
        CommandGroup(after: .toolbar) {
            // The space bar does this too, on the row the list points at. ⌘Y is
            // here because a shortcut that only exists as a bare space bar is a
            // shortcut nobody can find in a menu.
            Button("Quick Look") { model.toggleQuickLookForSelection() }
                .keyboardShortcut("y", modifiers: .command)
                .disabled(model.selectedNode.map { !model.canQuickLook($0) } ?? true)
            Button("Mark Everything as Read") { model.markAllRead(project: nil) }
                .keyboardShortcut("k", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .help) {
            Button("Getting Started") { openWindow(id: GettingStartedView.windowID) }
            Link("\(Brand.name) on GitHub", destination: Brand.repository)
        }
    }

    private func chooseFolder() {
        guard let url = FolderPicker.chooseProjectFolder() else { return }
        Task { await model.addProject(url: url) }
    }
}

/// A menu shortcut whose letter is part of the translation, for items whose
/// shortcut is the first letter of their name. The caller looks the letter up,
/// so that string extraction sees the key.
enum Shortcut {
    static func key(_ letter: String) -> KeyEquivalent {
        KeyEquivalent(letter.lowercased().first ?? "?")
    }
}

enum FolderPicker {
    /// The only way the app ever gets access to anything: the user points at a
    /// folder. There is no configured root and no scanning of the home directory.
    @MainActor
    static func chooseProjectFolder() -> URL? {
        guard let picked = runPanel(
            message: String(localized: "Choose a client or project folder. It will be watched, and its history kept in .macbench/ inside it."))
        else { return nil }
        return checkedForEnclosingProject(picked)
    }

    /// A folder inside somebody else's project is not a project of its own. Added
    /// as one it starts a second history beside theirs, and the two never meet:
    /// what either side writes never reaches the other, and neither can tell.
    /// So the bigger folder is offered instead, and only offered — the one who
    /// picked may know something this check does not.
    @MainActor
    private static func checkedForEnclosingProject(_ picked: URL) -> URL? {
        guard let root = LogLayout.enclosingProjectRoot(of: picked) else { return picked }
        let part = picked.lastPathComponent
        let whole = root.lastPathComponent
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(part)” is part of the project “\(whole)”")
        alert.informativeText = String(localized: "Somebody already keeps the history of “\(whole)”. Adding only “\(part)” would start a second one beside it: nothing written in either would reach the other. Add “\(whole)” instead — “\(part)” is in it, with everything else.")
        alert.addButton(withTitle: String(localized: "Add “\(whole)”…"))
        alert.addButton(withTitle: String(localized: "Add “\(part)” Anyway"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // The sandbox opens only a folder somebody pointed at, so the way to
            // the bigger one goes through the same panel, already standing in it.
            guard let confirmed = runPanel(
                message: String(localized: "Click Add Project to add “\(whole)”. You are already in it."),
                in: root)
            else { return nil }
            // They may have walked somewhere else in the panel.
            return checkedForEnclosingProject(confirmed)
        case .alertSecondButtonReturn:
            return picked
        default:
            return nil
        }
    }

    @MainActor
    private static func runPanel(message: String, in directory: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Add Project")
        panel.message = message
        // Standing in a folder with nothing selected, the panel hands back that
        // folder — which is what the confirmation relies on.
        if let directory { panel.directoryURL = directory }
        return panel.runModal() == .OK ? panel.url : nil
    }
}
