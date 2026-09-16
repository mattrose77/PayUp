import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

/// The shareable image. Deliberately takes plain values rather than model
/// objects — ImageRenderer draws it outside the view hierarchy, so it can't
/// rely on environment or SwiftData.
struct ShareCard: View {
    /// Width is fixed so every card lands in a chat at the same size; 360 at 3×
    /// renders to 1080px wide. Height is whatever the rows need.
    static let width: CGFloat = 360
    /// Below this the card stops looking like a card and starts looking like a
    /// crop, so a one-fine week is padded out to a portrait shape.
    static let minHeight: CGFloat = 420

    private static let padding: CGFloat = 24
    /// Row width left for offences once the padding and £ column are taken out.
    private static let detailWidth: CGFloat = 250
    private static let detailFontSize: CGFloat = 10
    private static let normalRowSpacing: CGFloat = 7
    private static let tightRowSpacing: CGFloat = 4
    /// A full squad is ~14. Past that the card is getting long enough that
    /// tightening the gaps is worth it — the type stays the size it was.
    private static let tightenBeyondRows = 18

    let clubName: String
    let subtitle: String
    let rows: [ShareSummary.Tally]
    let bigLabel: String
    let bigAmount: String
    let closing: String

    /// Every fined player, every offence. Nothing is dropped to fit: the card
    /// grows instead. Hiding a name defeats the point of sending it.
    private var laidOut: [(tally: ShareSummary.Tally, lines: [String])] {
        rows.map { tally in
            (tally, ShareSummary.pack(
                tally.details,
                maxWidth: Self.detailWidth,
                fontSize: Self.detailFontSize
            ))
        }
    }

    private var rowSpacing: CGFloat {
        rows.count > Self.tightenBeyondRows ? Self.tightRowSpacing : Self.normalRowSpacing
    }

    var body: some View {
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

            VStack(spacing: rowSpacing) {
                ForEach(Array(laidOut.enumerated()), id: \.offset) { _, entry in
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
            }

            // Sits directly under the last row. Pinning it to the bottom of a
            // fixed frame is what used to leave a hole above it.
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
            .padding(.top, 18)
        }
        .padding(Self.padding)
        // No height: the card is as tall as its rows. The minimum only bites on
        // very short lists, and centring keeps the top and bottom margins equal
        // rather than dropping all the slack in one place.
        .frame(width: Self.width, alignment: .topLeading)
        .frame(minHeight: Self.minHeight)
        .background(Theme.bg)
    }
}

// MARK: - Rendering

enum ShareCardRenderer {
    /// The share sheet's preview and the exported file both come through here,
    /// so what you see is what gets sent.
    @MainActor
    static func png(from card: ShareCard) -> UIImage? {
        let renderer = ImageRenderer(content: card)
        // Propose the fixed width and leave the height unspecified, so the
        // snapshot is the view's own intrinsic height rather than a guess.
        renderer.proposedSize = ProposedViewSize(width: ShareCard.width, height: nil)
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
