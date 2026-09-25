# MacBench

**A shared activity feed and chat for project folders synced between Macs.**

MacBench is a macOS app for small teams who share project folders through iCloud
Drive, Dropbox or a NAS. It shows what changed in those folders, who changed it,
and lets you discuss files, and assign tasks about them, right next to the files
themselves. No account, no server.

![The activity list: file changes and messages from every project in one
chronological list, with a line marking where you stopped reading](docs/screenshots/activity.png)

## Features

- **Activity feed.** See every change across all your projects in one list, with
  a marker showing where you left off.
- **Clean history.** Repeated saves of the same file are grouped into one entry.
  Cache files from Adobe, Affinity and DaVinci Resolve are hidden.
- **Know who changed what.** Each change shows which Mac it came from. If that
  can't be determined, it is marked as unknown.
- **Comments, chat and tasks in one place.** Write about any file or folder. Turn
  a message into a task with one click, and mention someone with @name to notify
  them.
- **Search everything.** Find files by name, folder or anything written about them.
- **Comments follow the file.** Renaming, moving or deleting a file keeps its
  conversation intact.
- **English and German**, following your macOS language.

## Requirements

- macOS 26
- Xcode 26 (to build)
- A folder synced between your Macs (iCloud Drive, Dropbox, NAS or similar)

No paid Apple Developer account is needed.

## Installation

```bash
brew install xcodegen
./build.sh MacBench Release
```

On first launch:

1. Choose the shared project folder.
2. Enter your name.
3. Leave *Start at login* on.

Existing files are indexed silently. The history starts from the day you install.
A *Getting Started* window then opens once; it stays in the Help menu.

## Using MacBench

The window has three columns:

| Left | Middle | Right |
|---|---|---|
| Latest activity, Tasks and your projects | The list for what you selected | Comments and chat about the selected item |

![A folder: its files in the middle, everything said about them on the right,
with the field to write at the bottom](docs/screenshots/folder.png)

- **Write a comment:** select a file or folder and type in the field at the
  bottom right.
- **Create a task:** tick the checkbox next to the field before sending.
- **Notify someone:** write @name. Only messages notify; file changes never do.
- **See open tasks:** choose *Tasks* in the sidebar. They are grouped by person,
  with yours first.
- **Open a file:** double-click it, in the file list or on any line about it.

![The task list, grouped by the person each task is for, yours
first](docs/screenshots/tasks.png)

### Getting started

The *Getting Started* window (Help menu) explains the rest in English and
German. Three things people ask about first:

- **Messages travel with the files.** There is no server: what you write reaches
  the others through the same sync as the folder, when that sync delivers it.
- **Double-click opens a file** in its own app, as in the Finder. Space or
  <kbd>⌘Y</kbd> previews it without downloading it from iCloud.
- **For without Task is a heads-up.** The person is named in front of the message
  and notified, but there is nothing to tick off and it does not appear under
  Tasks. Pick the person before sending: choosing them later changes the name
  shown but is not sure to notify.

It also covers unread, the quick note, the change stream, archiving, what the
banners at the top of the window mean, and the two most common setup mistakes:
adding a folder *inside* a project someone already added, which starts a second
history nobody else sees, and leaving *Start at login* off, which leaves your
changes to be found later without your name.

### Keyboard shortcuts

| Shortcut | Action |
|---|---|
| <kbd>⌃⌥⌘N</kbd> | Quick note, from any app (change it in Settings) |
| <kbd>⇧⌘O</kbd> | Add a project folder |
| <kbd>⌘1</kbd> | Show or hide the sidebar |
| <kbd>⌘2</kbd> | Show or hide the messages |
| <kbd>⇧⌘L</kbd> | Latest activity (German: <kbd>⇧⌘N</kbd>) |
| <kbd>⇧⌘T</kbd> | Tasks (German: <kbd>⇧⌘A</kbd>) |
| <kbd>Space</kbd> or <kbd>⌘Y</kbd> | Preview the selected file |
| <kbd>⇧⌘K</kbd> | Mark everything as read |
| <kbd>Return</kbd> / <kbd>⇧Return</kbd> | Send / new line |
| <kbd>⌘,</kbd> | Settings |

## How syncing works

MacBench uses the sync service you already have. It does not run its own.

Each Mac writes to its own log file in a hidden `.macbench` folder inside the
project folder. Because no file is ever written by more than one Mac, there are no
sync conflicts.

```
Client Project/
  Layout/poster.afdesign
  .macbench/
    devices/
      3F2A…/manifest.json      ← this Mac's identity and last-seen time
      3F2A…/000001.jsonl       ← this Mac's activity log (append-only)
```

The logs are plain JSON lines, readable in any text editor. If records from
another Mac haven't arrived yet, MacBench tells you the sync is behind instead of
showing nothing.

## Privacy

- No network access. The app contains no network code.
- No accounts, no analytics.
- Files are never downloaded from iCloud on its own.
- Local paths and read status stay on your Mac.

## Development

```bash
./test.sh                        # everything CI checks
cd MacBenchCore && swift test    # the core tests alone
```

- [docs/development.md](docs/development.md): everyday commands and rules
- [docs/testing.md](docs/testing.md): how to test, including a second Mac on the
  command line and the checklist before a release
- [docs/architecture.md](docs/architecture.md): how the sync works and why
- [docs/backlog.md](docs/backlog.md): planned work
- [docs/workflow-review.md](docs/workflow-review.md): known rough edges

## License

MIT. See [LICENSE](LICENSE).
