import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

struct ChatTurn: Identifiable {
    let id = UUID()
    var question: String
    var answer: String
    var include: Bool

    init(question: String) {
        self.question = question
        self.answer = ""
        self.include = false
    }
}

@MainActor
final class ReaderSession: ObservableObject {
    static let shared = ReaderSession()

    enum Phase: Equatable {
        case idle
        case reading
        case ready
        case error
    }

    let server = ModelServer.shared

    @Published var preview: NSImage?
    @Published var filename = ""
    @Published var isPDF = false
    @Published var page = 1
    @Published var pageCount = 1
    @Published var loading = false
    @Published var banner: String?
    @Published var descriptionText = ""
    @Published var descriptionPhase: Phase = .idle
    @Published var transcript = ""
    @Published var transcriptPhase: Phase = .idle
    @Published var turns: [ChatTurn] = []
    @Published var draft = ""
    @Published var asking = false
    @Published var canAsk = false

    private var dataURL = ""
    private var pdfData: Data?
    private var generation = 0
    private var loadToken = 0
    private var analyzeTask: Task<Void, Never>?
    private var askTask: Task<Void, Never>?
    private var failedBecauseOffline = false
    private var autoRetryBudget = 1
    private var didConsumeArgs = false
    private var lastOpenedPath = ""
    private var lastOpenedAt = Date.distantPast

    private init() {}

    func consumeLaunchArguments() {
        guard !didConsumeArgs else { return }
        didConsumeArgs = true
        let args = CommandLine.arguments.dropFirst().filter { arg in
            !arg.isEmpty && !arg.hasPrefix("-")
        }
        guard let last = args.last else { return }
        let url = URL(fileURLWithPath: last).standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return }
        openExternal(url)
    }

    func openExternal(_ url: URL) {
        guard url.isFileURL else { return }
        let path = url.standardizedFileURL.path
        let now = Date()
        if path == lastOpenedPath && now.timeIntervalSince(lastOpenedAt) < 1.5 { return }
        lastOpenedPath = path
        lastOpenedAt = now
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        ingest(url: url)
    }

    func openPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open a photo or PDF"
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ingest(url: url)
    }

    func pasteFromClipboard() {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL],
           let url = urls.first(where: ImageLoader.looksSupported) {
            ingest(url: url)
            return
        }
        if let data = pasteboard.data(forType: .png) {
            openData(data, filename: "Pasted image.png")
            return
        }
        if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)) {
            openData(data, filename: "Pasted image.jpg")
            return
        }
        if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(UTType.gif.identifier)) {
            openData(data, filename: "Pasted image.gif")
            return
        }
        if let data = pasteboard.data(forType: .tiff) {
            openData(data, filename: "Pasted image.tiff")
            return
        }
        if let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation {
            openData(tiff, filename: "Pasted image.tiff")
            return
        }
        banner = "The clipboard doesn't have an image."
    }

    func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let url = Self.url(from: item), url.isFileURL else { return }
                Task { @MainActor in
                    self.ingest(url: url)
                }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.pdf.identifier) { data, _ in
                guard let data else { return }
                Task { @MainActor in
                    self.openData(data, filename: "Document.pdf")
                }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                guard let data else { return }
                Task { @MainActor in
                    self.openData(data, filename: "Dropped image.png")
                }
            }
            return true
        }
        return false
    }

    func showPDFPage(_ newPage: Int) {
        guard isPDF, let pdfData, !loading else { return }
        guard newPage != page, (1...max(pageCount, 1)).contains(newPage) else { return }
        let previous = page
        page = newPage
        loadToken += 1
        let token = loadToken
        loading = true
        banner = nil
        Task {
            await Task.yield()
            let result = ImageLoader.capture {
                try ImageLoader.renderPDF(data: pdfData, page: newPage)
            }
            guard token == self.loadToken else { return }
            self.loading = false
            switch result {
            case .success(let prepared):
                guard self.page == newPage else { return }
                self.applyRendered(prepared)
            case .failure(let error):
                if self.page == newPage { self.page = previous }
                self.banner = error.localizedDescription
            }
        }
    }

    func copyTranscript() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transcript, forType: .string)
    }

    func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canAsk, !asking, !question.isEmpty, !dataURL.isEmpty else { return }
        draft = ""
        asking = true
        let gen = generation
        let url = dataURL
        var messages: [Outgoing] = []
        for prior in turns where prior.include {
            messages.append(.user(prior.question))
            messages.append(.assistant(prior.answer))
        }
        messages.append(.user(question, image: url))
        let turn = ChatTurn(question: question)
        let turnID = turn.id
        turns.append(turn)
        askTask?.cancel()
        askTask = Task {
            defer {
                if gen == self.generation { self.asking = false }
            }
            do {
                let text = try await ModelClient.stream(messages: messages) { visible in
                    guard gen == self.generation else { return }
                    guard let index = self.turns.firstIndex(where: { $0.id == turnID }) else { return }
                    self.turns[index].answer = visible
                }
                guard gen == self.generation else { return }
                guard let index = self.turns.firstIndex(where: { $0.id == turnID }) else { return }
                let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if clean.isEmpty {
                    self.turns[index].answer = "No answer came back."
                    self.turns[index].include = false
                } else {
                    self.turns[index].answer = clean
                    self.turns[index].include = true
                }
            } catch is CancellationError {
                return
            } catch {
                guard gen == self.generation else { return }
                guard let index = self.turns.firstIndex(where: { $0.id == turnID }) else { return }
                self.turns[index].answer = error.localizedDescription
                self.turns[index].include = false
            }
        }
    }

    func retryIfUnreachable() {
        guard failedBecauseOffline, !dataURL.isEmpty, !loading else { return }
        analyze(dataURL: dataURL)
    }

    private func ingest(url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            banner = "Could not read that file."
            return
        }
        if isDir.boolValue {
            banner = "That is a folder. Drop a photo, screenshot or PDF."
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            banner = "Could not read that file."
            return
        }
        let name = url.lastPathComponent.isEmpty ? "Image" : url.lastPathComponent
        openData(data, filename: name)
    }

    private func openData(_ data: Data, filename: String) {
        loadToken += 1
        let token = loadToken
        loading = true
        banner = nil
        let pdf = Self.treatAsPDF(data, filename: filename)
        Task {
            let result: Result<PreparedImage, ImageLoadError>
            if pdf {
                await Task.yield()
                result = ImageLoader.capture { try ImageLoader.load(data: data, filename: filename) }
            } else {
                result = await Task.detached {
                    ImageLoader.capture { try ImageLoader.load(data: data, filename: filename) }
                }.value
            }
            guard token == self.loadToken else { return }
            self.loading = false
            switch result {
            case .success(let prepared):
                self.applyLoaded(prepared, filename: filename)
            case .failure(let error):
                self.banner = error.localizedDescription
            }
        }
    }

    private func applyLoaded(_ prepared: PreparedImage, filename: String) {
        self.filename = filename
        if let pdf = prepared.pdfData {
            pdfData = pdf
            isPDF = true
            page = prepared.page
            pageCount = max(prepared.pageCount, 1)
        } else {
            pdfData = nil
            isPDF = false
            page = 1
            pageCount = 1
        }
        applyRendered(prepared)
    }

    private func applyRendered(_ prepared: PreparedImage) {
        guard let image = NSImage(data: prepared.encoded) else {
            banner = ImageLoadError.encodeFailed.localizedDescription
            return
        }
        autoRetryBudget = 1
        preview = image
        let url = prepared.dataURL
        dataURL = url
        pageCount = max(prepared.pageCount, 1)
        banner = nil
        analyze(dataURL: url)
    }

    private func analyze(dataURL url: String) {
        analyzeTask?.cancel()
        askTask?.cancel()
        generation += 1
        let gen = generation
        descriptionText = ""
        descriptionPhase = .reading
        transcript = ""
        transcriptPhase = .reading
        turns = []
        canAsk = false
        asking = false
        failedBecauseOffline = false
        analyzeTask = Task {
            var offline = false
            let described = await self.runPass(gen: gen, prompt: ModelClient.describePrompt, url: url) { visible in
                self.descriptionText = visible
            }
            switch described {
            case .cancelled:
                return
            case .text(let value):
                self.descriptionText = value
                self.descriptionPhase = .ready
            case .failed(let message, let unreachable):
                self.descriptionText = message
                self.descriptionPhase = .error
                offline = offline || unreachable
            }
            guard gen == self.generation else { return }
            self.transcriptPhase = .reading
            let extracted = await self.runPass(gen: gen, prompt: ModelClient.extractPrompt, url: url) { visible in
                self.transcript = visible
            }
            switch extracted {
            case .cancelled:
                return
            case .text(let value):
                self.transcript = value
                self.transcriptPhase = .ready
            case .failed(let message, let unreachable):
                self.transcript = message
                self.transcriptPhase = .error
                offline = offline || unreachable
            }
            guard gen == self.generation else { return }
            if offline && self.server.status == .ready && self.autoRetryBudget > 0 {
                self.autoRetryBudget -= 1
                self.analyze(dataURL: url)
                return
            }
            self.failedBecauseOffline = offline
            self.canAsk = true
        }
    }

    private enum PassResult {
        case cancelled
        case text(String)
        case failed(String, unreachable: Bool)
    }

    private func runPass(
        gen: Int,
        prompt: String,
        url: String,
        onVisible: @escaping (String) -> Void
    ) async -> PassResult {
        do {
            let text = try await ModelClient.stream(messages: [.user(prompt, image: url)]) { visible in
                guard gen == self.generation else { return }
                onVisible(visible)
            }
            guard gen == self.generation else { return .cancelled }
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty {
                return .failed("No answer came back.", unreachable: false)
            }
            return .text(clean)
        } catch is CancellationError {
            return .cancelled
        } catch {
            guard gen == self.generation else { return .cancelled }
            let unreachable: Bool
            if let model = error as? ModelClientError, case .unreachable = model {
                unreachable = true
            } else {
                unreachable = false
            }
            return .failed(error.localizedDescription, unreachable: unreachable)
        }
    }

    private static func treatAsPDF(_ data: Data, filename: String) -> Bool {
        if filename.lowercased().hasSuffix(".pdf") { return true }
        return data.starts(with: Data([0x25, 0x50, 0x44, 0x46]))
    }

    private static func url(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let url = item as? NSURL { return url as URL }
        if let string = item as? String { return URL(string: string) }
        if let string = item as? NSString { return URL(string: string as String) }
        if let data = item as? Data {
            if let url = URL(dataRepresentation: data, relativeTo: nil, isAbsolute: true) {
                return url
            }
            if let string = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) {
                return URL(string: string)
            }
        }
        return nil
    }
}
