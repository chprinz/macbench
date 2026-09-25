# Working on this

Practical notes for the next person, including the next version of whoever wrote
it. The architecture is in [architecture.md](architecture.md); this is the
mechanics, and the short list of things that must not be broken.

## Everyday commands

```bash
./build.sh                    # MacBench, Debug
./build.sh MacBench Release   # what gets installed
./test.sh                     # everything CI checks, before you push
cd MacBenchCore && swift test # the core test suite on its own, no GUI needed
```

The Xcode project is generated from `project.yml` and is not in the repository.
`build.sh` regenerates it every time, so adding a file needs no project surgery —
put it under `App/` or `MacBenchCore/Sources/` and build. To work in Xcode, run
`xcodegen generate` and open `MacBench.xcodeproj`.

The build number is the commit count, set by `build.sh`. The marketing version
lives in `project.yml` under `MARKETING_VERSION`.

## A build of your own

The app target is a template in `project.yml`, so a build under another name,
bundle identifier and icon is configuration rather than a fork. Put it in
`project.local.yml`, which git ignores and `build.sh` picks up when it exists:

```yaml
include:
  - project.yml

targets:
  StudioBench:
    templates: [App]
    templateAttributes:
      productName: Studio Bench
      bundleID: com.example.StudioBench
      brandFolder: StudioBench
```

Its icon and accent colour go in `Branding/StudioBench/Assets.xcassets` (also
ignored — only `Branding/MacBench` is committed), and `./build.sh StudioBench`
builds it. Every build reads and writes the same `.macbench` format, so people on
different builds can share a folder.

The name comes from the bundle at runtime through `Brand.name`, so it does not
belong in a string. Keep user-facing sentences free of the product name where
they can be. Most read better without it: "Lost access to “Kunde Meier”" beats
"MacBench lost access to …".

## Icons

```bash
swift tools/make-icon.swift Branding/MacBench/Assets.xcassets/AppIcon.appiconset E4572E bench
# a monogram on the same plate, for a build of your own
swift tools/make-icon.swift Branding/StudioBench/Assets.xcassets/AppIcon.appiconset 2E86AB sb
```

The script draws into a bitmap of exact pixel dimensions and refuses to write a
file whose size does not match its slot. That check exists because it was once
missing: `NSImage.lockFocus()` draws at the screen's backing scale, every file
came out at twice its declared size, `actool` dropped the entire icon set, and
the app shipped with no icon while the build reported success. If you change the
renderer, keep the assertion. CI checks the built app for the icon as well.

To check an icon actually made it into a build:

```bash
xcrun assetutil --info build/Build/Products/Release/MacBench.app/Contents/Resources/Assets.car | grep AppIcon
```

## Adding a string

Every user-facing string is English in the source and German in
`App/Resources/Localizable.xcstrings`. After building:

```bash
python3 tools/sync-strings.py build            # lists anything untranslated, exits 1
python3 tools/sync-strings.py build --prune     # also drops strings no longer used
```

CI runs the check, so a string without a German version fails the build rather
than shipping as English text in a German interface.

A string with a number in it needs both forms in both languages — "1 Datei", not
"1 Dateien". They live in the catalog under `variations` (the whole sentence
changes) or `substitutions` (only part of it does, which is what a sentence with
two numbers needs); the check reads either. Nothing in the source changes: write
`"\(count) files"` and let the catalog decide. `(s)` in a string is the tell that
this was skipped.

## Adding a database migration

`Store.migrator` in `MacBenchCore/Sources/MacBenchCore/Store/Schema.swift`.
Register a new migration; never edit an existing one — someone is running the
version you would be rewriting. The index is rebuildable from the logs, so a
migration that only recomputes derived columns is always safe.

## Things that must not be broken

These are the load-bearing decisions. Each has a test; if you find yourself
arguing with one, read the test first.

- **No file is ever written by more than one machine.** Every device writes only
  `.macbench/devices/<its own id>/`. This is what makes the whole thing
  conflict-free on top of any file sync. A shared file that both machines edit
  would reintroduce exactly the conflict copies the app is meant to warn about.
  A Mac made from another one's backup would share its device id; the identity
  records the hardware it was made on, and a copy on other hardware becomes a
  device of its own (`LocalIdentity.claimed`).
- **Duplicate resolution may only use facts both machines have.** A known author
  beats an unknown one, then the file's own modification date, then the entry id.
  Never `observedAt` — it is local, so the two machines would reach different
  verdicts and the duplicate would come back.
- **`Namespace.node` and `Namespace.category` never change.** Node ids are derived
  from them; changing either re-mints every id in every existing log and detaches
  history from its files.
- **The log folder is called `.macbench` in every build.** It is the data
  format, not a brand.
- **Absolute paths and security-scoped bookmarks stay local.** They contain the
  account name and are bound to one Mac. `projects.json` holds them, and lives in
  Application Support beside the index, never in a project folder.
- **The index is the only thing that may be lost.** Who this Mac is
  (`identity.json`) and which folders it watches (`projects.json`) live beside
  it, because a broken index is deleted and rebuilt from the logs, and the logs
  cannot say either.
- **Read state and verbosity are personal.** One person muting a project must not
  mute it for the other.
- **Never trigger an iCloud download to draw something.** Check
  `isMaterialised` first; a preview is not worth pulling a 4 GB video over a
  tethered connection.
- **A watermark never advances past a gap.** Missing records are re-read when
  they arrive; skipping them loses them for good.

## Tests

How to test, and what cannot be tested automatically, is in
[testing.md](testing.md). In short: `./test.sh` runs what CI runs, and
`swift run macbench-peer` plays a second Mac against the app on this one.

`MacBenchCore/Tests`, all runnable without a window:

| | covers |
|---|---|
| `LogTests` | the record format, segment rotation, gap detection, partial tails, failed writes |
| `WatchTests` | exclusion rules and coalescing |
| `StoreTests` | authorship resolution, history through moves, filters, editing, mentions |
| `SyncTests` | the two-machine cases, the authorship inference, records that cannot be applied |
| `DigestTests` | folding a file's changes into one line a day |
| `PackageTests` | document packages as one file, and folding older indexes into them |
| `RemovalTests` | who deleted a file, with and without the other Mac awake |
| `EngineIntegrationTests` | the real pipeline against a real folder |
| `SecondMacTests` | two engines on one folder: joining late, arrivals, renames, trashed folders |

The integration tests use a canonical temp path on purpose:
`URL.resolvingSymlinksInPath` strips a leading `/private`, which left an earlier
version of them exercising a code path the app never takes — and a real bug hid
there for a day.
