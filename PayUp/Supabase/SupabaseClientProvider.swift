import Foundation
import Supabase

/// Single shared client. The decoder is configured for snake_case once here so
/// no model needs hand-written CodingKeys.
enum SupabaseClientProvider {
    static let shared: SupabaseClient = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // Postgres hands back timestamptz with a variable number of fractional
        // digits, and `played_on` is a bare date. Handle both.
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = PostgresDate.parse(text) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unrecognised date: \(text)")
            )
        }

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        return SupabaseClient(
            supabaseURL: Config.supabaseURL,
            supabaseKey: Config.supabasePublishableKey,
            options: SupabaseClientOptions(
                db: .init(encoder: encoder, decoder: decoder)
            )
        )
    }()
}

enum PostgresDate {
    private static let timestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let timestampNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// `played_on` is a date, not a timestamp.
    private static let dayOnly: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func parse(_ text: String) -> Date? {
        // Postgres timestamptz carries microseconds ("…:33.123456+00"), and
        // ISO8601DateFormatter only copes with milliseconds — so trim the
        // fraction to three digits before handing it over.
        let trimmed = text.replacing(/\.(\d+)/) { match in
            "." + String(match.output.1.prefix(3))
        }
        return timestamp.date(from: trimmed)
            ?? timestampNoFraction.date(from: trimmed)
            ?? timestamp.date(from: text)
            ?? timestampNoFraction.date(from: text)
            ?? dayOnly.date(from: text)
    }

    static func day(from date: Date) -> String { dayOnly.string(from: date) }
}
