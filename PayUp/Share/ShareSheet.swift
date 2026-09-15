import SwiftUI

/// Preview of the card that's about to be sent, with copy and share.
struct ShareSheet: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let card: ShareCard
    let filename: String

    @State private var rendered: UIImage?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ScrollView {
                    if let rendered {
                        Image(uiImage: rendered)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    } else {
                        ProgressView()
                            .tint(Theme.accent)
                            .frame(maxWidth: .infinity, minHeight: 280)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                actions
            }
            .screenBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }.foregroundStyle(Theme.textDim)
                }
            }
        }
        .presentationBackground(Theme.bg)
        .task { if rendered == nil { rendered = ShareCardRenderer.png(from: card) } }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button(action: copy) {
                HStack(spacing: 8) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    Text(copied ? "Copied" : "Copy to clipboard")
                }
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(rendered == nil)

            if let rendered {
                ShareLink(
                    item: SharePNG(image: rendered, filename: filename),
                    preview: SharePreview(title, image: Image(uiImage: rendered))
                ) {
                    HStack(spacing: 8) {
                        Image(systemName: "square.and.arrow.up")
                        Text("Share")
                    }
                }
                .buttonStyle(AccentButtonStyle())
            } else {
                Button("Share") {}
                    .buttonStyle(AccentButtonStyle())
                    .disabled(true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private func copy() {
        guard let rendered else { return }
        UIPasteboard.general.image = rendered
        Haptics.bump()
        withAnimation(.snappy(duration: 0.2)) { copied = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeOut(duration: 0.2)) { copied = false }
        }
    }
}
