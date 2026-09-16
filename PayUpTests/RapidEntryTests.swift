import XCTest
@testable import PayUp

/// Lets a test hold each save open and resolve them in whatever order it likes,
/// so out-of-order completion is deterministic rather than a race.
private actor Gate {
    private var waiting: [String: CheckedContinuation<Void, Error>] = [:]
    private var arrived: Set<String> = []
    private(set) var received: [String] = []

    func arrive(_ key: String) async throws {
        received.append(key)
        arrived.insert(key)
        try await withCheckedThrowingContinuation { continuation in
            waiting[key] = continuation
        }
    }

    func hasArrived(_ key: String) -> Bool { arrived.contains(key) }

    func succeed(_ key: String) {
        waiting.removeValue(forKey: key)?.resume()
    }

    func fail(_ key: String, _ error: Error) {
        waiting.removeValue(forKey: key)?.resume(throwing: error)
    }

    func order() -> [String] { received }
}

private struct GateError: LocalizedError {
    var errorDescription: String? { "Network unavailable" }
}

@MainActor
final class RapidEntryTests: XCTestCase {
    private var gate: Gate!
    private var queue: RapidEntryQueue<String>!

    override func setUp() {
        gate = Gate()
        let gate = gate!
        queue = RapidEntryQueue<String> { name in
            try await gate.arrive(name)
        }
    }

    /// Waits until the save for `name` is actually in flight.
    private func waitForArrival(_ name: String, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if await gate.hasArrived(name) { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("save for \(name) never reached the repository", file: file, line: line)
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(30))
    }

    // MARK: - Nothing dropped

    func testNamesSubmittedRapidlyAllReachTheRepository() async {
        let names = (1...14).map { "Player \($0)" }
        for name in names { queue.submit(name) }

        for name in names { await waitForArrival(name) }

        let received = await gate.order()
        XCTAssertEqual(received.count, 14, "every name made it")
        XCTAssertEqual(Set(received), Set(names), "and none was lost or duplicated")
        XCTAssertEqual(queue.drafts.count, 14)
        XCTAssertTrue(queue.drafts.allSatisfy(\.state.isPending))
    }

    func testSavesAreNotSerialisedBehindEachOther() async {
        queue.submit("First")
        queue.submit("Second")
        queue.submit("Third")

        // All three are in flight at once — none is waiting for the one before.
        await waitForArrival("First")
        await waitForArrival("Second")
        await waitForArrival("Third")

        let received = await gate.order()
        XCTAssertEqual(received.count, 3)
    }

    // MARK: - Out-of-order responses

    func testOutOfOrderResponsesSettleOntoTheCorrectRows() async {
        let ids = ["Alpha", "Bravo", "Charlie"].map { queue.submit($0) }
        for name in ["Alpha", "Bravo", "Charlie"] { await waitForArrival(name) }

        // Resolve backwards, and fail the middle one.
        await gate.succeed("Charlie")
        await settle()
        await gate.fail("Bravo", GateError())
        await settle()
        await gate.succeed("Alpha")
        await settle()

        let byId = Dictionary(uniqueKeysWithValues: queue.drafts.map { ($0.id, $0) })
        XCTAssertTrue(byId[ids[0]]?.state.isSaved ?? false, "Alpha saved")
        XCTAssertTrue(byId[ids[1]]?.state.isFailed ?? false, "Bravo failed")
        XCTAssertTrue(byId[ids[2]]?.state.isSaved ?? false, "Charlie saved")
    }

    func testRowsKeepSubmissionOrderRegardlessOfResponseOrder() async {
        let names = ["Alpha", "Bravo", "Charlie", "Delta"]
        for name in names { queue.submit(name) }
        for name in names { await waitForArrival(name) }

        await gate.succeed("Delta")
        await settle()
        await gate.fail("Alpha", GateError())
        await settle()
        await gate.succeed("Bravo")
        await settle()
        await gate.fail("Charlie", GateError())
        await settle()

        XCTAssertEqual(
            queue.drafts.map(\.payload), names,
            "the list is still in the order it was typed"
        )
    }

    func testTwoRowsWithTheSameNameStayDistinct() async {
        let first = queue.submit("Jamie")
        let second = queue.submit("Jamie")
        XCTAssertNotEqual(first, second, "matched by id, never by name")

        await waitForArrival("Jamie")
        await gate.succeed("Jamie")
        await settle()

        // Only one save resolved, so exactly one row settled.
        let saved = queue.drafts.filter(\.state.isSaved)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(queue.drafts.count, 2, "both rows are still there")
    }

    // MARK: - Failure and retry

    func testAFailedSaveLeavesItsRowPresentAndMarkedFailed() async {
        let id = queue.submit("Doomed")
        await waitForArrival("Doomed")
        await gate.fail("Doomed", GateError())
        await settle()

        let row = queue.drafts.first { $0.id == id }
        XCTAssertNotNil(row, "the row is never silently dropped")
        XCTAssertTrue(row?.state.isFailed ?? false)
        XCTAssertEqual(row?.state.errorMessage, "Network unavailable")
        XCTAssertEqual(row?.payload, "Doomed", "the name is still there to retry or edit")
    }

    func testRetryResendsTheSameRowAndSettlesIt() async {
        let id = queue.submit("Flaky")
        await waitForArrival("Flaky")
        await gate.fail("Flaky", GateError())
        await settle()
        XCTAssertTrue(queue.drafts.first { $0.id == id }?.state.isFailed ?? false)

        queue.retry(id)
        XCTAssertTrue(
            queue.drafts.first { $0.id == id }?.state.isPending ?? false,
            "back to pending while it's in flight again"
        )

        await waitForArrival("Flaky")
        await gate.succeed("Flaky")
        await settle()

        XCTAssertTrue(queue.drafts.first { $0.id == id }?.state.isSaved ?? false)
        let received = await gate.order()
        XCTAssertEqual(received.filter { $0 == "Flaky" }.count, 2, "sent twice, once per attempt")
    }

    func testFailedRowsCanBeDiscarded() async {
        let id = queue.submit("Gone")
        await waitForArrival("Gone")
        await gate.fail("Gone", GateError())
        await settle()

        queue.discard(id)
        XCTAssertTrue(queue.drafts.isEmpty)
    }

    // MARK: - Visibility

    func testSavedRowsDropOutOfTheVisibleListButFailedOnesStay() async {
        let good = queue.submit("Good")
        let bad = queue.submit("Bad")
        await waitForArrival("Good")
        await waitForArrival("Bad")
        await gate.succeed("Good")
        await gate.fail("Bad", GateError())
        await settle()

        let visible = queue.visibleDrafts.map(\.id)
        XCTAssertFalse(visible.contains(good), "settled rows join the real list")
        XCTAssertTrue(visible.contains(bad), "broken ones stay put")
    }
}

/// Validation happens before anything reaches the network.
final class EntryValidationTests: XCTestCase {
    func testWhitespaceOnlyInputIsRejected() {
        XCTAssertNil(EntryValidation.cleanName(""))
        XCTAssertNil(EntryValidation.cleanName("   "))
        XCTAssertNil(EntryValidation.cleanName("\n\t "))
    }

    func testNamesAreTrimmedBeforeSending() {
        XCTAssertEqual(EntryValidation.cleanName("  Jamie Vasey  "), "Jamie Vasey")
        XCTAssertEqual(EntryValidation.cleanName("Jamie\n"), "Jamie")
    }

    func testDuplicateNamesWarnRatherThanBlock() {
        let warning = EntryValidation.duplicateWarning(
            for: "jamie vasey", existing: ["Jamie Vasey", "Alex Nkemdi"]
        )
        XCTAssertNotNil(warning, "case-insensitive match is flagged")
        XCTAssertTrue(warning?.contains("Jamie Vasey") ?? false)
        XCTAssertTrue(warning?.contains("added anyway") ?? false, "it's a warning, not a block")
    }

    func testDistinctNamesDoNotWarn() {
        XCTAssertNil(EntryValidation.duplicateWarning(for: "Sam", existing: ["Jamie", "Alex"]))
    }
}

@MainActor
final class RapidEntryValidationIntegrationTests: XCTestCase {
    /// The view rejects blank input before constructing a payload, so nothing
    /// blank can ever reach the queue.
    func testBlankInputNeverReachesTheRepository() async {
        let gate = Gate()
        let queue = RapidEntryQueue<String> { name in try await gate.arrive(name) }

        for blank in ["", "   ", "\n"] {
            if let clean = EntryValidation.cleanName(blank) { queue.submit(clean) }
        }
        try? await Task.sleep(for: .milliseconds(30))

        let received = await gate.order()
        XCTAssertTrue(received.isEmpty, "no network call was made")
        XCTAssertTrue(queue.drafts.isEmpty, "and no row was created")
    }
}
