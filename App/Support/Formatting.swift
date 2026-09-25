import SwiftUI
import MacBenchCore

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex.hasPrefix("#") ? String(hex.dropFirst()) : hex).scanHexInt64(&value)
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

/// The colours offered when someone joins. Distinguishable next to each other and
/// on both appearances, which is the only requirement a name colour has.
enum MemberPalette {
    static let colors = ["#E4572E", "#2E86AB", "#5B8C5A", "#8367C7",
                         "#C77D3E", "#3E8E7E", "#B5446E", "#4B6584"]

    /// Names exist for the screen reader and the tooltip. Nobody picks a colour by
    /// reading it, so the swatch is the control and the name never appears as the
    /// primary label.
    static func name(for hex: String) -> LocalizedStringKey {
        switch hex {
        case "#E4572E": "Red"
        case "#2E86AB": "Blue"
        case "#5B8C5A": "Green"
        case "#8367C7": "Purple"
        case "#C77D3E": "Amber"
        case "#3E8E7E": "Teal"
        case "#B5446E": "Berry"
        default: "Slate"
        }
    }

    static func next(after used: [String]) -> String {
        colors.first { !used.contains($0) } ?? colors.randomElement()!
    }
}

/// A row of colour swatches. The colour is the choice, so the colour is the
/// control — a menu listing hex codes asks people to read something no one reads.
struct ColorSwatchPicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 10) {
            ForEach(MemberPalette.colors, id: \.self) { hex in
                Button { selection = hex } label: {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 22, height: 22)
                        .overlay {
                            Circle()
                                .strokeBorder(Color.primary.opacity(selection == hex ? 0.85 : 0),
                                              lineWidth: 2)
                                .padding(-3)
                        }
                }
                .buttonStyle(.plain)
                .help(MemberPalette.name(for: hex))
                .accessibilityLabel(MemberPalette.name(for: hex))
                .accessibilityAddTraits(selection == hex ? [.isSelected] : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

enum Format {
    /// "09:12" today, "Tue 09:12" this week, "3 Sep" beyond. Timeline rows are
    /// read in sequence, so the date only appears where it changes meaning.
    static func timestamp(_ date: Date, reference: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if let days = calendar.dateComponents([.day], from: date, to: reference).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    /// The time alone, for rows under a heading that already says the day.
    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func dayHeading(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "Today") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    static func categoryName(_ category: MacBenchCore.Category) -> String {
        guard category.isBuiltIn else { return category.name }
        return switch category.name {
        case "feedback": String(localized: "Feedback")
        case "technical": String(localized: "Technical")
        case "admin": String(localized: "Admin")
        case "system": String(localized: "System")
        default: category.name
        }
    }

    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Text with its web addresses made clickable. Somebody pastes a link to a
    /// shared folder or a reference image; copying it out of a message to open
    /// it was the only way, and that is a chore a message should not leave.
    static func linked(_ text: some StringProtocol) -> AttributedString {
        let text = String(text)
        var result = AttributedString()
        var cursor = text.startIndex
        for (range, url) in links(in: text) {
            result += AttributedString(text[cursor..<range.lowerBound])
            var link = AttributedString(text[range])
            link.link = url
            result += link
            cursor = range.upperBound
        }
        result += AttributedString(text[cursor...])
        return result
    }

    /// Where the addresses are, so that a mention can stay out of one:
    /// "https://instagram.com/@mara" is a link with a name in it, not a name.
    static func links(in text: String) -> [(range: Range<String.Index>, url: URL)] {
        guard let linkDetector else { return [] }
        let whole = NSRange(text.startIndex..., in: text)
        return linkDetector.matches(in: text, range: whole).compactMap { match in
            guard let url = match.url, let range = Range(match.range, in: text),
                  isWrittenAsLink(text[range], url: url) else { return nil }
            return (range, url)
        }
    }

    /// Only what was written as an address. The detector also takes a bare name
    /// with a domain ending for one, and in an app about files "logo.ai" is an
    /// Illustrator file, not a website. "kunde.de" stays text as the price of that.
    private static func isWrittenAsLink(_ written: Substring, url: URL) -> Bool {
        url.scheme == "mailto"
            || written.contains("://")
            || written.lowercased().hasPrefix("www.")
    }
}

extension FileEventType {
    var symbolName: String {
        switch self {
        case .created: "plus.circle"
        case .modified: "pencil.circle"
        case .renamed: "character.cursor.ibeam"
        case .moved: "arrow.turn.down.right"
        case .removed: "minus.circle"
        }
    }
}

/// The wording of a system entry. Deliberately flat and factual: this is the text
/// that appears dozens of times a day, and anything with personality in it would
/// become unbearable by Thursday.
struct EventPhrase {
    let event: FileEvent
    let fileName: String
    /// False when nobody knows who made the change. The sentence is then about
    /// the file — "plakat.pdf was deleted" — rather than about a "someone" who
    /// says nothing and still takes the front of the line.
    var authorIsKnown = true

    var text: String {
        // "+0 −0" is a line count that says a file changed without a single line
        // changing, which is true of a resave and useless to read.
        let hasLineStats: Bool = {
            guard let added = event.linesAdded, let removed = event.linesRemoved else { return false }
            return added + removed > 0
        }()
        var sentence: String = authorIsKnown
            ? active(hasLineStats: hasLineStats)
            : passive(hasLineStats: hasLineStats)
        if hasLineStats, let added = event.linesAdded, let removed = event.linesRemoved {
            sentence += "  +\(added) −\(removed)"
        }
        return sentence
    }

    private func active(hasLineStats: Bool) -> String {
        switch event.type {
        case .created: String(localized: "added \(fileName)")
        case .modified:
            if event.count > 1 {
                String(localized: "changed \(fileName) \(event.count) times")
            } else if hasLineStats {
                String(localized: "changed \(fileName)")
            } else {
                // No byte counts: "replaced" is all that can honestly be said
                // about a layout file, and a size would only invite false
                // conclusions.
                String(localized: "replaced \(fileName)")
            }
        case .renamed: String(localized: "renamed \(previousName) to \(fileName)")
        case .moved:
            if let previousFolder {
                String(localized: "moved \(fileName) from \(previousFolder)")
            } else {
                String(localized: "moved \(fileName)")
            }
        case .removed: String(localized: "deleted \(fileName)")
        }
    }

    private func passive(hasLineStats: Bool) -> String {
        switch event.type {
        case .created: String(localized: "\(fileName) was added")
        case .modified:
            if event.count > 1 {
                String(localized: "\(fileName) was changed \(event.count) times")
            } else if hasLineStats {
                String(localized: "\(fileName) was changed")
            } else {
                String(localized: "\(fileName) was replaced")
            }
        case .renamed: String(localized: "\(previousName) was renamed to \(fileName)")
        case .moved:
            if let previousFolder {
                String(localized: "\(fileName) was moved from \(previousFolder)")
            } else {
                String(localized: "\(fileName) was moved")
            }
        case .removed: String(localized: "\(fileName) was deleted")
        }
    }

    /// Where a moved file was before. Where it is now the line already shows, as
    /// the path to it.
    private var previousFolder: String? {
        guard let from = event.fromPath else { return nil }
        let parent = (from as NSString).deletingLastPathComponent
        return parent.isEmpty
            ? String(localized: "the top level")
            : (parent as NSString).lastPathComponent
    }

    private var previousName: String {
        guard let from = event.fromPath else { return String(localized: "the previous name") }
        return (from as NSString).lastPathComponent
    }
}
