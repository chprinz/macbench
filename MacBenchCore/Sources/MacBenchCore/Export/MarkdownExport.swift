import Foundation

/// Writes a project's history as Markdown.
///
/// This ships in version one on purpose: after two years a large part of what a
/// team knows about a client lives in this database, and it must not be readable
/// only by this one application.
public struct MarkdownExport: Sendable {
    public var includeSystemEntries: Bool = true
    public var groupByDay: Bool = true

    public init(includeSystemEntries: Bool = true, groupByDay: Bool = true) {
        self.includeSystemEntries = includeSystemEntries
        self.groupByDay = groupByDay
    }

    public func render(project: Project, items: [TimelineItem], locale: Locale = .current,
                       generatedAt: Date = Date()) -> String {
        let dayFormatter = DateFormatter()
        dayFormatter.locale = locale
        dayFormatter.dateStyle = .full
        dayFormatter.timeStyle = .none
        let timeFormatter = DateFormatter()
        timeFormatter.locale = locale
        timeFormatter.dateFormat = "HH:mm"

        var out = "# \(project.name)\n\n"
        out += "_\(items.count) entries, exported \(ISO8601DateFormatter().string(from: generatedAt))_\n\n"

        var lastDay = ""
        for item in items where includeSystemEntries || item.entry.kind == .message {
            if groupByDay {
                let day = dayFormatter.string(from: item.entry.createdAt)
                if day != lastDay {
                    out += "\n## \(day)\n\n"
                    lastDay = day
                }
            }
            out += line(for: item, time: timeFormatter.string(from: item.entry.createdAt))
        }
        return out
    }

    private func line(for item: TimelineItem, time: String) -> String {
        var parts: [String] = ["**\(time)**"]
        parts.append(item.author?.name ?? "unknown")
        if let node = item.node, !node.isPlaceholder {
            // The slash, as `ls -F` has it: a folder is not a file without an extension.
            parts.append("`\(node.relativePath)\(node.isDirectory ? "/" : "")`")
        }
        if !item.categories.isEmpty {
            parts.append(item.categories.map { "#\($0.name)" }.joined(separator: " "))
        }
        var text = item.entry.text
        if item.entry.kind == .system, let event = item.entry.event {
            text = describe(event: event, node: item.node)
        } else if item.entry.notice == .joined {
            // The name is already the second column of this line.
            text = "joined this project"
        }
        var line = parts.joined(separator: " · ")
        if item.entry.isTask {
            line = (item.entry.isDone ? "- [x] " : "- [ ] ") + line
        } else {
            line = "- " + line
        }
        line += "  \n  " + text.replacingOccurrences(of: "\n", with: "\n  ") + "\n"
        return line
    }

    private func describe(event: FileEvent, node: Node?) -> String {
        var text: String
        switch event.type {
        case .created: text = "created"
        case .modified: text = "changed"
        case .renamed: text = "renamed"
        case .moved: text = "moved"
        case .removed: text = "deleted"
        }
        if let from = event.fromPath { text += " (was `\(from)`)" }
        if event.count > 1 { text += " ×\(event.count)" }
        if let added = event.linesAdded, let removed = event.linesRemoved {
            text += " +\(added) −\(removed)"
        }
        if event.backfilled { text += " — reconstructed, time approximate" }
        return text
    }
}
