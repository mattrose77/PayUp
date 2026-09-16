import Foundation
import UIKit

/// Shapes matchday and season data into the rows the share card draws.
enum ShareSummary {
    /// Upper bound per line. Width usually bites first — three long offences
    /// don't fit a card row, and clipping one is worse than wrapping early.
    static let maxFinesPerLine = 3

    struct Tally {
        let name: String
        /// Already grouped and lowercased — "gloves / hairband ×5", "own goal".
        let details: [String]
        let amountPence: Int
    }

    static func headline(_ clubName: String) -> String {
        var name = clubName.trimmingCharacters(in: .whitespaces).uppercased()
        for suffix in [" FC", " AFC", " CF", " FC."] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
            break
        }
        return name.isEmpty ? "FINES" : "\(name) FINES"
    }

    static func dateString(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// Repeats collapse into "×N" rather than being listed twice. Reads each
    /// fine's own description — the fine type may since have been deleted.
    static func fineLabels(_ fines: [Fine]) -> [String] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for fine in fines.sorted(by: { $0.createdAt < $1.createdAt }) {
            if counts[fine.description] == nil { order.append(fine.description) }
            counts[fine.description, default: 0] += 1
        }
        return order.map { label in
            let n = counts[label] ?? 1
            return n > 1 ? "\(label.lowercased()) ×\(n)" : label.lowercased()
        }
    }

    /// Greedily packs offences onto lines, measuring the real rendered width
    /// so a line is never wider than the row it has to sit in.
    static func pack(
        _ labels: [String],
        maxWidth: CGFloat,
        fontSize: CGFloat,
        maxPerLine: Int = maxFinesPerLine
    ) -> [String] {
        guard !labels.isEmpty else { return [] }
        let font = UIFont.systemFont(ofSize: fontSize)
        func width(_ text: String) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }

        var lines: [String] = []
        var current: [String] = []

        for label in labels {
            if current.isEmpty {
                current = [label]
                continue
            }
            let candidate = (current + [label]).joined(separator: ", ")
            if current.count < maxPerLine, width(candidate) <= maxWidth {
                current.append(label)
            } else {
                lines.append(current.joined(separator: ", "))
                current = [label]
            }
        }
        if !current.isEmpty { lines.append(current.joined(separator: ", ")) }
        return lines
    }

    static func matchdayTallies(fines: [Fine], players: [Player]) -> [Tally] {
        players.compactMap { player in
            let mine = fines.filter { $0.playerId == player.id }
            guard !mine.isEmpty else { return nil }
            return Tally(
                name: player.name,
                details: fineLabels(mine),
                amountPence: mine.totalPence
            )
        }
        .sorted { $0.amountPence > $1.amountPence }
    }
}
