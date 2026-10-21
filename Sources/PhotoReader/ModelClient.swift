import Foundation

struct Outgoing: Sendable {
    enum Role: String, Sendable {
        case user
        case assistant
    }

    var role: Role
    var text: String
    var imageDataURL: String?

    static func user(_ text: String, image: String? = nil) -> Outgoing {
        Outgoing(role: .user, text: text, imageDataURL: image)
    }

    static func assistant(_ text: String) -> Outgoing {
        Outgoing(role: .assistant, text: text, imageDataURL: nil)
    }
}

enum ModelClientError: LocalizedError {
    case unreachable
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .unreachable:
            return "The model server is not reachable."
        case .rejected(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "The model rejected the request." }
            if trimmed.count > 500 { return String(trimmed.prefix(500)) }
            return trimmed
        }
    }
}

@MainActor
enum ModelClient {
    static let describePrompt = "Describe this image in two short sentences of plain English."
    static let extractPrompt = "Transcribe all text in this image exactly. Preserve the line breaks. Output only the transcription."

    static func stream(messages: [Outgoing], onVisible: (String) -> Void) async throws -> String {
        let request = try makeRequest(messages: messages)
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else {
                throw ModelClientError.unreachable
            }
            guard (200...299).contains(http.statusCode) else {
                let message = await failureMessage(from: bytes)
                throw ModelClientError.rejected(message)
            }
            var raw = ""
            for try await line in bytes.lines {
                try Task.checkCancellation()
                if let piece = try contentDelta(from: line) {
                    raw += piece
                    onVisible(ThinkStrip.visible(raw, flush: false))
                }
            }
            let finalText = ThinkStrip.visible(raw, flush: true)
            onVisible(finalText)
            return finalText
        } catch let error as ModelClientError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ModelClientError.unreachable
        }
    }

    private static func makeRequest(messages: [Outgoing]) throws -> URLRequest {
        guard let url = URL(string: "http://127.0.0.1:8093/v1/chat/completions") else {
            throw ModelClientError.unreachable
        }
        let payload: [String: Any] = [
            "model": "local",
            "messages": messages.map(messageJSON),
            "temperature": 0.2,
            "max_tokens": 1024,
            "stream": true,
            "chat_template_kwargs": ["enable_thinking": false]
        ]
        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw ModelClientError.rejected("Could not build the request.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }

    private static func messageJSON(_ message: Outgoing) -> [String: Any] {
        if message.role == .assistant {
            return ["role": "assistant", "content": message.text]
        }
        var parts: [[String: Any]] = [
            ["type": "text", "text": message.text]
        ]
        if let image = message.imageDataURL {
            parts.append([
                "type": "image_url",
                "image_url": ["url": image]
            ])
        }
        return ["role": "user", "content": parts]
    }

    private static func contentDelta(from line: String) throws -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload.isEmpty || payload == "[DONE]" { return nil }
        guard let data = payload.data(using: .utf8) else { return nil }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            return nil
        }
        guard let json = object as? [String: Any] else { return nil }
        if let error = json["error"] {
            throw ModelClientError.rejected(message(from: error))
        }
        guard
            let choices = json["choices"] as? [[String: Any]],
            let delta = choices.first?["delta"] as? [String: Any],
            let content = delta["content"] as? String,
            !content.isEmpty
        else {
            return nil
        }
        return content
    }

    private static func failureMessage(from bytes: URLSession.AsyncBytes) async -> String {
        var text = ""
        do {
            for try await line in bytes.lines {
                text += line
                if text.count > 4000 { break }
            }
        } catch {
            // Keep the bytes already read.
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "The model rejected the request." }
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] {
            return message(from: error)
        }
        return trimmed
    }

    private static func message(from error: Any) -> String {
        if let text = error as? String { return text }
        if let object = error as? [String: Any] {
            if let text = object["message"] as? String { return text }
            if let text = object["error"] as? String { return text }
        }
        return "The model returned an error."
    }
}

/// Drops `<think>…</think>` as tokens arrive, and holds a partial tag at the end of the buffer.
enum ThinkStrip {
    private static let openTag = Array("<think>")
    private static let closeTag = Array("</think>")

    static func visible(_ raw: String, flush: Bool) -> String {
        let chars = Array(raw)
        var out: [Character] = []
        var index = 0
        while index < chars.count {
            if match(chars, at: index, tag: openTag) {
                if let end = findClose(chars, from: index + openTag.count) {
                    index = end
                    continue
                }
                return trimLeading(out)
            }
            if chars[index] == "<", !flush,
               isPrefix(chars, at: index, tag: openTag) || isPrefix(chars, at: index, tag: closeTag) {
                return trimLeading(out)
            }
            out.append(chars[index])
            index += 1
        }
        return trimLeading(out)
    }

    private static func match(_ chars: [Character], at index: Int, tag: [Character]) -> Bool {
        guard index + tag.count <= chars.count else { return false }
        for offset in 0..<tag.count {
            if !same(chars[index + offset], tag[offset]) { return false }
        }
        return true
    }

    private static func isPrefix(_ chars: [Character], at index: Int, tag: [Character]) -> Bool {
        let rest = chars.count - index
        guard rest > 0, rest <= tag.count else { return false }
        for offset in 0..<rest {
            if !same(chars[index + offset], tag[offset]) { return false }
        }
        return true
    }

    private static func findClose(_ chars: [Character], from start: Int) -> Int? {
        guard start <= chars.count else { return nil }
        var index = start
        while index + closeTag.count <= chars.count {
            if match(chars, at: index, tag: closeTag) {
                return index + closeTag.count
            }
            index += 1
        }
        return nil
    }

    private static func same(_ lhs: Character, _ rhs: Character) -> Bool {
        if lhs == rhs { return true }
        return String(lhs).lowercased() == String(rhs).lowercased()
    }

    private static func trimLeading(_ chars: [Character]) -> String {
        var index = 0
        while index < chars.count, chars[index].isWhitespace {
            index += 1
        }
        return String(chars[index...])
    }
}
