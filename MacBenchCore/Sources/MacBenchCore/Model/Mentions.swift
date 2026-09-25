import Foundation

/// Finds `@name` in what somebody typed.
///
/// The field it fills is `assigneeID`, which is not "who is responsible" but
/// "who is this for" — the notification rule has never asked whether the entry
/// was a task. A ticked box turns it into work; without one it is a heads-up.
/// Same field, and the checkbox decides which reading applies.
public enum Mentions {

    public struct Match: Sendable, Hashable {
        public var range: Range<String.Index>
        public var member: Member
    }

    /// Longest name first, so "@Anna Maria" is not read as "@Anna".
    public static func parse(_ text: String, members: [Member]) -> [Match] {
        let candidates = members
            .map { (needle: searchNormalized($0.name), member: $0) }
            .filter { !$0.needle.isEmpty }
            .sorted { $0.needle.count > $1.needle.count }
        guard !candidates.isEmpty else { return [] }

        var matches: [Match] = []
        var index = text.startIndex

        while let at = text[index...].firstIndex(of: "@") {
            index = text.index(after: at)
            // An address like tom@example.com is not a mention: a real one starts
            // a word. Nor is a profile in a link, "instagram.com/@mara" — pasting
            // one would otherwise address the message to Mara and notify her.
            if at > text.startIndex {
                let before = text[text.index(before: at)]
                if before.isLetter || before.isNumber || before == "/" { continue }
            }

            for candidate in candidates {
                guard let end = matchEnd(of: candidate.needle, in: text, from: index) else { continue }
                // A name must end the word, so "@Mara" does not match "@Marathon".
                if end < text.endIndex, text[end].isLetter || text[end].isNumber { continue }
                matches.append(Match(range: at..<end, member: candidate.member))
                index = end
                break
            }
        }
        return matches
    }

    /// Where `needle` ends in `text`, starting at `from`, or `nil` if it is not
    /// there. The comparison is on normalised forms, so "@jorg" finds Jörg.
    ///
    /// Deliberately slice by slice on the original string. Normalising the whole
    /// text once and indexing into it with an offset taken from the original is
    /// what this used to do, and it is wrong: folding turns "ß" into "ss" and "ﬁ"
    /// into "fi", so the two strings have different lengths and every mention
    /// after the first such character lands in the wrong place — silently, which
    /// in a German sentence means most of them.
    private static func matchEnd(of needle: String, in text: String,
                                 from start: String.Index) -> String.Index? {
        var end = start
        // Folding never shortens, so the original can be no longer than the needle.
        for _ in 0...needle.count {
            if searchNormalized(String(text[start..<end])) == needle { return end }
            guard end < text.endIndex else { return nil }
            end = text.index(after: end)
        }
        return nil
    }

    /// Who a message is for, if anyone. The first name mentioned: a sentence that
    /// names two people is addressed to the one it opens with.
    public static func recipient(in text: String, members: [Member]) -> Member? {
        parse(text, members: members).first?.member
    }
}
