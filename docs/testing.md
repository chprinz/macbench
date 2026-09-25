# Testing

What is tested automatically, how to try the two-Mac cases on one Mac, and what
still needs two real Macs and a person looking before a release.

## Before you push

```bash
./test.sh          # what CI runs: core tests, app build, strings, icon
./test.sh --core   # the core tests alone, in a few seconds
```

CI (`.github/workflows/ci.yml`) runs the same on every push to `main` and every
pull request: the core tests, a Release build of the app, a check that every
string has a German version, and a check that the icon made it into the built
app — a build can succeed and ship without one, and once did.

## What the automated tests cover

Everything in `MacBenchCore`, which is everything that decides what a person
sees: the log format, the index, the watcher's rules, who gets named for a
change, and two machines reading each other. The table of test files is in
[development.md](development.md#tests). Several suites drive the real engine
against a real temporary folder, with real FSEvents, and `SecondMacTests` runs
two engines with separate indexes on one folder.

The app target has no tests of its own. That is deliberate — it holds no rule
worth testing — and it is also why the manual pass below exists: the app is
where a correct core can still be shown wrongly.

## A second Mac on the command line

`macbench-peer` plays another Mac against a folder: its own index, its own
person, its own device folder in `.macbench`, and the same engine the app runs.
With it, the cases that need a second person can be tried against the real app
on one Mac.

```bash
cd MacBenchCore
swift run macbench-peer sample ~/Desktop/Bench-Test
```

1. Add `~/Desktop/Bench-Test` in the app (⇧⌘O).
2. Let Ben join, and keep him listening:

   ```bash
   swift run macbench-peer watch ~/Desktop/Bench-Test
   ```

   The app shows that Ben is now in the project — and nothing about the files
   that were already there. Write something in the app; it appears in the
   terminal within a second.
3. From a second terminal, have Ben give you a task on a file:

   ```bash
   swift run macbench-peer say ~/Desktop/Bench-Test "@YourName check the dates?" --task --file Brief/brief.txt
   ```

   It lands on the file, under Tasks, for you, with a notification.
4. The rest:

   ```bash
   swift run macbench-peer tick ~/Desktop/Bench-Test dates           # Ben ticks it off
   swift run macbench-peer rename ~/Desktop/Bench-Test Benjamin      # a new name travels
   swift run macbench-peer show ~/Desktop/Bench-Test                 # what Ben's Mac sees
   swift run macbench-peer say ~/Desktop/Bench-Test "hi" --as Lena   # a third person
   ```

When you are done, remove the project in the app, delete the folder, and
`swift run macbench-peer reset` (and `--as Lena` for each other name used).

Three things it cannot tell you:

- **Who gets named for a file change.** It watches files only with `--files`,
  and on the Mac the app runs on both would see every change as their own.
  Attribution needs two real Macs.
- **Anything iCloud does.** No placeholders, no download delays, no last-editor
  names, no conflict copies. The folder is just a folder.
- **Anything about a real project.** Use a throwaway folder: whatever the peer
  writes stays in that folder's history, exactly as a real Mac's would.

## Before a release: the manual pass

Grouped by how much would go wrong unnoticed. Each line is something the code
promises and no automated test sees end to end.

### First run

- [ ] On a fresh macOS user (or with the app's container moved aside, which
      forgets this Mac's index and identity, not any folder's history):
      onboarding asks for a name, a folder, and login.
- [ ] Picking a subfolder of a folder that already has a history offers the
      whole project instead.
- [ ] Existing files are indexed without entries; the only line is who joined.
- [ ] With *Start at login* on: after logging out and in, the app runs with no
      window and no Dock icon, and opening it from Spotlight brings the window.

### One Mac, every day

- [ ] Save a text file twice: the pending bar shows it at once, one line with
      `+n −n` appears after the twenty-minute window.
- [ ] Add, rename, move, delete a file: each is a line within about half a minute.
- [ ] Delete a file, then rename another one to its name: nothing stops, and the
      file under that name keeps what was said about it.
- [ ] Drag a folder with files in it to the Trash: its files no longer turn up in
      search.
- [ ] Save a Pages or Keynote document: one line about the document, nothing
      about its insides.
- [ ] A cache folder (Resolve's `CacheClip`, Premiere's `Media Cache`) never
      shows up.
- [ ] Message, task, `@name`, reply, edit, delete, categories — in the stream
      and in the task list.
- [ ] Quick note (⌃⌥⌘N) from another app, with `@name` in it: it is for that
      person.
- [ ] Space and ⌘Y preview the picked file; a file iCloud has evicted shows the
      cloud icon and is not downloaded.
- [ ] Change an image or PDF: its thumbnail in the file list follows.
- [ ] Search finds a file by something written about it.
- [ ] Quit (⌘Q) while a change is still being gathered: after relaunch it is in
      the list.
- [ ] Rename the project folder in the Finder: a banner says so, rather than the
      project going quiet.
- [ ] Unplug the drive a project is on, or rename it away: writing into that
      project keeps the text in the field and beeps; nothing claims to be saved.
- [ ] With the system language set to German, no English is left anywhere.

### Two real Macs, over iCloud

The part no test can reach. Worth doing properly once per release.

- [ ] The second person adds a folder that already has a history: no file
      changes on either Mac, one line each saying who joined.
- [ ] A message and a task from each side arrive; a task for you notifies you,
      a file change never does.
- [ ] A file saved on one Mac appears on the other once, with the right name.
- [ ] Work done while one Mac's app was closed: once it runs again, the other
      Mac shows it with the right name, or honestly as unknown — never with the
      wrong one.
- [ ] Both save the same file at the same moment: the conflict copy is announced.
- [ ] Rename yourself in Settings: the other Mac shows the new name, and still
      does after a minute.
- [ ] One Mac asleep for a day, then woken: the sidebar says it is loading
      changes, then that everything has arrived; no warning is left standing.
