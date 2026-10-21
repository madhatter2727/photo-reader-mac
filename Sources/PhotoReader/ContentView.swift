import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var session: ReaderSession
    @EnvironmentObject private var server: ModelServer
    @State private var targeted = false

    private static let dropTypes: [UTType] = [
        .fileURL, .image, .pdf, .png, .jpeg, .gif, .tiff, .heic, .webP
    ]

    var body: some View {
        HSplitView {
            PreviewPane(targeted: targeted)
                .frame(minWidth: 300, idealWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
            ReadingPane()
                .frame(minWidth: 380, idealWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Photo Reader")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                StatusPill()
                Button {
                    session.openPanel()
                } label: {
                    Label("Open", systemImage: "folder")
                }
                .help("Open a photo or PDF")
            }
        }
        .modifier(NoToolbarPocket())
        .onDrop(of: Self.dropTypes, isTargeted: $targeted) { providers in
            session.receiveDrop(providers)
        }
        .onAppear {
            session.server.startIfNeeded()
            session.consumeLaunchArguments()
        }
        .onChange(of: server.status) { _, newStatus in
            if newStatus == .ready {
                session.retryIfUnreachable()
            }
        }
        .onOpenURL { url in
            session.openExternal(url)
        }
    }
}

/// macOS 26 extends the toolbar's frosted band over the first scroll view in the
/// detail column. Hide that band and its edge fade.
private struct NoToolbarPocket: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .scrollEdgeEffectHidden(true, for: .all)
        } else {
            content
        }
    }
}
