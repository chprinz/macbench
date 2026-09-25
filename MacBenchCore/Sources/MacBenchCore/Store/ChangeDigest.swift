import Foundation

/// One line in the stream: an entry, or a file's changes on one day told once.
public struct DigestRow: Sendable, Hashable, Identifiable {
    /// What the line says. For folded changes this is the day's latest change,
    /// with its event rewritten to sum up the day.
    public var item: TimelineItem
    /// Every entry the line stands for, oldest first. Just `item` for anything
    /// that was not folded.
    public var members: [TimelineItem]
    public var id: UUID { item.id }

    public var isFolded: Bool { members.count > 1 }
}

/// Folds a file's changes into one line per day.
///
/// Opening the app, the question is what changed — not the minute of every save.
/// Three saves of a layout were three lines, and with the other Mac's lines
/// between them, the one sentence somebody wrote was hard to find. Folded, the
/// line says the file changed, how often, and sits where the last change did.
///
/// Only changes to files fold. What people wrote, and somebody joining, stay
/// lines of their own.
public enum ChangeDigest {

    public static func fold(_ items: [TimelineItem], calendar: Calendar = .current) -> [DigestRow] {
        struct Key: Hashable { let node: UUID; let day: Date }
        func key(_ item: TimelineItem) -> Key? {
            guard item.entry.kind == .system, item.entry.event != nil,
                  let node = item.entry.nodeID else { return nil }
            return Key(node: node, day: calendar.startOfDay(for: item.entry.createdAt))
        }

        var groups: [Key: [TimelineItem]] = [:]
        for item in items {
            if let key = key(item) { groups[key, default: []].append(item) }
        }
        var rows: [DigestRow] = []
        for item in items {
            guard let key = key(item), let members = groups[key] else {
                rows.append(DigestRow(item: item, members: [item]))
                continue
            }
            // The line goes where the file was last touched.
            guard members.last?.id == item.id else { continue }
            rows.append(DigestRow(item: members.count == 1 ? item : summary(of: members),
                                  members: members))
        }
        return rows
    }

    /// The day's changes as one. Same precedence as a coalescing window: a file
    /// that appeared was added, whatever happened to it afterwards, unless it is
    /// gone again at the end of the day.
    static func summary(of members: [TimelineItem]) -> TimelineItem {
        var summary = members[members.count - 1]
        let events = members.compactMap(\.entry.event)
        let types = events.map(\.type)

        let type: FileEventType
        if types.last == .removed { type = .removed }
        else if types.contains(.created) { type = .created }
        else if types.contains(.moved) { type = .moved }
        else if types.contains(.renamed) { type = .renamed }
        else { type = .modified }

        let added = events.compactMap(\.linesAdded)
        let removed = events.compactMap(\.linesRemoved)
        summary.entry.event = FileEvent(
            type: type,
            // Saves, not filesystem events: "changed 15 times" was Pages rewriting
            // one file fifteen times in a single save.
            count: members.count,
            linesAdded: added.isEmpty ? nil : added.reduce(0, +),
            linesRemoved: removed.isEmpty ? nil : removed.reduce(0, +),
            fromPath: events.first { $0.fromPath != nil }?.fromPath,
            backfilled: events.allSatisfy(\.backfilled))
        // The last name anyone can put to it. A nameless line after a named one
        // is usually the same work, arrived before its author's log did.
        if let named = members.last(where: { $0.author != nil }) {
            summary.author = named.author
            summary.entry.authorID = named.entry.authorID
        }
        summary.isUnread = members.contains(where: \.isUnread)
        return summary
    }
}
