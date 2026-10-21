import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum PhotoReaderStyle {
    static let accent = Color(red: 0.22, green: 0.48, blue: 0.34)
    static let ready = Color(nsColor: .systemGreen)
    static let starting = Color(nsColor: .systemOrange)
    static let offline = Color(nsColor: .systemRed)
    static let error = Color(red: 0.62, green: 0.24, blue: 0.20)
}

enum PasteMonitor {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard !event.isARepeat else { return event }
            let flags = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting(.capsLock)
            guard flags == .command, event.charactersIgnoringModifiers?.lowercased() == "v" else {
                return event
            }
            guard Clipboard.shouldInterceptPaste() else { return event }
            Task { @MainActor in
                ReaderSession.shared.pasteFromClipboard()
            }
            return nil
        }
    }
}

enum Clipboard {
    static func shouldInterceptPaste() -> Bool {
        let pasteboard = NSPasteboard.general
        if fieldEditorActive(), let text = pasteboard.string(forType: .string), !text.isEmpty {
            return false
        }
        if hasImage(pasteboard) { return true }
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] {
            return urls.contains(where: ImageLoader.looksSupported)
        }
        return false
    }

    private static func fieldEditorActive() -> Bool {
        NSApp.keyWindow?.firstResponder is NSTextView
    }

    private static func hasImage(_ pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types else { return false }
        let imageTypes: [NSPasteboard.PasteboardType] = [
            .png,
            .tiff,
            NSPasteboard.PasteboardType(UTType.jpeg.identifier),
            NSPasteboard.PasteboardType(UTType.gif.identifier),
            NSPasteboard.PasteboardType(UTType.image.identifier)
        ]
        return imageTypes.contains(where: types.contains)
    }
}

final class PhotoReaderAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable so the window gets keyboard focus.
        focusWindow()
        DispatchQueue.main.async { self.focusWindow() }
        PasteMonitor.install()
        Task { @MainActor in
            ReaderSession.shared.server.startIfNeeded()
            ReaderSession.shared.consumeLaunchArguments()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.last else { return }
        Task { @MainActor in
            ReaderSession.shared.openExternal(url)
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        Task { @MainActor in
            ReaderSession.shared.openExternal(URL(fileURLWithPath: filename))
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func focusWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
}

@main
struct PhotoReaderApp: App {
    @NSApplicationDelegateAdaptor(PhotoReaderAppDelegate.self) private var appDelegate
    @StateObject private var session = ReaderSession.shared

    var body: some Scene {
        WindowGroup("Photo Reader") {
            ContentView()
                .environmentObject(session)
                .environmentObject(session.server)
                .tint(PhotoReaderStyle.accent)
                .frame(minWidth: 920, minHeight: 640)
        }
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") {
                    ReaderSession.shared.openPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .pasteboard) {
                Button("Paste Image") {
                    ReaderSession.shared.pasteFromClipboard()
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            }
        }
    }
}
