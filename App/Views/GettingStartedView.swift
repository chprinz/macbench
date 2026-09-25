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
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Getting Started").font(.largeTitle.weight(.semibold))
                    Text("How the window is laid out, what writing does and whom it reaches, and what to do when something looks off. This page is in the Help menu whenever you want it again.")
                        .foregroundStyle(.secondary)
                }

                Topic(symbol: "rectangle.split.3x1", title: "Three columns") {
                    Point("**Left:** Latest activity, Tasks, and your projects with their folders.")
                    Point("**Middle:** what you picked on the left: the files in a folder, every open task, or everything that has happened.")
                    Point("**Right:** the messages about what you picked in the middle, with the field to write in at the bottom. Messages in the toolbar shows and hides this column.")
                }

                Topic(symbol: "text.bubble", title: "Messages") {
                    Point("Pick a file or folder, then write in the field at the bottom right. The message stays with that file, even when it is renamed or moved.")
                    Point("Return sends, Shift-Return starts a new line. To answer a message, choose Reply from its menu (Control-click).")
                    Point("Turn on **Task** before sending to make it something to do. Open tasks collect under Tasks in the sidebar until somebody ticks them off.")
                    Point("There is no server. Messages travel with your files, through iCloud Drive, Dropbox or your NAS, and arrive on the other Macs when the sync delivers them.")
                }

                Topic(symbol: "at", title: "Who a message is for") {
                    Point("**For**, or @ and a name in the text, addresses a message to one person. Their name appears in front of it in their colour, and they get a notification.")
                    Point("With Task on, it is work for them: it is listed under their name in Tasks. Without it, it is a heads-up: a notification, nothing to tick off, and it does not appear in Tasks.")
                    Point("Pick the person before you send. Changing For later, from the message's menu, changes the name shown, but only a message that arrives already addressed is sure to notify.")
                    Point("A reply to something you wrote notifies you too. File changes never do.")
                }

                Topic(symbol: "doc", title: "Files") {
                    Point("Double-click a file to open it in its app, as in the Finder. The same works on any line in the messages that is about a file.")
                    Point("Space or ⌘Y shows a preview. A file with a cloud icon is not on this Mac yet: the preview leaves it in the cloud, opening it downloads it.")
                    Point("Nothing here moves, renames or deletes a file. That stays the Finder's job.")
                }

                Topic(symbol: "circle.fill", title: "Unread") {
                    Point("A line counts as read once it has been on screen for a moment. The number beside Latest activity is what you have not read yet, and a dot in the sidebar marks the folders it is in.")
                    Point("Latest activity opens where you stopped, at a line marking the spot. Your own entries are never unread.")
                    Point("Mark as Unread, in a line's menu, puts it back. The menu of a project or folder marks it all as read; ⇧⌘K marks everything.")
                }

                Topic(symbol: "square.and.pencil", title: "Quick note") {
                    if let shortcut = model.quickCaptureShortcut {
                        Point("\(shortcut) opens a small window from any app, even with every window closed. Pick the project, write, press Return.")
                    } else {
                        Point("A shortcut opens a small window from any app, even with every window closed. Pick the project, write, press Return. There is none set right now; choose one in Settings, under General.")
                    }
                    Point("Task and @name work as in the field on the right. A quick note belongs to the project, not to a file.")
                }

                Topic(symbol: "clock.arrow.circlepath", title: "The change stream") {
                    Point("Every change to a file becomes a line. Repeated saves of one file are gathered for twenty minutes and then shown as one line; until then they are listed below the messages with a countdown.")
                    Point("Too much? In Settings, under Projects, set **Change stream** to *Only bigger events* (files added, deleted, moved or renamed) or to *Nothing — only what we write*. Messages always show, and the setting is yours alone.")
                }

                Topic(symbol: "archivebox", title: "Archiving") {
                    Point("**Archive Project**, in a project's menu in the sidebar, is for a job that is done. It is no longer watched and leaves the lists; its history is kept. It comes back from Settings, under Projects, and whatever changed meanwhile is found by comparing the folder.")
                    Point("Deleted files move to the archive after a while, 90 days unless you change it in Settings, under General. They leave the lists and search; what was written about them is kept.")
                    Point("Both apply only on your Mac. Nothing is deleted, for you or for anybody else.")
                }

                Topic(symbol: "exclamationmark.triangle", title: "Messages at the top of the window") {
                    Point("Problems with the sync are shown, never hidden. The × puts one away; it comes back on the next start if the problem is still there.")
                    Banner("… is not being watched",
                           "The folder cannot be opened: renamed, moved, or on a drive that is not connected. Reconnect it, or add it again. The reason stays in Settings, under Projects, and changes made meanwhile are found by comparing the folder once it can be read.")
                    Banner("iCloud is not delivering changes from …",
                           "Another Mac has announced changes that have not arrived for over ten minutes. Check that iCloud Drive is syncing on both Macs; the changes show up by themselves. A shorter wait appears only at the foot of the sidebar and needs nothing from you.")
                    Banner("… changes in … have not reached the others yet",
                           "This Mac could not write its log into the folder. Nothing is lost: the changes are kept here and written once it works again.")
                    Banner("Could not read … / Could not look for the other Macs …",
                           "Something in the shared folder could not be read, so entries may be missing until it can. If it lasts, check that the folder syncs.")
                    Banner("… is running a newer version",
                           "Somebody has updated. Update on this Mac too, to see what they write.")
                    Banner("iCloud made a conflict copy of …",
                           "Two people saved the same file at the same moment. Open the folder and keep the version you want.")
                }

                Topic(symbol: "wrench.and.screwdriver", title: "Two common mistakes when setting up") {
                    Point("**Adding a folder inside the project.** A project keeps one shared history in its top folder. If somebody has already added it, add the same folder they did. A folder inside it would start a second history that nobody else sees. When this happens you are warned and offered the right folder.")
                    Point("**Leaving Start at login off.** Changes are recorded with your name only while the app runs. What you do while it is closed is found later by comparing the folder, with a ~ before the time and often without your name. Closing the window does not stop it; it keeps watching in the background. The switch is in Settings, under General.")
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
                        Key(String(localized: "Space") + "  ⌘Y", "Preview the picked file")
                        Key("⇧⌘K", "Mark everything as read")
                        Key("↩", "Send")
                        Key("⇧↩", "New line")
                        Key("⎋", "Clear the search")
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
                .font(.body.monospaced())
                .gridColumnAlignment(.trailing)
            Text(action)
        }
    }
}
