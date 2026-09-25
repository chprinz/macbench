import SwiftUI

/// What nobody works out alone: the three columns, what writing does and whom
/// it reaches, what the banners mean, and the two ways setting up goes wrong.
/// Opens once by itself after onboarding, and from the Help menu after that.
///
/// Every sentence here describes behaviour the code has. Where it says who gets
/// notified, or what "For" does without a task, it follows the query and the
/// patch that decide it, not what would sound reasonable.
struct GettingStartedView: View {
    @Environment(AppModel.self) private var model

    static let windowID = "getting-started"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Getting Started").font(.largeTitle.weight(.semibold))
                    Text("The essentials. This page stays in the Help menu.")
                        .foregroundStyle(.secondary)
                }

                Topic(symbol: "rectangle.split.3x1", title: "Three columns") {
                    Point("Left: your projects, Latest activity and Tasks. Middle: what you picked there. Right: the messages about it, with the field to write in.")
                }

                Topic(symbol: "text.bubble", title: "Messages") {
                    Point("Pick a file and write in the field on the right. Return sends. The message stays with the file, even when it moves.")
                    Point("There is no server: messages arrive with the sync of your folder.")
                }

                Topic(symbol: "at", title: "Task and For") {
                    Point("**Task** turns a message into something to tick off. **For**, or @name, notifies that person.")
                    Point("For without Task is just a heads-up: nothing to tick off, not listed under Tasks. Pick the person before sending.")
                }

                Topic(symbol: "doc", title: "Files") {
                    Point("Double-click opens a file. Space previews it without downloading it.")
                }

                Topic(symbol: "eye", title: "Unread") {
                    Point("What you have seen counts as read. Latest activity opens where you stopped.")
                }

                Topic(symbol: "square.and.pencil", title: "Quick note") {
                    if let shortcut = model.quickCaptureShortcut {
                        Point("\(shortcut) opens a quick note from any app.")
                    } else {
                        Point("A quick note opens from any app, with a shortcut you set in Settings.")
                    }
                }

                Topic(symbol: "line.3.horizontal.decrease", title: "Less in the list") {
                    Point("Too many file changes? Turn down the change stream in Settings, under Projects. Only for you.")
                    Point("A project is finished? Archive Project in its menu. Settings brings it back.")
                }

                Topic(symbol: "exclamationmark.triangle", title: "Messages at the top of the window") {
                    Banner("… is not being watched", "Folder moved, or its drive is not connected.")
                    Banner("iCloud is not delivering changes from …", "Check iCloud Drive on both Macs.")
                    Banner("… changes in … have not reached the others yet", "Nothing is lost; they follow later.")
                    Banner("Could not read … / Could not look for the other Macs …", "Entries may be missing until the sync catches up.")
                    Banner("… is running a newer version", "Update this Mac.")
                    Banner("iCloud made a conflict copy of …", "Open the folder and keep one version.")
                }

                Topic(symbol: "wrench.and.screwdriver", title: "Two common mistakes when setting up") {
                    Point("**Adding a folder inside a project.** Add the same top folder as the others, or you start a second history.")
                    Point("**Start at login off.** Changes carry your name only while the app runs. Leave it on.")
                }

                Topic(symbol: "keyboard", title: "Keyboard shortcuts") {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                        if let shortcut = model.quickCaptureShortcut {
                            Key(shortcut, "Quick note, from any app")
                        }
                        Key("⇧⌘O", "Add a project folder")
                        Key("⌘1", "Show or hide the sidebar")
                        Key("⌘2", "Show or hide the messages")
                        Key("⇧⌘" + Self.activityLetter, "Latest activity")
                        Key("⇧⌘" + Self.tasksLetter, "Tasks")
                        Key(String(localized: "Space") + " / ⌘Y", "Preview the picked file")
                        Key("⇧⌘K", "Mark everything as read")
                        Key("⇧↩", "New line")
                        Key("esc", "Clear the search")
                        Key("⌘,", "Settings")
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // The letters the menu uses, which follow the translated words. Looked up
    // by the same keys as the menu, so the two cannot disagree.
    private static var tasksLetter: String {
        String(localized: "shortcut.tasks", defaultValue: "t").uppercased()
    }
    private static var activityLetter: String {
        String(localized: "shortcut.activity", defaultValue: "l").uppercased()
    }
}

private struct Topic<Content: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol)
                .font(.title3.weight(.semibold))
                .labelStyle(.titleAndIcon)
            content
                .padding(.leading, 30)
        }
    }
}

private struct Point: View {
    let text: LocalizedStringKey
    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A banner as it reads in the window, and what to do about it.
private struct Banner: View {
    let title: LocalizedStringKey
    let meaning: LocalizedStringKey
    init(_ title: LocalizedStringKey, _ meaning: LocalizedStringKey) {
        self.title = title
        self.meaning = meaning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout.weight(.medium))
            Text(meaning).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Key: View {
    let keys: String
    let action: LocalizedStringKey
    init(_ keys: String, _ action: LocalizedStringKey) {
        self.keys = keys
        self.action = action
    }

    var body: some View {
        GridRow {
            Text(verbatim: keys)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(action)
        }
    }
}
