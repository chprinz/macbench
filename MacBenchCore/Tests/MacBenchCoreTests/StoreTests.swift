import Foundation
import Testing
@testable import MacBenchCore

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private struct Fixture {
    let store: Store
    let project: Project
    let anna: Member
    let ben: Member

    init() throws {
        store = try Store()
        project = Project(id: UUID(), name: "Kunde A", addedAt: t0)
        try store.addProject(project, rootPath: "/tmp/Kunde A", bookmark: nil)
        anna = Member(name: "Anna", colorHex: "#E4572E")
        ben = Member(name: "Ben", colorHex: "#2E86AB")
        try store.upsert(member: anna, at: t0)
        try store.upsert(member: ben, at: t0)
        try store.ensureBuiltInCategories()
    }

    @discardableResult
    func node(_ path: String, isDirectory: Bool = false, at date: Date = t0) throws -> Node {
        let node = Node(id: Namespace.nodeID(firstSeenPath: path), projectID: project.id,
                        relativePath: path, isDirectory: isDirectory,
                        firstSeenAt: date, lastSeenAt: date)
        try store.upsert(node: node)
        return node
    }

    func systemEntry(node: Node, author: UUID?, type: FileEventType = .modified,
                     at date: Date = t0, id: UUID = UUID()) -> Entry {
        Entry(id: id, projectID: project.id, nodeID: node.id, authorID: author,
              createdAt: date, observedAt: date, kind: .system, text: "",
              event: FileEvent(type: type),
              dedupKey: DedupKey.make(nodeID: node.id, event: type, at: date))
    }
}

@Suite("Store: authorship and duplicates")
struct AuthorshipTests {

    @Test("The same change witnessed by both machines stays one entry")
    func rejectsDuplicate() throws {
        let f = try Fixture()
        let node = try f.node("Layout/plakat.afdesign")
        let mine = f.systemEntry(node: node, author: f.anna.id)
        #expect(try f.store.merge(entry: mine) == .inserted)

        // The other Mac wrote its own record for the identical change. Which of
        // the two ids survives does not matter; that only one does, does.
        let theirs = f.systemEntry(node: node, author: f.anna.id)
        let outcome = try f.store.merge(entry: theirs)
        #expect(outcome != .inserted)
        let timeline = try f.store.timeline(scope: .project(f.project.id), viewer: f.ben.id)
        #expect(timeline.count == 1)
    }

    @Test("An entry with an unknown author heals when the real one arrives")
    func healsUnknownAuthor() throws {
        let f = try Fixture()
        let node = try f.node("Layout/plakat.afdesign")
        // Ben's Mac saw the file change arrive through sync while Anna's app was
        // closed. It records the change but does not claim to know who did it.
        try f.store.merge(entry: f.systemEntry(node: node, author: nil))
        var timeline = try f.store.timeline(scope: .project(f.project.id), viewer: f.ben.id)
        #expect(timeline.count == 1)
        #expect(timeline[0].author == nil)

        // Anna opens her app; her log arrives.
        let authored = f.systemEntry(node: node, author: f.anna.id)
        guard case .replacedExisting = try f.store.merge(entry: authored) else {
            Issue.record("a known author must win over an unknown one"); return
        }
        timeline = try f.store.timeline(scope: .project(f.project.id), viewer: f.ben.id)
        #expect(timeline.count == 1, "healing must not leave a second copy behind")
        #expect(timeline[0].author?.name == "Anna")
    }

    @Test("Both machines reach the same verdict regardless of arrival order")
    func resolutionIsOrderIndependent() throws {
        let idA = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let idB = UUID(uuidString: "FFFFFFFF-0000-0000-0000-0000000000BB")!

        func run(firstAuthored: Bool) throws -> UUID? {
            let f = try Fixture()
            let node = try f.node("Layout/plakat.afdesign")
            let unknown = f.systemEntry(node: node, author: nil, id: idB)
            let authored = f.systemEntry(node: node, author: f.anna.id, id: idA)
            if firstAuthored {
                try f.store.merge(entry: authored)
                try f.store.merge(entry: unknown)
            } else {
                try f.store.merge(entry: unknown)
                try f.store.merge(entry: authored)
            }
            let timeline = try f.store.timeline(scope: .project(f.project.id), viewer: f.ben.id)
            #expect(timeline.count == 1)
            return timeline.first?.entry.id
        }

        #expect(try run(firstAuthored: true) == idA)
        #expect(try run(firstAuthored: false) == idA)
    }

    @Test("Only shared facts decide the winner, never local ones")
    func resolutionIgnoresLocalTiming() throws {
        let f = try Fixture()
        let node = try f.node("a.psd")
        var early = f.systemEntry(node: node, author: f.anna.id, at: t0)
        early.observedAt = t0.addingTimeInterval(10_000)
        var late = f.systemEntry(node: node, author: f.ben.id, at: t0.addingTimeInterval(1))
        late.observedAt = t0
        // `late` was noticed first locally, but the file's own date is what counts.
        #expect(Store.preferred(early, over: late))
        #expect(!Store.preferred(late, over: early))
    }
}

@Suite("Store: history follows files")
struct HistoryTests {

    @Test("Renaming a folder keeps every entry underneath it")
    func moveKeepsHistory() throws {
        let f = try Fixture()
        let folder = try f.node("Entwurf", isDirectory: true)
        let file = try f.node("Entwurf/plakat.afdesign")
        try f.store.merge(entry: Entry(projectID: f.project.id, nodeID: file.id, authorID: f.anna.id,
                                       createdAt: t0, observedAt: t0, kind: .message,
                                       text: "Schrift bitte größer"))

        try f.store.moveNode(id: folder.id, to: "Final", at: t0.addingTimeInterval(60))

        let moved = try #require(try f.store.node(id: file.id))
        #expect(moved.relativePath == "Final/plakat.afdesign")
        let timeline = try f.store.timeline(scope: .folder(folder.id), viewer: f.ben.id)
        #expect(timeline.count == 1)
        #expect(timeline[0].entry.text == "Schrift bitte größer")
    }

    @Test("A folder's timeline includes everything inside it")
    func folderScopeIncludesDescendants() throws {
        let f = try Fixture()
        let folder = try f.node("Layout", isDirectory: true)
        let deep = try f.node("Layout/Varianten/b.afdesign")
        let outside = try f.node("Video/schnitt.drp")
        try f.store.merge(entry: f.systemEntry(node: deep, author: f.anna.id, type: .created))
        try f.store.merge(entry: f.systemEntry(node: outside, author: f.anna.id, type: .created))

        let inside = try f.store.timeline(scope: .folder(folder.id), viewer: f.ben.id)
        #expect(inside.count == 1)
        #expect(inside[0].node?.relativePath == "Layout/Varianten/b.afdesign")
    }

    /// Delete the old version, rename the new one to the old name. The deleted
    /// file still holds that path in the index, and there is one node per path.
    @Test("A file moved onto the name of a deleted one takes that name")
    func moveOntoDeletedPath() throws {
        let f = try Fixture()
        let old = try f.node("Poster.pdf")
        let new = try f.node("Poster_v2.pdf")
        try f.store.merge(entry: Entry(projectID: f.project.id, nodeID: old.id, authorID: f.anna.id,
                                       createdAt: t0, observedAt: t0, kind: .message,
                                       text: "Rand zu schmal"))
        try f.store.setNodeState(.deleted, id: old.id, at: t0.addingTimeInterval(60))

        try f.store.moveNode(id: new.id, to: "Poster.pdf", at: t0.addingTimeInterval(90))

        let poster = try #require(try f.store.node(projectID: f.project.id, relativePath: "Poster.pdf"))
        #expect(poster.id == new.id, "the file that moved there is the one at that path now")
        #expect(poster.state == .present)
        #expect(try f.store.timeline(scope: .file(new.id), viewer: f.ben.id)
                    .contains { $0.entry.text == "Rand zu schmal" },
                "what was said about that name before is kept, on the file that carries it")
    }

    @Test("A folder moved onto the name of a deleted one brings its files along")
    func folderMoveOntoDeletedPath() throws {
        let f = try Fixture()
        let gone = try f.node("Final", isDirectory: true)
        let goneFile = try f.node("Final/plakat.txt")
        try f.store.setNodeState(.deleted, id: gone.id, at: t0)
        try f.store.setNodeState(.deleted, id: goneFile.id, at: t0)
        let draft = try f.node("Entwurf", isDirectory: true)
        let draftFile = try f.node("Entwurf/plakat.txt")

        try f.store.moveNode(id: draft.id, to: "Final", at: t0.addingTimeInterval(60))

        #expect(try f.store.node(projectID: f.project.id, relativePath: "Final")?.id == draft.id)
        #expect(try f.store.node(projectID: f.project.id, relativePath: "Final/plakat.txt")?.id
                == draftFile.id)
        #expect(try f.store.files(projectID: f.project.id, parentPath: "Final", viewer: f.ben.id)
                    .map(\.node.id) == [draftFile.id])
    }

    @Test("An old node id still resolves after two machines merged it")
    func aliasRedirects() throws {
        let f = try Fixture()
        let winner = try f.node("Layout/plakat.afdesign")
        let loser = try f.node("Layout/plakat_alt.afdesign")
        try f.store.merge(entry: f.systemEntry(node: loser, author: f.anna.id, type: .created))
        try f.store.aliasNode(projectID: f.project.id, loser: loser.id, winner: winner.id)

        #expect(try f.store.node(id: loser.id)?.id == winner.id)
        let timeline = try f.store.timeline(scope: .file(loser.id), viewer: f.ben.id)
        #expect(timeline.count == 1, "entries written against the old id must still be found")
    }
}

@Suite("Store: what people see")
struct ViewTests {

    @Test("Muting the change stream is personal and only hides system entries")
    func verbosity() throws {
        let f = try Fixture()
        let file = try f.node("a.psd")
        try f.store.merge(entry: f.systemEntry(node: file, author: f.anna.id, type: .modified))
        try f.store.merge(entry: f.systemEntry(node: file, author: f.anna.id, type: .created,
                                               at: t0.addingTimeInterval(3600)))
        try f.store.merge(entry: Entry(projectID: f.project.id, nodeID: file.id, authorID: f.anna.id,
                                       createdAt: t0, observedAt: t0, kind: .message, text: "hallo"))

        #expect(try f.store.timeline(scope: .project(f.project.id), viewer: f.ben.id).count == 3)

        try f.store.setVerbosity(.majorOnly, for: f.project.id)
        let major = try f.store.timeline(scope: .project(f.project.id), viewer: f.ben.id)
        #expect(major.count == 2, "quiet changes drop out, loud ones and messages stay")

        try f.store.setVerbosity(.off, for: f.project.id)
        let off = try f.store.timeline(scope: .project(f.project.id), viewer: f.ben.id)
        #expect(off.count == 1)
        #expect(off[0].entry.kind == .message)
    }

    /// Muting is about the churn of a shared folder. Somebody arriving in it is
    /// not churn: it happens once, and it changes who the folder belongs to.
    @Test("Muting a project does not hide somebody joining it")
    func noticesAreLouderThanTheChangeStream() throws {
        let f = try Fixture()
        let file = try f.node("a.psd")
        try f.store.merge(entry: f.systemEntry(node: file, author: f.anna.id, type: .modified))
        try f.store.merge(entry: Entry(projectID: f.project.id, authorID: f.anna.id,
                                       createdAt: t0, observedAt: t0, kind: .system,
                                       text: "Anna is now in this project", notice: .joined,
                                       dedupKey: DedupKey.joined(memberID: f.anna.id)))

        for setting in [Verbosity.everything, .majorOnly, .off] {
            try f.store.setVerbosity(setting, for: f.project.id)
            let timeline = try f.store.timeline(scope: .project(f.project.id), viewer: f.ben.id)
            #expect(timeline.contains { $0.entry.notice == .joined },
                    "a notice survives verbosity \(setting.rawValue)")
        }
    }

    /// Both of somebody's Macs index the shared folder for the first time, and
    /// both have something true to say — but it is one fact, and the key that
    /// folds them together may only use what both machines have.
    @Test("Somebody's second Mac joins the same project, not a second time")
    func joiningIsSaidOnce() throws {
        let f = try Fixture()
        func joining(at date: Date) -> Entry {
            Entry(projectID: f.project.id, authorID: f.anna.id, createdAt: date, observedAt: date,
                  kind: .system, text: "Anna is now in this project", notice: .joined,
                  dedupKey: DedupKey.joined(memberID: f.anna.id))
        }
        try f.store.merge(entry: joining(at: t0.addingTimeInterval(3600)))
        try f.store.merge(entry: joining(at: t0))

        let timeline = try f.store.timeline(scope: .project(f.project.id), viewer: f.ben.id)
        #expect(timeline.filter { $0.entry.notice == .joined }.count == 1)
        #expect(timeline.first { $0.entry.notice == .joined }?.entry.createdAt == t0,
                "the earlier of the two is the one that happened")
    }

    @Test("You have already read what you wrote yourself")
    func ownEntriesAreNotUnread() throws {
        let f = try Fixture()
        let file = try f.node("a.psd")
        try f.store.merge(entry: Entry(projectID: f.project.id, nodeID: file.id, authorID: f.anna.id,
                                       createdAt: t0, observedAt: t0, kind: .message, text: "meins"))
        let annaSees = try f.store.activitySignals(viewer: f.anna.id)
        let benSees = try f.store.activitySignals(viewer: f.ben.id)
        #expect(annaSees.unreadTotal == 0)
        #expect(benSees.unreadTotal == 1)

        // And the stream says the same. It no longer leaves out what you have
        // read, so your own sentence travels through it — it must not arrive
        // wearing the mark that means "somebody said something you have not seen".
        let annaReads = try f.store.timeline(scope: .activity, viewer: f.anna.id)
        #expect(annaReads.count == 1)
        #expect(annaReads.contains { $0.isUnread } == false)
        #expect(try f.store.timeline(scope: .activity, viewer: f.ben.id)
            .allSatisfy(\.isUnread))
    }

    @Test("Marking as read is per person")
    func readStateIsPersonal() throws {
        let f = try Fixture()
        let file = try f.node("a.psd")
        let entry = Entry(projectID: f.project.id, nodeID: file.id, authorID: f.anna.id,
                          createdAt: t0, observedAt: t0, kind: .message, text: "schau mal")
        try f.store.merge(entry: entry)
        try f.store.markRead(entryIDs: [entry.id], member: f.ben.id, at: t0)
        #expect(try f.store.activitySignals(viewer: f.ben.id).unreadTotal == 0)
    }

    @Test("Something read by accident can be put back to unread, for that person only")
    func markUnread() throws {
        let f = try Fixture()
        let file = try f.node("a.psd")
        let entry = Entry(projectID: f.project.id, nodeID: file.id, authorID: f.anna.id,
                          createdAt: t0, observedAt: t0, kind: .message, text: "schau mal")
        try f.store.merge(entry: entry)
        try f.store.markRead(entryIDs: [entry.id], member: f.ben.id, at: t0)
        try f.store.markRead(entryIDs: [entry.id], member: f.anna.id, at: t0)
        try f.store.markUnread(entryIDs: [entry.id], member: f.ben.id)
        #expect(try f.store.activitySignals(viewer: f.ben.id).unreadTotal == 1)
        #expect(try f.store.timeline(scope: .activity, viewer: f.ben.id).first?.isUnread == true)
        #expect(try f.store.activitySignals(viewer: f.anna.id).unreadTotal == 0)
    }

    @Test("An archived project is out of the feed and the tasks, and back when brought back")
    func archivedProjectIsPutAway() throws {
        let f = try Fixture()
        let entry = Entry(projectID: f.project.id, authorID: f.anna.id, createdAt: t0, observedAt: t0,
                          kind: .message, text: "erledigt", isTask: true)
        try f.store.merge(entry: entry)
        try f.store.setProjectArchived(f.project.id, true)
        #expect(try f.store.timeline(scope: .activity, viewer: f.ben.id).isEmpty)
        #expect(try f.store.timeline(scope: .openTasks, viewer: f.ben.id).isEmpty)
        #expect(try f.store.timeline(scope: .project(f.project.id), viewer: f.ben.id).count == 1,
                "its own history is still there")
        try f.store.setProjectArchived(f.project.id, false)
        #expect(try f.store.timeline(scope: .activity, viewer: f.ben.id).count == 1)
        #expect(try f.store.timeline(scope: .openTasks, viewer: f.ben.id).count == 1)
    }

    @Test("A deleted message comes back when the delete is undone")
    func retractionCanBeUndone() throws {
        let f = try Fixture()
        let entry = Entry(projectID: f.project.id, authorID: f.anna.id,
                          createdAt: t0, observedAt: t0, kind: .message, text: "doch nicht")
        try f.store.merge(entry: entry)
        try f.store.apply(patch: EntryPatchRecord(entryID: entry.id, isRetracted: true), at: t0)
        #expect(try f.store.timeline(scope: .activity, viewer: f.ben.id).isEmpty)
        try f.store.apply(patch: EntryPatchRecord(entryID: entry.id, isRetracted: false),
                          at: t0.addingTimeInterval(5))
        #expect(try f.store.timeline(scope: .activity, viewer: f.ben.id).map(\.entry.text) == ["doch nicht"])
    }

    @Test("Picking a file reads its changes, not what was written about it")
    func pickingReadsChangesOnly() throws {
        let f = try Fixture()
        try f.store.setVerbosity(.everything, for: f.project.id)
        let file = try f.node("a.psd")
        let other = try f.node("b.psd")
        try f.store.merge(entry: f.systemEntry(node: file, author: f.anna.id))
        try f.store.merge(entry: f.systemEntry(node: other, author: f.anna.id))
        try f.store.merge(entry: Entry(projectID: f.project.id, nodeID: file.id, authorID: f.anna.id,
                                       createdAt: t0, observedAt: t0, kind: .message, text: "schau mal"))
        #expect(try f.store.activitySignals(viewer: f.ben.id).unreadTotal == 3)

        try f.store.markChangesRead(nodeID: file.id, member: f.ben.id, at: t0)
        let unread = try f.store.timeline(scope: .activity, viewer: f.ben.id).filter(\.isUnread)
        #expect(unread.count == 2)
        #expect(unread.contains { $0.entry.kind == .message && $0.entry.nodeID == file.id })
        #expect(unread.contains { $0.entry.nodeID == other.id })
    }

    @Test("Long-deleted files move to the archive, and their history stays")
    func archivesAfterRetention() throws {
        let f = try Fixture()
        let recent = try f.node("Layout/neu.afdesign")
        let old = try f.node("Layout/alt.afdesign")
        try f.store.merge(entry: Entry(projectID: f.project.id, nodeID: old.id, authorID: f.anna.id,
                                       createdAt: t0, observedAt: t0, kind: .message,
                                       text: "Diese Fassung war die richtige"))

        let now = t0.addingTimeInterval(200 * 24 * 3600)
        try f.store.setNodeState(.deleted, id: recent.id, at: now.addingTimeInterval(-10 * 24 * 3600))
        try f.store.setNodeState(.deleted, id: old.id, at: now.addingTimeInterval(-120 * 24 * 3600))

        #expect(try f.store.archiveDeletedNodes(olderThan: 90, now: now) == 1)
        #expect(try f.store.node(id: old.id)?.state == .archived)
        #expect(try f.store.node(id: recent.id)?.state == .deleted,
                "a file deleted last week is still one you might be looking for")

        // Out of search, but not out of the database.
        #expect(try f.store.search("alt.afdesign", viewer: f.ben.id).nodes.isEmpty)
        #expect(try f.store.search("neu.afdesign", viewer: f.ben.id).nodes.count == 1)
        #expect(try f.store.timeline(scope: .file(old.id), viewer: f.ben.id).count == 1,
                "a history is never thrown away, only put out of the way")
    }

    @Test("A retention of zero keeps everything in view")
    func archivingCanBeTurnedOff() throws {
        let f = try Fixture()
        let node = try f.node("a.psd")
        try f.store.setNodeState(.deleted, id: node.id, at: t0)
        #expect(try f.store.archiveDeletedNodes(olderThan: 0, now: t0.addingTimeInterval(9e7)) == 0)
        #expect(try f.store.node(id: node.id)?.state == .deleted)
    }

    @Test("A file is findable because someone talked about it")
    func searchFindsFileByConversation() throws {
        let f = try Fixture()
        let file = try f.node("Layout/DSC_9931.jpg")
        try f.store.merge(entry: Entry(projectID: f.project.id, nodeID: file.id, authorID: f.anna.id,
                                       createdAt: t0, observedAt: t0, kind: .message,
                                       text: "Das ist das Titelbild für die Broschüre"))
        let results = try f.store.search("broschüre", viewer: f.ben.id)
        #expect(results.entries.count == 1)
        #expect(results.entries[0].node?.name == "DSC_9931.jpg")

        // Accent- and case-insensitive, and substrings of file names work.
        #expect(try f.store.search("BROSCHURE", viewer: f.ben.id).entries.count == 1)
        #expect(try f.store.search("9931", viewer: f.ben.id).nodes.count == 1)
    }

    @Test("Wildcards typed by a person are searched for, not interpreted")
    func searchEscapesWildcards() throws {
        let f = try Fixture()
        let file = try f.node("a.psd")
        try f.store.merge(entry: Entry(projectID: f.project.id, nodeID: file.id, authorID: f.anna.id,
                                       createdAt: t0, observedAt: t0, kind: .message, text: "Rabatt 50 % zugesagt"))
        #expect(try f.store.search("50 %", viewer: f.ben.id).entries.count == 1)
        #expect(try f.store.search("%%%", viewer: f.ben.id).entries.isEmpty)
    }

    @Test("Tasks can be narrowed to the person they are for")
    func filterTasksByAssignee() throws {
        let f = try Fixture()
        try f.store.merge(entry: Entry(projectID: f.project.id, authorID: f.anna.id, createdAt: t0,
                                       observedAt: t0, kind: .message, text: "Freigabe einholen",
                                       isTask: true, assigneeID: f.ben.id))
        try f.store.merge(entry: Entry(projectID: f.project.id, authorID: f.ben.id, createdAt: t0,
                                       observedAt: t0, kind: .message, text: "Rechnung stellen",
                                       isTask: true, assigneeID: f.anna.id))
        try f.store.merge(entry: Entry(projectID: f.project.id, authorID: f.anna.id, createdAt: t0,
                                       observedAt: t0, kind: .message, text: "Irgendwer: Backup prüfen",
                                       isTask: true))

        func tasks(_ assignee: AssigneeFilter) throws -> [String] {
            var filter = TimelineFilter()
            filter.status = .openTasks
            filter.assignee = assignee
            return try f.store.timeline(scope: .openTasks, filter: filter, viewer: f.anna.id)
                .map(\.entry.text)
        }

        #expect(try tasks(.anyone).count == 3)
        #expect(try tasks(.member(f.ben.id)) == ["Freigabe einholen"])
        #expect(try tasks(.member(f.anna.id)) == ["Rechnung stellen"])
        #expect(try tasks(.unassigned) == ["Irgendwer: Backup prüfen"])
    }

    @Test("Open tasks are collected across every project")
    func openTasksAcrossProjects() throws {
        let f = try Fixture()
        let second = Project(id: UUID(), name: "Kunde B", addedAt: t0)
        try f.store.addProject(second, rootPath: "/tmp/b", bookmark: nil)
        try f.store.merge(entry: Entry(projectID: f.project.id, authorID: f.anna.id, createdAt: t0,
                                       observedAt: t0, kind: .message, text: "Freigabe einholen",
                                       isTask: true, assigneeID: f.ben.id))
        try f.store.merge(entry: Entry(projectID: second.id, authorID: f.ben.id, createdAt: t0,
                                       observedAt: t0, kind: .message, text: "Rechnung stellen", isTask: true))
        try f.store.merge(entry: Entry(projectID: second.id, authorID: f.ben.id, createdAt: t0,
                                       observedAt: t0, kind: .message, text: "erledigt",
                                       isTask: true, isDone: true))
        let tasks = try f.store.timeline(scope: .openTasks, viewer: f.anna.id)
        #expect(tasks.count == 2)
    }

    @Test("The lists that span projects can be narrowed to one of them")
    func narrowedToOneProject() throws {
        let f = try Fixture()
        let second = Project(id: UUID(), name: "Kunde B", addedAt: t0)
        try f.store.addProject(second, rootPath: "/tmp/b", bookmark: nil)
        try f.store.merge(entry: Entry(projectID: f.project.id, authorID: f.anna.id, createdAt: t0,
                                       observedAt: t0, kind: .message, text: "Freigabe einholen",
                                       isTask: true))
        try f.store.merge(entry: Entry(projectID: second.id, authorID: f.ben.id, createdAt: t0,
                                       observedAt: t0, kind: .message, text: "Rechnung stellen", isTask: true))

        var filter = TimelineFilter()
        filter.project = second.id
        #expect(try f.store.timeline(scope: .activity, filter: filter, viewer: f.anna.id)
            .map(\.entry.text) == ["Rechnung stellen"])
        var tasks = TimelineFilter.tasks
        tasks.project = f.project.id
        #expect(try f.store.timeline(scope: .openTasks, filter: tasks, viewer: f.anna.id)
            .map(\.entry.text) == ["Freigabe einholen"])
    }

    /// The task list is where somebody goes to see what they have just ticked
    /// off. It used to be the one place that could never show it.
    @Test("The task list can be turned around to show what has been ticked off")
    func doneTasksInTheTaskList() throws {
        let f = try Fixture()
        try f.store.merge(entry: Entry(projectID: f.project.id, authorID: f.anna.id, createdAt: t0,
                                       observedAt: t0, kind: .message, text: "Freigabe einholen",
                                       isTask: true))
        try f.store.merge(entry: Entry(projectID: f.project.id, authorID: f.anna.id, createdAt: t0,
                                       observedAt: t0, kind: .message, text: "Rechnung gestellt",
                                       isTask: true, isDone: true))

        var filter = TimelineFilter()
        filter.status = .doneTasks
        let done = try f.store.timeline(scope: .openTasks, filter: filter, viewer: f.anna.id)
        #expect(done.map(\.entry.text) == ["Rechnung gestellt"])

        filter.status = .openTasks
        let open = try f.store.timeline(scope: .openTasks, filter: filter, viewer: f.anna.id)
        #expect(open.map(\.entry.text) == ["Freigabe einholen"])
    }

    /// Turning a project down has to mean the same thing everywhere. A dot on a
    /// file whose change is not in the stream cannot be cleared by reading it,
    /// because there is nothing to read.
    @Test("Turning a project down also takes away its unread marks")
    func verbosityReachesTheFileList() throws {
        let f = try Fixture()
        try f.store.setVerbosity(.off, for: f.project.id)
        let node = try f.node("Layout/plakat.afdesign")
        try f.store.merge(entry: f.systemEntry(node: node, author: f.ben.id))

        #expect(try f.store.timeline(scope: .project(f.project.id), viewer: f.anna.id).isEmpty)
        #expect(try f.store.activitySignals(viewer: f.anna.id).unreadTotal == 0)
        let listed = try f.store.files(projectID: f.project.id, parentPath: "Layout",
                                       viewer: f.anna.id)
        #expect(listed.first?.unreadCount == 0, "and the file list agrees with both")
    }

    @Test("Search puts files that still exist above the ones that are gone")
    func searchRanksPresentFirst() throws {
        let f = try Fixture()
        var gone = try f.node("Alt/plakat.afdesign")
        gone.state = .deleted
        try f.store.upsert(node: gone)
        try f.node("Neu/plakat.afdesign")

        let results = try f.store.search("plakat", viewer: f.anna.id)
        #expect(results.nodes.map(\.relativePath) == ["Neu/plakat.afdesign", "Alt/plakat.afdesign"])
    }

    /// A stub that stands in for a file whose registration is still in transit has
    /// a raw id where its name should be and nothing behind it to open.
    @Test("A stub for an unregistered file stays out of the lists")
    func placeholdersAreNotFiles() throws {
        let f = try Fixture()
        let unknown = UUID()
        try f.store.upsert(node: Node(id: unknown, projectID: f.project.id,
                                      relativePath: Node.placeholderPath(for: unknown),
                                      isDirectory: false, firstSeenAt: t0, lastSeenAt: t0))
        try f.store.merge(entry: Entry(projectID: f.project.id, nodeID: unknown, authorID: f.ben.id,
                                       createdAt: t0, observedAt: t0, kind: .message,
                                       text: "Bitte anschauen", isTask: true))

        #expect(try f.store.files(projectID: f.project.id, parentPath: "",
                                  viewer: f.anna.id).isEmpty)
        #expect(try f.store.search("Bitte", viewer: f.anna.id).nodes.isEmpty)
        // The entry itself is not hidden — only the file it cannot name yet.
        #expect(try f.store.timeline(scope: .project(f.project.id), viewer: f.anna.id).count == 1)
    }
}

@Suite("Changing an entry afterwards")
struct PatchTests {

    @Test("Rewording is recorded, ticking a box is not")
    func onlyTextEditsAreMarked() throws {
        let f = try Fixture()
        let entry = Entry(projectID: f.project.id, authorID: f.anna.id, createdAt: t0,
                          observedAt: t0, kind: .message, text: "Freigabe holen", isTask: true)
        try f.store.merge(entry: entry)

        try f.store.apply(patch: EntryPatchRecord(entryID: entry.id, isDone: true),
                          at: t0.addingTimeInterval(60))
        #expect(try f.store.entry(id: entry.id)?.textEditedAt == nil,
                "ticking a task off is not a change to what was said")

        try f.store.apply(patch: EntryPatchRecord(entryID: entry.id, text: "Freigabe bei Meier holen"),
                          at: t0.addingTimeInterval(120))
        let edited = try #require(try f.store.entry(id: entry.id))
        #expect(edited.text == "Freigabe bei Meier holen")
        #expect(edited.textEditedAt != nil)
    }

    @Test("A retracted entry leaves every view but not the log")
    func retraction() throws {
        let f = try Fixture()
        let entry = Entry(projectID: f.project.id, authorID: f.anna.id, createdAt: t0,
                          observedAt: t0, kind: .message, text: "war Unsinn")
        try f.store.merge(entry: entry)
        #expect(try f.store.timeline(scope: .project(f.project.id), viewer: f.ben.id).count == 1)

        try f.store.apply(patch: EntryPatchRecord(entryID: entry.id, isRetracted: true), at: t0)
        #expect(try f.store.timeline(scope: .project(f.project.id), viewer: f.ben.id).isEmpty)
        #expect(try f.store.entry(id: entry.id) != nil, "the record itself is kept")
    }

    @Test("Someone can be given a message after it was written")
    func assignAfterwards() throws {
        let f = try Fixture()
        let entry = Entry(projectID: f.project.id, authorID: f.anna.id, createdAt: t0,
                          observedAt: t0, kind: .message, text: "schau da mal drüber")
        try f.store.merge(entry: entry)
        try f.store.apply(patch: EntryPatchRecord(entryID: entry.id, assigneeID: f.ben.id), at: t0)
        #expect(try f.store.entry(id: entry.id)?.assigneeID == f.ben.id)

        try f.store.apply(patch: EntryPatchRecord(entryID: entry.id, assigneeID: .some(nil)),
                          at: t0.addingTimeInterval(60))
        #expect(try f.store.entry(id: entry.id)?.assigneeID == nil)
    }

    /// A peer's log is read again from its watermark whenever a hole in it is
    /// still open, and the entries past the hole come round again. Seeing one a
    /// second time used to overwrite it with what it said when it was written —
    /// reopening a task somebody here had ticked off, and bringing the message
    /// back as new so that it notified a second time.
    @Test("Reading an entry again does not undo what was changed about it since")
    func rereadKeepsPatches() throws {
        let f = try Fixture()
        let feedback = try #require(try f.store.categories().first)
        let task = Entry(projectID: f.project.id, authorID: f.anna.id, createdAt: t0,
                         observedAt: t0, kind: .message, text: "Freigabe holen", isTask: true)
        try f.store.merge(entry: task)
        try f.store.apply(patch: EntryPatchRecord(entryID: task.id, text: "Freigabe beim Kunden holen",
                                                  isDone: true, assigneeID: .some(f.ben.id),
                                                  categoryIDs: [feedback.id]),
                          at: t0.addingTimeInterval(60))

        var again = task
        again.observedAt = t0.addingTimeInterval(3600)
        #expect(try f.store.merge(entry: again) == .updated)

        let entry = try #require(try f.store.entry(id: task.id))
        #expect(entry.isDone, "ticked off stays ticked off")
        #expect(entry.text == "Freigabe beim Kunden holen")
        #expect(entry.assigneeID == f.ben.id)
        #expect(entry.observedAt == t0, "it is not news the second time")
        let listed = try f.store.timeline(scope: .project(f.project.id), viewer: f.ben.id)
        #expect(listed.first?.categories.map(\.id) == [feedback.id])
    }

    @Test("A later change wins, an older one arriving late does not")
    func lastWriterWins() throws {
        let f = try Fixture()
        let entry = Entry(projectID: f.project.id, authorID: f.anna.id, createdAt: t0,
                          observedAt: t0, kind: .message, text: "erste Fassung")
        try f.store.merge(entry: entry)
        try f.store.apply(patch: EntryPatchRecord(entryID: entry.id, text: "zweite Fassung"),
                          at: t0.addingTimeInterval(600))
        // The other Mac's older edit turns up afterwards; it must not win.
        try f.store.apply(patch: EntryPatchRecord(entryID: entry.id, text: "veraltete Fassung"),
                          at: t0.addingTimeInterval(60))
        #expect(try f.store.entry(id: entry.id)?.text == "zweite Fassung")
    }
}

@Suite("Mentions")
struct MentionTests {
    let anna = Member(name: "Anna", colorHex: "#E4572E")
    let ben = Member(name: "Ben", colorHex: "#2E86AB")
    let annaMaria = Member(name: "Anna Maria", colorHex: "#5B8C5A")

    @Test("A name after @ is the person it is for")
    func findsMention() {
        let matches = Mentions.parse("@Ben schaust du drüber?", members: [anna, ben])
        #expect(matches.count == 1)
        #expect(matches.first?.member.name == "Ben")
    }

    @Test("Case and umlauts do not have to be typed exactly")
    func matchesLoosely() {
        let jorg = Member(name: "Jörg", colorHex: "#000000")
        #expect(Mentions.recipient(in: "kannst du das @jorg", members: [jorg])?.name == "Jörg")
        #expect(Mentions.recipient(in: "@ANNA bitte", members: [anna])?.name == "Anna")
    }

    @Test("An email address is not a mention")
    func ignoresEmail() {
        #expect(Mentions.recipient(in: "schick es an tom@ben.example", members: [ben]) == nil)
    }

    @Test("A profile in a link is not a mention")
    func ignoresProfileLink() {
        #expect(Mentions.recipient(in: "so wie https://instagram.com/@anna", members: [anna]) == nil)
        #expect(Mentions.recipient(in: "wie bei /@anna, @Ben schau", members: [anna, ben])?.name == "Ben")
    }

    @Test("The longer name wins, so Anna Maria is not Anna")
    func prefersLongestName() {
        #expect(Mentions.recipient(in: "@Anna Maria übernimmt", members: [anna, annaMaria])?.name
                == "Anna Maria")
        #expect(Mentions.recipient(in: "@Anna übernimmt", members: [anna, annaMaria])?.name == "Anna")
    }

    @Test("A name must end the word")
    func requiresWordBoundary() {
        #expect(Mentions.recipient(in: "@Benedikt hat angerufen", members: [ben]) == nil)
    }

    @Test("A name nobody has is not a mention")
    func ignoresUnknownNames() {
        #expect(Mentions.recipient(in: "@Kunde meldet sich", members: [anna, ben]) == nil)
    }

    @Test("The first name mentioned is the one it is addressed to")
    func firstMentionWins() {
        #expect(Mentions.recipient(in: "@Ben und @Anna, kurz abstimmen", members: [anna, ben])?.name
                == "Ben")
    }

    /// The sentence this app is written for is a German one, and "Größe", "muss",
    /// "weiß" and "außerdem" all fold to something longer than they are. Anything
    /// that indexes a folded string with an offset from the unfolded one loses
    /// every mention after the first ß in the message, without saying so.
    @Test("A ß earlier in the sentence does not swallow the mention")
    func survivesFoldingThatChangesLength() {
        #expect(Mentions.recipient(in: "Bitte die Größe anpassen @Ben", members: [anna, ben])?.name
                == "Ben")
        #expect(Mentions.recipient(in: "Weiß @Anna davon?", members: [anna, ben])?.name == "Anna")
        #expect(Mentions.recipient(in: "Die ﬁnale Fassung @Ben", members: [anna, ben])?.name == "Ben")
    }

    @Test("The highlighted range is the mention itself, not a shifted slice")
    func highlightsTheRightCharacters() {
        let text = "Größe? @Anna Maria weiß es"
        let matches = Mentions.parse(text, members: [anna, ben, annaMaria])
        #expect(matches.count == 1)
        #expect(matches.first.map { String(text[$0.range]) } == "@Anna Maria")
    }
}

@Suite("Store: writing about a folder")
struct FolderEntryTests {

    @Test("A dot belongs to the folder a file is in, or to the folder itself")
    func signalsNameTheFolder() throws {
        let f = try Fixture()
        let layout = try f.node("Layout", isDirectory: true)
        let drafts = try f.node("Layout/Entwürfe", isDirectory: true)
        let poster = try f.node("Layout/plakat.afdesign")
        for (node, text) in [(drafts, "alt, bitte aufräumen"), (poster, "Farben passen"),
                             (layout, "Ordner fürs Plakat")] as [(Node, String)] {
            try f.store.merge(entry: Entry(projectID: f.project.id, nodeID: node.id,
                                           authorID: f.anna.id, createdAt: t0, observedAt: t0,
                                           kind: .message, text: text, isTask: true))
        }
        try f.store.merge(entry: Entry(projectID: f.project.id, authorID: f.anna.id,
                                       createdAt: t0, observedAt: t0, kind: .message, text: "Hallo"))

        let signals = try f.store.activitySignals(viewer: f.ben.id)
        #expect(signals.unreadFolders[f.project.id]?.sorted()
                == ["", "Layout", "Layout", "Layout/Entwürfe"])
        #expect(signals.openTaskFolders[f.project.id]?.sorted()
                == ["Layout", "Layout", "Layout/Entwürfe"])
    }

    @Test("What was said about a folder is in its stream and in the one above")
    func folderStreamIncludesTheFolder() throws {
        let f = try Fixture()
        let layout = try f.node("Layout", isDirectory: true)
        let drafts = try f.node("Layout/Entwürfe", isDirectory: true)
        let note = Entry(projectID: f.project.id, nodeID: drafts.id, authorID: f.anna.id,
                         createdAt: t0, observedAt: t0, kind: .message, text: "alt, bitte aufräumen")
        try f.store.merge(entry: note)

        #expect(try f.store.timeline(scope: .folder(drafts.id), viewer: f.ben.id).map(\.id) == [note.id])
        #expect(try f.store.timeline(scope: .folder(layout.id), viewer: f.ben.id).map(\.id) == [note.id])
    }
}
