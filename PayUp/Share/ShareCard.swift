import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

/// The shareable image. Deliberately takes plain values rather than model
/// objects — ImageRenderer draws it outside the view hierarchy, so it can't
/// rely on environment or SwiftData.
struct ShareCard: View {
    /// 360×450 at 3× renders to 1080×1350, the portrait size social apps like.
    static let size = CGSize(width: 360, height: 450)

    /// Offence lists wrap, so rows are variable height. Rather than guess a row
    /// count, spend a points budget and stop when the next row won't fit.
    private static let rowsBudget: CGFloat = 236
    private static let nameLineHeight: CGFloat = 16
    private static let detailLineHeight: CGFloat = 13
    private static let rowSpacing: CGFloat = 7
    private static let maxDetailLines = 3
    /// Row width left for offences once the padding and £ column are taken out.
    private static let detailWidth: CGFloat = 250
    private static let detailFontSize: CGFloat = 10

    let clubName: String
    let subtitle: String
    let rows: [ShareSummary.Tally]
    let bigLabel: String
    let bigAmount: String
    let closing: String

    private var laidOut: [(tally: ShareSummary.Tally, lines: [String])] {
        var out: [(ShareSummary.Tally, [String])] = []
        var remaining = Self.rowsBudget
        for tally in rows {
            let packed = ShareSummary.pack(
                tally.details,
                maxWidth: Self.detailWidth,
                fontSize: Self.detailFontSize
            )
            let lines = Array(packed.prefix(Self.maxDetailLines))
            let cost = Self.nameLineHeight
                + CGFloat(lines.count) * Self.detailLineHeight
                + Self.rowSpacing
            if remaining - cost < 0 { break }
            remaining -= cost
            out.append((tally, lines))
        }
        return out
    }

    var body: some View {
        let shown = laidOut
        let hidden = rows.count - shown.count

        VStack(alignment: .leading, spacing: 0) {
            Text(ShareSummary.headline(clubName))
                .font(.system(size: 21, weight: .bold))
                .tracking(1.1)
                .foregroundStyle(Theme.beige)
            Text(subtitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textDim)
                .padding(.top, 3)

            Rectangle()
                .fill(Theme.surfaceHi)
                .frame(height: 1)
                .padding(.vertical, 12)

            VStack(spacing: Self.rowSpacing) {
                ForEach(Array(shown.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.tally.name)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.beige)
                                .lineLimit(1)
                            ForEach(Array(entry.lines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: Self.detailFontSize))
                                    .foregroundStyle(Theme.textDim)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 6)
                        Text(Money.string(entry.tally.amountPence))
                            .font(.tally(15, .bold))
                            .foregroundStyle(Theme.accent)
                    }
                }

                if hidden > 0 {
                    HStack {
                        Text("…and \(hidden) more")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textFaint)
                        Spacer()
                    }
                }
            }

            Spacer(minLength: 12)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(bigAmount)
                        .font(.tally(30, .bold))
                        .foregroundStyle(Theme.accent)
                    Text(bigLabel)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textDim)
                    Spacer()
                }

                if !closing.isEmpty {
                    Text(closing)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textFaint)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(24)
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        .background(Theme.bg)
    }
}

// MARK: - Rendering

enum ShareCardRenderer {
    @MainActor
    static func png(from card: ShareCard) -> UIImage? {
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        renderer.isOpaque = true
        return renderer.uiImage
    }
}

/// Lets ShareLink hand a PNG to WhatsApp, Photos, Mail and friends.
struct SharePNG: Transferable {
    let image: UIImage
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            item.image.pngData() ?? Data()
        }
        .suggestedFileName { $0.filename }
    }
}
