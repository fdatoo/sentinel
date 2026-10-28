import Foundation

public enum SentinelJSON {
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            guard let date = RFC3339.parse(string) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Invalid RFC 3339 date: \(string)")
                )
            }
            return date
        }
        return decoder
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(RFC3339.format(date))
        }
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

/// RFC 3339 parsing that accepts any number of fractional digits (Go emits up to
/// nine) and numeric offsets as well as `Z`.
public enum RFC3339 {
    public static func parse(_ string: String) -> Date? {
        var base = string
        var fraction: Double = 0

        if let dot = string.firstIndex(of: ".") {
            var end = string.index(after: dot)
            while end < string.endIndex, string[end].isASCII, string[end].isNumber {
                end = string.index(after: end)
            }
            let digits = string[string.index(after: dot)..<end]
            guard !digits.isEmpty, let value = Double("0." + digits) else { return nil }
            fraction = value
            base.removeSubrange(dot..<end)
        }

        guard let date = try? Date.ISO8601FormatStyle().parse(base) else { return nil }
        return date.addingTimeInterval(fraction)
    }

    public static func format(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle())
    }
}
