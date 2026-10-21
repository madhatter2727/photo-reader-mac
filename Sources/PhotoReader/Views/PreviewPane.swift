import AppKit
import SwiftUI

struct PreviewPane: View {
    @EnvironmentObject private var session: ReaderSession
    var targeted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(session.preview == nil ? 0.45 : 1))
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        targeted ? PhotoReaderStyle.accent : Color.secondary.opacity(0.45),
                        style: StrokeStyle(lineWidth: targeted ? 2 : 1.5, dash: dash)
                    )
                dropContent
                    .padding(16)
                if session.loading {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(.black.opacity(0.08))
                        ProgressView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minHeight: 280)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onTapGesture { session.openPanel() }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(session.preview == nil ? "Drop a photo, screenshot or PDF" : "Replace picture")

            if session.isPDF {
                Stepper(
                    value: Binding(
                        get: { session.page },
                        set: { session.showPDFPage($0) }
                    ),
                    in: 1...max(session.pageCount, 1)
                ) {
                    Text("Page \(session.page) of \(session.pageCount)")
                        .font(.callout)
                        .monospacedDigit()
                }
                .disabled(session.loading)
            }

            if !session.filename.isEmpty {
                Text(session.filename)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.12), value: targeted)
    }

    private var dash: [CGFloat] {
        if targeted || session.preview == nil { return [8, 6] }
        return []
    }

    @ViewBuilder
    private var dropContent: some View {
        if let image = session.preview {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(session.filename.isEmpty ? "Picture" : session.filename)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Drop a photo, screenshot or PDF")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Click to choose a file, or paste with ⌘V.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
