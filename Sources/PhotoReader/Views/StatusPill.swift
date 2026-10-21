import SwiftUI

struct StatusPill: View {
    @EnvironmentObject private var server: ModelServer

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption)
            if server.status == .offline {
                Button("Retry") { server.retry() }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.semibold))
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.thinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .help("The picture stays on this Mac.")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }

    private var title: String {
        switch server.status {
        case .ready:
            return "Model ready"
        case .starting:
            return "Starting model…"
        case .offline:
            return "Model offline"
        }
    }

    private var color: Color {
        switch server.status {
        case .ready:
            return PhotoReaderStyle.ready
        case .starting:
            return PhotoReaderStyle.starting
        case .offline:
            return PhotoReaderStyle.offline
        }
    }
}
