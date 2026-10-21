import AppKit
import SwiftUI

struct ReadingPane: View {
    @EnvironmentObject private var session: ReaderSession
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            if let banner = session.banner, !banner.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(banner)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
                .foregroundStyle(PhotoReaderStyle.error)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PhotoReaderStyle.error.opacity(0.08))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        descriptionBox
                        transcriptBox
                        if !session.turns.isEmpty {
                            VStack(alignment: .leading, spacing: 14) {
                                ForEach(session.turns) { turn in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(turn.question)
                                            .font(.callout.weight(.semibold))
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Text(turn.answer.isEmpty ? "…" : turn.answer)
                                            .font(.callout)
                                            .foregroundStyle(turn.answer.isEmpty ? .secondary : .primary)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .id(turn.id)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: session.turns.count) { _, _ in
                    if let id = session.turns.last?.id {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }

            Divider()
            askBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: session.transcript) { _, _ in
            copied = false
        }
    }

    private var descriptionBox: some View {
        GroupBox {
            bodyCopy(
                session.descriptionText,
                phase: session.descriptionPhase,
                idle: "A short description will appear here.",
                monospaced: false
            )
            .padding(.top, 2)
        } label: {
            HStack(spacing: 8) {
                Label("Description", systemImage: "text.quote")
                Spacer(minLength: 8)
                if session.descriptionPhase == .reading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transcriptBox: some View {
        GroupBox {
            bodyCopy(
                session.transcript,
                phase: session.transcriptPhase,
                idle: "Text found in the picture will show up here.",
                monospaced: true
            )
            .padding(.top, 2)
        } label: {
            HStack(spacing: 8) {
                Label("Text in image", systemImage: "text.viewfinder")
                Spacer(minLength: 8)
                if session.transcriptPhase == .reading {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(copied ? "Copied" : "Copy") {
                    session.copyTranscript()
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_600_000_000)
                        copied = false
                    }
                }
                .disabled(session.transcriptPhase != .ready || session.transcript.isEmpty)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var askBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Ask", systemImage: "bubble.left.and.bubble.right")
                .font(.headline)
            HStack(spacing: 8) {
                TextField("Ask a question about the picture", text: $session.draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { session.send() }
                Button("Send") { session.send() }
                    .disabled(sendDisabled)
            }
        }
        .padding(16)
    }

    private var sendDisabled: Bool {
        !session.canAsk
            || session.asking
            || session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func bodyCopy(_ text: String, phase: ReaderSession.Phase, idle: String, monospaced: Bool) -> some View {
        let shown = displayText(text, phase: phase, idle: idle)
        let quiet = phase == .idle || (phase == .reading && text.isEmpty)
        let font: Font = monospaced ? .system(.body, design: .monospaced) : .body
        return Text(shown)
            .font(font)
            .foregroundStyle(foreground(phase: phase, quiet: quiet))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineSpacing(2)
    }

    private func displayText(_ text: String, phase: ReaderSession.Phase, idle: String) -> String {
        switch phase {
        case .idle:
            return idle
        case .reading where text.isEmpty:
            return "Reading…"
        case .error where text.isEmpty:
            return "Something went wrong."
        case .reading, .ready, .error:
            return text
        }
    }

    private func foreground(phase: ReaderSession.Phase, quiet: Bool) -> AnyShapeStyle {
        if phase == .error { return AnyShapeStyle(PhotoReaderStyle.error) }
        if quiet { return AnyShapeStyle(.secondary) }
        return AnyShapeStyle(.primary)
    }
}
