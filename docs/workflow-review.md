# Workflow review

Walking the five things this app is for, looking for what is unnecessary,
confusing, or simply too much work.

## 1. Open it in the morning and see what happened

Sidebar → **Latest activity** → the list fills the middle column, oldest first,
with a line marking where you stopped last time. Picking a line puts the
conversation it belongs to on the right, with the field to answer it.

**What was wrong:** the same word appeared three times. "New" was the sidebar
entry, the middle column's title, and the stream's title, which reads like a
rendering bug rather than a hierarchy. And "New" and "Open" are adjectives with
no object — new *what*, open *what*?

**Fixed:** the two lists are named after what they contain. The stream has no
title at all: the middle column already says where you are. Both sidebar rows
carry a tooltip saying what they collect.

**Then renamed again, and rebuilt.** "Unread" promised a personal inbox, which is
what this app already calls a message *to you* — a task assigned to you, a reply
to your entry. Most of what landed in that list was a file moving, addressed to
nobody. And a list defined by what you have not read empties itself as you read
it: it needed a "since I opened this" timestamp just to stay still long enough to
be read.

So the list is **everything that has happened**, across every project, in order —
your own entries included, read ones included. Unread survives as what it always
was everywhere else: a mark. The number on the sidebar row, the bar on the row,
the line, and the list opens at the first thing you have not seen.

**Also fixed on the way:** the stream used to think your own entries were unread
and drew a bar beside them until you scrolled past. The dots in the tree and the
counts in the file lists never counted them. Now nothing does.

**And the column it reads in.** This view used to put the files something
happened to in the widest column and the reading in a 320-point inspector. It was
the only view where the main column answered the side question. Now the middle
column is the list you came for — files in a folder, the tasks, or the activity —
and the right column is the conversation about the line you picked there.

**Still open:** an entry cannot be marked unread again.

## 2. Say something about a file

Find the folder in the tree, click the file in the middle column, type on the
right. Selecting a file attaches it automatically, so the note lands on the file
rather than on the project.

**What was wrong:** clicking a file swapped the whole right-hand side for a
different layout, and the sidebar lost its highlight because a file and a folder
shared one selection.

**Fixed:** they are separate now. The file list stays put, the file you clicked
stays visible among its neighbours, and a pill above the stream says which file is
narrowing it, with an × to get back out.

**Still open:** the composer lives inside the stream, so hiding the stream also
hides the only way to write. The quick note window is the workaround, and it is
not obvious.

## 3. Turn something into a task, and tick it off later

Type, tick the box beside the field, optionally pick who it is for, send. Ticked
off from the checkbox in the entry itself, or from **Tasks** in the sidebar —
which is a list of tasks now, grouped by the person each one is for with yours at
the top, and not a list of the files tasks happen to hang on. Open and ticked-off
are two halves of one switch above it; "Done" used to be a filter that could
never return anything, because the list underneath it had already excluded
everything done.

**What is weak:** the box that makes a message a task is an unlabelled icon
button. It is the whole difference between a remark and a commitment, and nothing
says so. It deserves a label, or at least a much clearer symbol.

**What is missing:** typing `@name` and `#file` in the text. Both fields already
exist on an entry; only the shortcut for reaching them is missing. That is the
part of the "todo.md" idea worth building — see the backlog.

## 4. Find a file because somebody talked about it

The search field covers file names, folder names and every word anyone wrote.
This is the one thing the Finder cannot do, and it works.

**What is wrong:** search results replace the middle column while the stream on
the right still shows the previous selection, so the window is showing two
unrelated things. Search should either take over the whole window or open a
result properly.

## 5. Set it up for the first time

Onboarding asks three things: who you are, which folder, whether to launch at
login. The folder is indexed silently.

**What was wrong:** after setup the app looked broken. The index is silent by
design and quiet changes are gathered for twenty minutes, so for the first
twenty minutes there is nothing at all, and nothing said why.

**Fixed:** changes that are being gathered are listed under the stream with a
countdown, and the empty state says the index started empty.

## What the first screenshot showed

Four things that no amount of reading the code would have caught:

- **The Unread row had no icon.** `circle.badge.fill` is not a symbol that exists,
  and SwiftUI draws nothing rather than complaining. The row sat there looking
  half-rendered next to Tasks, which has one.
- **`+0 −0`** appeared on a change where no line changed — true of any resave of a
  text file, and a number that tells you nothing is worse than no number.
- **The composer's new Task label truncated to "Aufg…"**, because its controls
  shared a row with the text field in a 320-point column. Labelling the control
  and then cutting the label in half is worse than the bare icon it replaced.
- **"No files in this folder" filled the widest column of the window.** In a
  structure where everything lives one level down — "1. Konzept & Planung",
  "2. Besprechung & Kommunikation" — the project root is always empty, so the
  largest area of the app was permanently reporting nothing while the stream was
  squeezed into a third of the width beside it.

And one about wording: **"…changed X — author unknown"** put the honest part at
the end of a line that had already run out of room, pushing the file name into an
ellipsis. It now reads "Someone changed X", the same sentence shape as a named
change, with the explanation in the tooltip.

## Two ways to say the same thing

The screenshot shows a category called **Todo** alongside a task checkbox. That is
not a mistake, it is a symptom: the checkbox was an unlabelled square, so the
category system got used for what the checkbox is for. Now that it says Task, the
overlap should ease — but it is worth watching. If people keep making a "Todo"
category, the checkbox still is not carrying its weight.

The same screenshot had a task whose text was `@Mara durchschauen`, where the @
did nothing and the field it should have filled sat in a menu two controls away.
It works now, and it works whether or not the box is ticked — because the field
was never "who is responsible", it was "who is this for", and the notification
rule had never asked whether the entry was a task. The checkbox decides which
reading applies: ticked it is work, unticked it is a heads-up.

## Unnecessary elements

- **The sidebar filter** (All / With unread / With tasks) duplicates the two rows
  directly above it. With four projects it earns nothing. It comes from the
  specification and should probably only appear once a project list is long
  enough to need it.
- **The status filter** in the stream (Everything / Open tasks / Done) overlaps
  with the **Tasks** row in the sidebar. Narrowed since: the task list has its own
  switch, so this one is only the folder stream's now.
- **Verbosity in two places**, the context menu and Settings.

Each of these is defensible alone. Together they are three ways to answer the
same question, in three different corners of one window.

## Simplifications worth making

**Visually.** Long file names lose their middle in a 340-point stream —
`erstgesp…age-v2.md` where the interesting part is the version. The stream can be
widened, but the default should probably not be a width where every file name is
unreadable. Less pressing since the morning reading moved to the wide column;
still true for the conversation beside it.

The window title says "MacBench" while the column beside it says which project
you are in. The title bar is the one place with room for the project name.

**Technically.** Two things stand out, both in the backlog: every database change
re-runs every query including a full rebuild of the folder tree, and
`Selection.node` means either a file or a folder so half a dozen call sites have
to ask which. Neither hurts at this size. Both will.

**Removed already:** the per-row author lookup in the file list ran one query per
file; it is now part of the same statement. A fixed-length truncation of file
names has been dropped in favour of letting the layout decide — the names carry
meaning and there was usually room. And the file list under the two
cross-project views is gone entirely: both of them list what they are about now,
which left `filesWithActivity` with no caller and took sixty lines of SQL with
it.

## What is deliberately not here

An editor. What was asked for is "markdown, but easy even if you do not know
markdown" — and a markdown editor is precisely the thing that requires knowing
markdown. What makes a task list easy is a checkbox you click, a list that
continues itself, and `@` opening a list of people. That is a structured task
view whose storage happens to be text, not a text editor. Building the editor
first would be building the hard half of the wrong thing.
