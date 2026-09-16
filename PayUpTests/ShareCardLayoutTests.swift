import XCTest
import SwiftUI
@testable import PayUp

/// The card has to grow with its content: no capped row count, no fixed frame
/// leaving a hole above the total, and an export that matches the preview.
@MainActor
final class ShareCardLayoutTests: XCTestCase {

    private func card(rows count: Int) -> ShareCard {
        let names = [
            "Jamie Vasey", "Alex Nkemdi", "Tom Bright", "Sam Whittaker",
            "Kieran Booth", "Marcus Ellery", "Rob Gallagher", "Danny Coombes",
            "Owen Pritchard", "Callum Reeves", "Nathan Ashworth", "Lewis Fenton",
            "Harry Stapleton", "Joe Blackwell", "Ryan Mortimer", "Ben Hollingsworth"
        ]
        let offences = [
            ["late for kick-off"],
            ["own goal", "missed sitter"],
            ["wrong colour socks", "gloves", "hairband ×2"],
            ["argued with the referee about a throw-in", "late for kick-off"]
        ]
        let tallies = (0..<count).map { index in
            ShareSummary.Tally(
                name: names[index % names.count],
                details: offences[index % offences.count],
                amountPence: (index + 1) * 150
            )
        }
        return ShareCard(
            clubName: "Minety FC",
            subtitle: "v Crown FC — Sat 13 Sep",
            rows: tallies,
            bigLabel: "today's damage",
            bigAmount: Money.string(tallies.reduce(0) { $0 + $1.amountPence }),
            closing: "Settle up before Thursday or it doubles."
        )
    }

    private func rendered(rows: Int) throws -> UIImage {
        try XCTUnwrap(ShareCardRenderer.png(from: card(rows: rows)), "render failed at \(rows) rows")
    }

    /// Every fined player appears. The old card stopped at a points budget and
    /// appended "…and N more", which cut exactly the name worth sending.
    func testEveryRowIsLaidOut() {
        for count in [1, 3, 6, 11, 14, 16, 24] {
            XCTAssertEqual(card(rows: count).rows.count, count)
        }
    }

    func testHeightGrowsWithRowCount() throws {
        var previous: CGFloat = 0
        for count in [6, 11, 14, 16] {
            let height = try rendered(rows: count).size.height
            XCTAssertGreaterThan(height, previous, "\(count) rows should be taller than the count below it")
            previous = height
        }
    }

    /// A one-fine week still renders as a portrait card rather than a crop.
    func testShortListsKeepAMinimumHeight() throws {
        for count in [1, 2] {
            let size = try rendered(rows: count).size
            XCTAssertEqual(size.height, ShareCard.minHeight, accuracy: 1)
            XCTAssertEqual(size.width, ShareCard.width, accuracy: 1)
        }
    }

    func testWidthIsConstantAtEveryRowCount() throws {
        for count in [1, 3, 6, 11, 16] {
            XCTAssertEqual(try rendered(rows: count).size.width, ShareCard.width, accuracy: 1)
        }
    }

    /// The renderer proposes a width and no height. If it ever went back to
    /// proposing a fixed size, tall cards would silently crop in the export.
    func testTallCardsAreNotCropped() throws {
        let sixteen = try rendered(rows: 16).size.height
        XCTAssertGreaterThan(sixteen, ShareCard.minHeight)
        // Sixteen rows of names and offences can't fit in a 4:5 portrait.
        XCTAssertGreaterThan(sixteen, ShareCard.width * 1.5)
    }

    /// Writes the PNGs out for a human to look at. Path is printed by the test.
    func testWriteVisualSamples() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sharecards")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for count in [1, 3, 6, 11, 16] {
            let image = try rendered(rows: count)
            let data = try XCTUnwrap(image.pngData())
            let url = dir.appendingPathComponent("card-\(String(format: "%02d", count)).png")
            try data.write(to: url)
            print("SAMPLE \(count) rows -> \(url.path) (\(Int(image.size.width))x\(Int(image.size.height)) pt)")
        }
    }
}
