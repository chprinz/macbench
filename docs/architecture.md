# Architecture, and where it departs from the specification

The app began as a short specification for two people sharing client folders
over iCloud; it is not kept in the repository, and "the spec" below means that.
This is what was built, and — more usefully — the places where the
implementation deliberately does something else, with the reasoning.

## Layout

```
Branding/         the app icon and accent colour, and nothing else
tools/            icon rendering, string catalog upkeep
MacBenchCore/     everything that can be tested without a window
  Model/          the domain: member, node, entry, category
  Log/            the on-disk record format, its writer and its reader
  Store/          the local SQLite index and every query the UI makes
  Watch/          FSEvents, exclusion rules, coalescing, authorship, line counts
  Ingest/         the engine that wires those together, and peer syncing
  Export/         Markdown
  macbench-peer/  a second Mac on the command line, for testing (docs/testing.md)
App/              SwiftUI, and only SwiftUI
```

The split is not decoration. Every rule that decides *what a person sees* lives in
the package and is covered by tests; the app target contains no logic worth
testing. The tricky parts of this app cannot be reproduced by clicking around on
one Mac, so they had to be reachable from a test.

## Departures from the specification

### CloudKit was replaced by a log inside the project folder

**Spec:** SwiftData with CloudKit, shared through CKShare.

**Built:** each device appends to its own JSONL file under `.macbench/` inside the
project folder, and that folder rides on whatever sync is already in use.

Three reasons. iCloud entitlements require a paid Apple Developer membership, so
CloudKit would have made the app unbuildable for anyone who cloned it — and for
the two people it was first built for, who have no membership either. Second, CloudKit would have been a *second*
sync channel alongside the one already carrying the files, and two channels can
disagree; one channel cannot. Third, the log is a readable, portable format, which
is most of the export requirement satisfied for free.

The consequence: SwiftData lost its reason to exist (it was there for CloudKit), so
the index is SQLite through GRDB. That buys WAL concurrency for a writer that runs
while the UI reads, and predictable behaviour under a schema that will change.

Everything sync-related sits behind `PeerSync` and `DeviceLogWriter`. A CloudKit
transport can be added beside them without touching the rest.

### A change nobody can attribute is still recorded

**Spec:** an entry is created only by the machine the change happened on.

**Built:** that rule holds whenever the machine that made the change is running.
When it is not, the receiving machine records the change with **no author** rather
than not recording it, and the entry heals into the right author as soon as that
machine's log arrives.

The spec's rule, taken literally, has a hole: if one person's app is closed while
they work, nothing they do is ever recorded by anyone. That is precisely the
"silent gap" the spec calls the worst failure. An entry that says "changed —
author unknown" is honest; a missing entry is not.

Convergence is guaranteed because both machines resolve duplicates with the same
rule, using only facts both of them have: a known author beats an unknown one,
then the file's own modification date, then the entry id. Local timing is
deliberately not consulted — it differs per machine, so it would produce different
verdicts and the duplicate would come back.

### Changes that look like they arrived are held briefly before being written

A change with no attributable author waits ten minutes before being recorded
without one. In the normal case the other machine's log arrives inside that
window, and no nameless entry is ever written. On quit, everything pending is
flushed rather than dropped.

### An extra signal for authorship, and an inference for gaps

Beyond the download-status keys the spec names, the watcher notices when a hidden
`.name.icloud` placeholder disappears immediately before the file itself appears.
That is sync materialising a file and nothing else, and it is the strongest signal
available.

For changes nobody watched happen, there is one inference: a machine that was
running would have recorded its own user's edit, so a machine that was awake and
stayed silent can be ruled out. Devices publish their awake stretches in their
manifest. If exactly one candidate remains, the change is attributed to them;
otherwise it stays unattributed. This is used at start-up only — after a dropped
event batch, our own presence proves nothing, because we were demonstrably running
and still missed it.

### iCloud's last editor, where nobody watched

In a folder shared through iCloud, every file carries the name of whoever last
saved it — kept by iCloud, whether or not anybody's app was running. For a
created or saved file whose author the watching could not establish, that is
the evidence used, ahead of the awake-window inference: a name is matched to one
of the people in the folder (full name, first name, or the start of either; with
one other person, any other name is theirs), and no name means the person at
this Mac.

"No name" is only believed where it cannot be a leftover: for a change nobody
watched happen, or one that has waited out the full ten minutes for its author's
log — not when quitting cuts the wait short — and only for a file that has
finished syncing. Seen live, a file arriving from the other Mac can still carry
the previous editor, and while a new version is still arriving iCloud can leave
the name out altogether; believing either would put the name of the person here
on the other's work. That happened once, on a Pages document the other person
was saving every few minutes.

A save this Mac took for its own is overridden by a name only once the change is
five minutes old. Before that, iCloud may still show whoever saved it last time,
because our own upload is not through; after it, a different name means the
impression was wrong — which it can be for a document package, since a package
reports no download of its own and a save arriving from the other Mac can look
like one made here.

A document package is never taken for ours on its date alone, in a shared
folder. It reports no download of its own, so a Pages document the other person
created a minute ago looks exactly like one saved here; that put this Mac's name
on their documents. Only an upload is proof. Otherwise it waits like anything
else that may have arrived, and iCloud's last editor decides.

Moves, renames and deletions are not asked about: the last editor says who
changed the contents, not who moved the file, and a deleted file is not there to
ask.

Both Macs read the same editor from iCloud, each from its own side, so two
records of one change carry the same author and the duplicate resolves as
before.

### A deletion waits for its author

A vanished file leaves nothing to inspect: sync removing it looks exactly like
somebody deleting it here. Deletions used to be claimed by whichever Mac saw
them, which put one person's name on the other's work — or on a document whose
copy on this Mac simply had not caught up.

So a deletion is held like any other change that may have arrived: ten minutes
for the other Mac's log to claim it, matched on the file rather than the dedup
key, because each Mac only knows when the file vanished from its own disk. If
nobody claims it, the awake-window inference decides; with nobody else in the
folder, it is ours at once. A deletion found in history replayed after a restart
happened while nobody here watched and stays nameless, marked reconstructed.

A move waits the same way. Sync carries out the other Mac's move on this disk
exactly as a move made here — same file, new place — and claiming every move
seen live put this Mac's name on a folder the other person had moved. It is
matched on the file and on when it was seen, since a move leaves the file's own
date alone.

A file this Mac never had under that name — known only from a peer's log, or
renamed there and not yet here — is not deleted when it is missing. The node's
local file identity marks the difference: it is set when this disk is seen to
have the file, and dropped when a peer renames it.

### Opening a file is not changing it

Opening a document touches it: the system notes when it was last used, iCloud
updates its bookkeeping, and each of those is a filesystem event. A file already
in the index only counts as changed when its date or size moved — the same test
the catch-up comparison uses. Without it, opening the other person's Pages
document went down as an edit by whoever opened it.

### Loud events settle for thirty seconds

**Spec:** created, deleted and moved are loud and always appear.

They do appear, after half a minute of quiet. Many applications write a scratch
file and delete it moments later; without the delay, every one of those becomes a
"file added" line. A file created and removed inside one window is treated as
never having existed.

### Somebody joining is an entry, not a notification

**Spec:** the first look at a folder is silent — everything already in it is
indexed without producing a single line.

It still is, about files. The one line a first index does produce says who just
joined. An entry rather than a notification on purpose: a notification that gets
wiped away is gone, and "since when is she in this?" is a question asked weeks
later, in the stream, where the answer has to be. It is also the only system entry
verbosity cannot mute — muting is about the churn of a shared folder, and a person
arriving is not churn.

The line is not written into the log as a sentence. A sentence would travel in the
language of whoever joined and be read by somebody in another one, so the entry
carries a structured `notice` and every reader builds the words itself. The
sentence is written into `text` as well, in English, as what a version that
predates notices will show instead of an empty line.

Two Macs, one person: both index the folder for the first time and both have the
same true thing to say. They fold together on a dedup key built from the member
id — a fact both machines have — and the earlier of the two survives, on both
machines independently. Dedup keys are matched inside the project now: a key built
from a node is unique anywhere, because node ids are salted apart across projects,
but a key built from a person is not. Joining two folders is two facts.

### Node identity is derived, not assigned

Two machines must agree on which file an entry refers to, without asking each
other. A node's id is a version-5 UUID derived from the path it was first seen at,
so both machines compute the same one. Inodes differ between Macs and stay local.

When a rename happens before the second machine ever indexed the file, the two do
mint different ids — the older registration wins, on both machines independently,
and the loser becomes a redirect so entries already written against it still
resolve.

### The middle column is the list you came for, not always the files

**Spec:** the column beside the tree shows the files of the selected folder, and
under them the history of everything in it.

**Built:** that holds for a project or a folder. The two lists that span projects
— every task, everything that has happened — put *themselves* there instead, and
the column beside them becomes the conversation around the line you pick.

The spec's shape assumes the question is always "which files". For tasks it is
not: a task's file is one of its details, and listing files meant opening each one
to find out which task was yours. For the activity list it is not either: the
reading is the point, and it was happening in a 320-point inspector while the
widest column answered the side question.

One rule covers all three now — middle: the list; right: the conversation about
the line picked in it — which is fewer rules than the exception it replaced, and
one query fewer: the cross-project file lists had no caller left.

### A document package is one file

A `.pages`, `.key` or `.fcpbundle` is a folder on disk. Watched as one, a single
save became a dozen lines about `Index.zip` and `preview-micro.jpg`, mostly with
nobody's name on them: Pages keeps the original dates of the images it copies in,
and a file with an old date looks like it arrived through sync.

Packages are recognised by extension (`DocumentPackage`), never by asking the
filesystem — both Macs have to agree on what a node is, and a package iCloud has
not downloaded cannot answer. Everything inside is folded into the package: one
node, one change per save, dated by the newest file in it. Indexes and peer logs
from before this are folded on start and on read: what they say about a file
inside becomes "the document changed", keyed into the same twenty-minute bucket so
one save is one line. A file vanishing from inside is dropped rather than folded —
that is what made a Mac whose copy had not caught up read as somebody deleting
images. The ids a peer used for files inside are remembered in `packageInterior`,
so its entries about them are recognised instead of turning into placeholder files.

### Search is substring, not token-based

Full-text indexes match token prefixes: searching "plakat" would not find
`Sommerplakat_final`. For file names that is the wrong trade. Search runs over a
normalised column (lower-cased, accents folded) so that "grussformel" finds
"Grußformel", and matches anywhere in the string.

### Not built

The optional Foundation Models features — natural-language search and the weekly
review — are not implemented. They are additive: the search filter and the
timeline query they would drive already exist.

## The failure this design is built around

Sync being late must never look like nothing having happened.

- Every device's manifest carries its highest sequence number. If the segments on
  disk do not reach it, the app reports the gap instead of showing less.
- A watermark never advances past a hole, so missing records are re-read when they
  arrive rather than skipped forever.
- A segment that is an iCloud placeholder is reported as "waiting", and a download
  is requested.
- A half-written final line is tolerated (a segment mid-upload legitimately looks
  like that); a broken line anywhere else is reported. The writer cuts one off its
  own last segment before appending, so a crash mid-write never becomes one.
- A device's own numbering comes from its segments as much as its manifest. A
  manifest that is gone or broken is rebuilt from them; one that is there but
  cannot be read (evicted, offline) stops the writer rather than letting it count
  from one again below where the others already are.
- A devices folder that cannot be listed is reported, not read as an empty one.
- A record this Mac cannot write to its log waits in a queue beside the index,
  with the time it happened, and goes first on the next write that works.
- A project whose index is empty — added again, or rebuilt — reads this Mac's own
  log back once, up to where it stood, so the rebuild covers both halves. Who this
  Mac is lives in `identity.json` beside the index, not in it, so a rebuilt index
  keeps the person and the device id that the own log is found by. Which folders
  it watches is mirrored into `projects.json` beside it too, and put back when
  the index comes up with no project at all.
- A project that could not be started — its own log not here yet, its drive not
  mounted — is tried again every minute and on waking, not left until the next
  launch.
- FSEvents replay is only trusted while the volume's event-history UUID matches
  the one stored. When it does not, the whole folder is compared instead, and
  everything that comes out of that comparison is marked as reconstructed with an
  approximate time.
