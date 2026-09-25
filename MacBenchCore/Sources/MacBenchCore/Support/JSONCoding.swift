import Foundation

/// The log is the durable format: it is what survives the app, what gets exported,
/// and what a human reads when something looks wrong. So: readable ISO-8601 UTC
/// timestamps, sorted keys, no pretty-printing (one record per line).
public enum JSONCoding {
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    public static func string(from date: Date) -> String { formatter.string(from: date) }

    public static func date(from string: String) -> Date? {
        if let d = formatter.date(from: string) { return d }
        // Tolerate timestamps without fractional seconds; hand-edited logs happen.
        let fallback = ISO8601DateFormatter()
        fallback.formatOptions = [.withInternetDateTime]
        return fallback.date(from: string)
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(string(from: date))
        }
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = self.date(from: raw) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Bad timestamp: \(raw)")
                )
            }
            return date
        }
        return d
    }
}
