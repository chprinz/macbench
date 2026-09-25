# Backlog

Everything noticed along the way that is not done. Kept here rather than in
someone's head. Newest observations at the top of each section.

## Gaps against the specification

- **Sidebar indentation** is whatever SwiftUI's `DisclosureGroup` does, not the
  twelve points the spec asks for.
- **Foundation Models** — natural-language search and the weekly review. Marked
  optional in the spec and deliberately deferred. The query layer they would
  drive already exists.
- **Projects cannot be reordered** although `sortIndex` is there; they sort by
  when they were added.

## Rough edges

- **Which filters are remembered is a judgement call, not a setting.**
  Categories, "without file changes", the sidebar's tree filter and the task
  list's person come back; "Done" deliberately does not, because it would open
  the app on a list that is empty for a reason set days ago. The person used to
  be left out for the same reason, and the first bug report said "only mine" is
  how people work, not something they look up once.
- **Verbosity is settable in two places**, the project's context menu and
  Settings. One of them should go.

## Technical

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
