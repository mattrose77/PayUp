import XCTest
@testable import PayUp

/// The mapper is the layer most likely to break silently: if the server renames
/// an error, nothing crashes, the app just stops explaining itself. These need
/// no network.
final class PostgresErrorMapperTests: XCTestCase {
    private func mapped(_ message: String, fallbackLimit: Int = 1) -> TeamError {
        PostgresErrorMapper.teamError(from: message, fallbackLimit: fallbackLimit)
    }

    func testEachServerErrorMapsToItsCase() {
        XCTAssertEqual(mapped("team_full"), .teamFull)
        XCTAssertEqual(mapped("code_not_found"), .codeNotFound)
        XCTAssertEqual(mapped("already_member"), .alreadyMember)
        XCTAssertEqual(mapped("not_owner"), .notAuthorised)
        XCTAssertEqual(mapped("team_limit_reached"), .teamLimitReached(limit: 1))
    }

    /// `.single()` on a row the other member just deleted. RemoteCall prefixes
    /// the PostgREST code, so both the code and the wording are covered.
    func testMissingRowReadsAsGoneRatherThanPostgrestJargon() {
        let raw = "PGRST116 JSON object requested, multiple (or no) rows returned The result contains 0 rows"
        guard case .serverRejected(let text) = mapped(raw) else {
            return XCTFail("expected a readable serverRejected message")
        }
        XCTAssertFalse(text.contains("JSON"))
        XCTAssertTrue(text.contains("refresh"))
    }

    func testErrorsAreFoundInsideWrappedPostgresMessages() {
        // Postgres wraps RAISE messages, so matching has to be on substrings.
        XCTAssertEqual(
            mapped(#"new row violates check constraint: team_full"#),
            .teamFull
        )
        XCTAssertEqual(
            mapped("PostgrestError(message: \"code_not_found\", code: \"P0001\")"),
            .codeNotFound
        )
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertEqual(mapped("TEAM_FULL"), .teamFull)
        XCTAssertEqual(mapped("Already_Member"), .alreadyMember)
    }

    func testLimitIsReadFromTheMessageWhenPresent() {
        XCTAssertEqual(mapped("team_limit_reached: 3"), .teamLimitReached(limit: 3))
        XCTAssertEqual(mapped("team_limit_reached (limit 5)"), .teamLimitReached(limit: 5))
    }

    func testLimitFallsBackToTheClientEntitlementWhenAbsent() {
        XCTAssertEqual(
            mapped("team_limit_reached", fallbackLimit: 2),
            .teamLimitReached(limit: 2)
        )
    }

    func testUnrecognisedErrorsFallBackRatherThanCrashing() {
        // A rule added server-side after this build shipped.
        let error = mapped("season_archived")
        XCTAssertEqual(error, .serverRejected("season_archived"))
        XCTAssertEqual(error.errorDescription, "season_archived")
    }

    func testEveryMappedCaseHasAMessageWorthShowing() {
        let cases: [TeamError] = [
            .teamFull, .codeNotFound, .alreadyMember, .notAuthorised,
            .ownerCannotLeave, .teamLimitReached(limit: 1), .serverRejected("nope")
        ]
        for error in cases {
            let text = error.errorDescription ?? ""
            XCTAssertFalse(text.isEmpty, "\(error) has no user-facing message")
        }
    }
}

/// Postgres hands back more precision than ISO8601DateFormatter accepts, which
/// is a silent failure: rows simply don't decode and the screen stays empty.
final class PostgresDateTests: XCTestCase {
    func testParsesMicrosecondTimestamps() {
        XCTAssertNotNil(PostgresDate.parse("2026-09-15T12:08:33.123456+00:00"))
        XCTAssertNotNil(PostgresDate.parse("2026-09-15T12:08:33.123456Z"))
    }

    func testParsesMillisecondAndPlainTimestamps() {
        XCTAssertNotNil(PostgresDate.parse("2026-09-15T12:08:33.123Z"))
        XCTAssertNotNil(PostgresDate.parse("2026-09-15T12:08:33Z"))
    }

    func testParsesDateOnlyForPlayedOn() {
        let date = PostgresDate.parse("2026-09-12")
        XCTAssertNotNil(date)
        XCTAssertEqual(date.map(PostgresDate.day(from:)), "2026-09-12")
    }

    func testRejectsNonsense() {
        XCTAssertNil(PostgresDate.parse("not a date"))
    }
}

/// Swift uppercases UUID strings, Postgres lowercases them. Comparing raw makes
/// a signed-in owner look like a non-member of their own team.
final class UserIDTests: XCTestCase {
    private let upper = "CED48E2C-5A3A-4195-AAD1-9ED431783F84"
    private let lower = "ced48e2c-5a3a-4195-aad1-9ed431783f84"

    func testCaseDifferencesStillMatch() {
        XCTAssertTrue(UserID.matches(upper, lower))
        XCTAssertTrue(UserID.matches(lower, upper))
    }

    func testNormalisationIsStable() {
        XCTAssertEqual(UserID.normalise(upper), lower)
        XCTAssertEqual(UserID.normalise(" \(upper) "), lower)
        XCTAssertEqual(UserID.normalise(lower), lower)
    }

    func testDifferentIdsStillDiffer() {
        XCTAssertFalse(UserID.matches(lower, "00000000-0000-0000-0000-000000000000"))
    }

    func testSwiftUUIDStringRoundTripsToTheServerForm() {
        let id = UUID()
        XCTAssertEqual(UserID.normalise(id.uuidString), id.uuidString.lowercased())
    }
}
