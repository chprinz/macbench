import Foundation
import Testing
@testable import MacBenchCore

@Suite("What changed, once per file and day")
struct ChangeDigestTests {
    let project = UUID()
    let layout = UUID()
    let brief = UUID()
    let mara = Member(name: "Mara", colorHex: "#2E86AB")
    let tom = Member(name: "Tom", colorHex: "#8367C7")
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    /// 24 September 2026, at the given local time.
    func at(_ hour: Int, _ minute: Int, day: Int = 24) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    func change(_ node: UUID, _ type: FileEventType, _ date: Date, by author: Member? = nil,
                count: Int = 1, unread: Bool = false, from: String? = nil) -> TimelineItem {
        TimelineItem(entry: Entry(projectID: project, nodeID: node, authorID: author?.id,
                                  createdAt: date, observedAt: date, kind: .system, text: "",
                                  event: FileEvent(type: type, count: count, fromPath: from)),
                     categories: [], author: author, assignee: nil, node: nil, isUnread: unread)
    }

    func message(_ text: String, _ date: Date, by author: Member) -> TimelineItem {
        TimelineItem(entry: Entry(projectID: project, nodeID: layout, authorID: author.id,
                                  createdAt: date, observedAt: date, kind: .message, text: text),
                     categories: [], author: author, assignee: nil, node: nil, isUnread: false)
    }

    @Test("A day of saving a file is one line, where it was last saved")
    func foldsSaves() {
        let items = [
            change(layout, .modified, at(10, 35), count: 15),
            change(brief, .modified, at(10, 40), by: tom),
            change(layout, .modified, at(10, 57), count: 6),
            change(layout, .modified, at(13, 1), by: mara),
        ]
        let rows = ChangeDigest.fold(items, calendar: calendar)
        #expect(rows.count == 2)
        #expect(rows.map(\.item.entry.nodeID) == [brief, layout],
                "the file's line sits at its last change")
        let layoutRow = rows[1]
        #expect(layoutRow.members.count == 3)
        #expect(layoutRow.item.entry.event?.type == .modified)
        #expect(layoutRow.item.entry.event?.count == 3,
                "saves are counted, not the fifteen files Pages rewrote in one of them")
        #expect(layoutRow.item.author == mara)
    }

    @Test("What people wrote is never folded away")
    func messagesStay() {
        let items = [
            change(layout, .modified, at(10, 35)),
            message("Seite 2 bitte kürzen", at(10, 50), by: mara),
            change(layout, .modified, at(11, 5)),
        ]
        let rows = ChangeDigest.fold(items, calendar: calendar)
        #expect(rows.map(\.item.entry.kind) == [.message, .system])
    }

    @Test("Another day is another line")
    func daysStaySeparate() {
        let items = [
            change(layout, .modified, at(17, 0, day: 23)),
            change(layout, .modified, at(9, 0)),
        ]
        #expect(ChangeDigest.fold(items, calendar: calendar).count == 2)
    }

    @Test("Added and then saved is added; saved and then deleted is deleted")
    func precedence() {
        let added = ChangeDigest.fold([
            change(layout, .created, at(9, 0), by: mara),
            change(layout, .modified, at(9, 30), by: mara),
        ], calendar: calendar)
        #expect(added.first?.item.entry.event?.type == .created)

        let gone = ChangeDigest.fold([
            change(brief, .modified, at(9, 0)),
            change(brief, .removed, at(9, 30), by: tom),
        ], calendar: calendar)
        #expect(gone.first?.item.entry.event?.type == .removed)
    }

    @Test("Unread if any of it is")
    func unread() {
        let rows = ChangeDigest.fold([
            change(layout, .modified, at(9, 0), unread: true),
            change(layout, .modified, at(9, 30)),
        ], calendar: calendar)
        #expect(rows.first?.item.isUnread == true)
    }

    @Test("A single change is left exactly as it was")
    func singleUntouched() {
        let one = change(layout, .renamed, at(9, 0), by: mara, count: 18, from: "alt.png")
        let rows = ChangeDigest.fold([one], calendar: calendar)
        #expect(rows.first?.item == one)
        #expect(rows.first?.isFolded == false)
    }
}
