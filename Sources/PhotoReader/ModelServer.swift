import Combine
import Foundation

@MainActor
final class ModelServer: ObservableObject {
    static let shared = ModelServer()

    enum Status: Equatable {
        case starting
        case ready
        case offline
    }

    @Published private(set) var status: Status = .starting

    private var bootTask: Task<Void, Never>?

    private init() {}

    /// Checks health once. Starts llama-server only when it is down.
    /// The process is left running on quit; One Space uses the same server.
    func startIfNeeded() {
        guard bootTask == nil else { return }
        retry()
    }

    func retry() {
        bootTask?.cancel()
        status = .starting
        bootTask = Task { await self.boot() }
    }

    private func boot() async {
        if await Self.healthOK() {
            guard !Task.isCancelled else { return }
            status = .ready
            return
        }
        guard !Task.isCancelled else { return }
        status = .starting
        await Task.detached {
            Self.submitServer()
        }.value
        guard !Task.isCancelled else { return }

        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if Task.isCancelled { return }
            if await Self.healthOK() {
                guard !Task.isCancelled else { return }
                status = .ready
                return
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            let pause = min(1.0, remaining)
            try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
        }
        if Task.isCancelled { return }
        if await Self.healthOK() {
            status = .ready
        } else {
            status = .offline
        }
    }

    nonisolated private static func healthOK() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:8093/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode)
        } catch {
            return false
        }
    }

    nonisolated private static func submitServer() {
        let label = "com.tara.photoreader.model"
        let script = "exec $HOME/src/llama.cpp/build/bin/llama-server -m $HOME/Models/minicpm-v47/MiniCPM-V-4_7-1B-Q4_K_M.gguf --mmproj $HOME/Models/minicpm-v47/mmproj-model-f16.gguf --host 127.0.0.1 --port 8093 -c 8192 > $HOME/Models/minicpm-v47/llama-server.log 2>&1"
        launchctl(["remove", label])
        launchctl(["submit", "-l", label, "--", "/bin/sh", "-c", script])
    }

    nonisolated private static func launchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return
        }
    }
}
