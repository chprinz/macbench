# Backlog

Everything noticed along the way that is not done. Kept here rather than in
someone's head. Newest observations at the top of each section.

## Gaps against the specification

- **Sidebar indentation** is whatever SwiftUI's `DisclosureGroup` does, not the
  twelve points the spec asks for.
- **Foundation Models** — natural-language search and the weekly review. Marked
  optional in the spec and deliberately deferred. The query layer they would
  drive already exists.
- **Project archiving** exists in the store (`setProjectArchived`) with no way to
  reach it, and projects cannot be reordered although `sortIndex` is there.

## Rough edges

- **Search leaves the two columns out of step.** Typing in the search field
  replaces the middle column, but the stream on the right keeps showing the
  previous selection — in the activity and task views too, where the middle
  column is the whole point of the view.
- **No way to mark an entry unread again** after reading it by accident.
- **The timeline stops at 400 entries** with no way to load more and nothing
  saying it stopped. It matters more now that the activity list is the widest
  column rather than a 320-point inspector.
- **The picked line is forgotten on relaunch.** Latest activity and Tasks restore
  which list you were in, not which entry you had open, so the column beside them
  starts empty every morning.
- **Which filters are remembered is a judgement call, not a setting.**
  Categories, "without file changes", the sidebar's tree filter and the task
  list's person come back; "Done" deliberately does not, because it would open
  the app on a list that is empty for a reason set days ago. The person used to
  be left out for the same reason, and the first bug report said "only mine" is
  how people work, not something they look up once.
- **Verbosity is settable in two places**, the project's context menu and
  Settings. One of them should go.

## Technical

- **A machine never reads its own log, so a reset loses its own history.**
  `PeerSync.pull` skips the device it runs on, which is right while the index is
  intact and wrong the moment it is not: everything this Mac ever wrote still
  sits in its own segments, readable, and is never read again. The other Mac
  keeps those entries and goes on showing them; the one that wrote them does
  not. README and `development.md` both say the log is enough to rebuild the
  index from scratch — true only of the other machines' half of it. Reading
  one's own segments when the index comes up empty would close the gap;
  `merge(entry:)` is already idempotent, so nothing would arrive twice.

- **A devices folder that cannot be listed looks exactly like an empty one.**
  `DeviceLogReader.peers` swallows the error with `?? []`. The `.skipsHiddenFiles`
  bug lived five days behind that silence: two Macs writing into the same folder,
  neither ever saying that it had read nothing from the other. A record that
  cannot be applied now reaches a banner as an unreadable log, and the engine's
  own errors are shown too; a listing that failed belongs on the same route.

- **A Mac that cannot read its own manifest starts counting at one again.**
  `DeviceLogWriter.init` treats an unreadable `manifest.json` as a first start —
  a manifest iCloud has evicted on a Mac that was off for months would do it —
  and new records then reuse sequence numbers the other Mac has already passed,
  so it never reads them. A coordinated read (which waits for the download), or
  refusing to write until the manifest is here, would close it.

- **FSEvents batches are handed to the engine in unstructured tasks**, one per
  callback, and nothing guarantees they run in the order they were delivered.
  In practice a second apart; a serial hand-off (an `AsyncStream`) would make
  it a guarantee.

- **The identity lives in the index.** If `index.sqlite` cannot be opened it is
  deleted and rebuilt, and with it goes who this Mac is: the person onboards
  again, gets a new member id, and appears to the others as somebody new. Keeping
  `LocalIdentity` beside the index, not inside it, would survive the reset.

- **The thumbnail cache on disk is never pruned.** Keyed by file and date now, so
  every saved version of an image leaves a small PNG behind.

- **The sidebar's width is remembered by measuring it.** SwiftUI gives no binding
  for a split view's width, so the sidebar reports its size while being dragged
  and that value is handed back as the ideal width next launch. It works, but it
  is a measurement rather than a real restoration: the very first frame after
  launch is drawn at the ideal width and then settles. The stream no longer has
  this problem — its width is now a fixed constant, not remembered.

- **`AppModel.refreshAll` re-runs every query on any database change.** Debounced
  to 180 ms, which is fine for two people and a few thousand entries, and will
  not be fine at a hundred thousand. The tree in particular is rebuilt from
  scratch when only an entry changed.
- **`Selection.node` covers both files and folders**, so several call sites have
  to ask which one it is. Splitting it would remove those branches.
- **No guard against a duplicated device folder.** If a Mac is cloned (Time
  Machine restore, Migration Assistant), two installs write under one device id,
  which is the one way the "no file is written twice" invariant can break. Fix:
  an instance token in the manifest; on a mismatch, mint a new device id.

- **No "mark as unread".** The dwell before an entry counts as read is 900 ms,
  which is short enough that glancing at the stream clears it.
- **A retraction cannot be undone.** `isRetracted` is a patch like any other, so
  the reverse patch would work; there is no way to reach it.
- **File names lose their middle** at the stream's default width. Either the
  default is too narrow or the name needs its own line.
- **The window title is the app's name**, not the project's.

- **`AssigneeFilter.unassigned` is unreachable from the interface.** The store
  supports it and a test covers it; the menu offers only "anyone" or a person,
  because a third entry read as a synonym of the first. If "what has nobody
  picked up?" turns out to be a real question, the capability is already there.

## Wishlist

- **Conflict resolution.** iCloud conflict copies are detected and announced;
  they cannot be resolved in the app. `NSFileVersion.unresolvedConflictVersionsOfItem`
  gives the versions, dates and sizes needed to offer a choice.
- **`#file` to link a file by typing**, the counterpart of `@name`. Dropping a
  file on the text field already works; typing its name does not.
- **A generated `TODO.md`** in the project folder, so tasks are readable in
  Obsidian or the Finder. Derived, therefore safe to overwrite.
- **"Open in MarkEdit"** beside a text file. Looking at one is covered — space or
  ⌘Y hands it to Quick Look — but the app that should edit it is still whatever
  the Finder thinks. Editing stays out of this app: editing shared files is where
  conflict copies come from, and MarkEdit already does it better.
- **Quick Look is refused for a file iCloud has evicted**, because previewing it
  would download it. The row says so with a cloud icon and "Open" still works.
  Offering the download as a choice would be better than refusing quietly.
- **An editor inside the app.** Parked deliberately. See the workflow review for
  why it is a different product.

## Lessons that cost a day

Kept because each of them was invisible while it was happening.

- **A build can succeed and ship nothing.** `actool` dropped an entire icon set
  because the PNGs were twice their declared size, and said so only in a warning
  nobody was reading. Both apps shipped iconless. The renderer now asserts its own
  output dimensions.
- **A test can exercise the wrong branch.** `URL.resolvingSymlinksInPath` strips a
  leading `/private`, so the integration tests ran against a `/var` symlink and
  took a path the app never takes. A real bug — folders finding none of their own
  files — hid there behind a green suite.

## Not verified

- **The two-machine case has never run on two real Macs.** Tests run two
  engines with separate indexes on one folder, and `macbench-peer` plays a second
  Mac against the real app (see testing.md), but never across iCloud. The things
  that can only fail there: how long a log segment takes to arrive, whether a
  `.icloud` placeholder ever appears for a file that small, and whether
  authorship survives a machine being closed for a day. The two-Mac section of
  the release checklist in testing.md is the stand-in until then.
- **The live FSEvents path has only a few tests**, which wait on real events
  with a timeout: a file seen in the first session, deletions, a folder leaving,
  a file arriving from the other Mac. Most of its logic is shared with the
  catch-up path, which is covered thoroughly.
