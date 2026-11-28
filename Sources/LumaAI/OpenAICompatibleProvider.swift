import Foundation
import LumaDomain

/// OpenAI 兼容的 chat/completions 后端：
/// DeepSeek / Kimi / GLM / 通义千问 / 豆包 / OpenAI / 本地运行时 / 自定义。
package struct OpenAICompatibleChatProvider: AIChatProvider {
    package let descriptor: AIChatProviderDescriptor

    package init(config: AIConfig) {
        descriptor = AIChatProviderDescriptor(id: config.provider.rawValue,
                                             title: config.provider.title,
                                             capabilities: config.requestCapabilities,
                                             isLocal: config.provider == .local)
    }

    package func complete(_ request: AIChatRequest) async throws -> AICompletion {
        let config = request.config
        let key = request.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // 本地运行时（Ollama / LM Studio）不校验 API Key。
        if config.provider.requiresAPIKey, key.isEmpty { throw AIError.missingKey }
        let model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw AIError.server("请先在设置 › 助手中填写模型名称")
        }
        guard let url = Self.endpointURL(for: config.baseURL) else { throw AIError.invalidBaseURL }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 120
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty {
            urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        // Claude 的 OpenAI 兼容层需要显式版本头。
        if config.provider == .anthropic {
            urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }

        var body: [String: Any] = [
            "model": model,
            "messages": request.messages.map(Self.encode),
            "stream": false
        ]
        // o 系列与 GPT-5 是推理模型：不接受 temperature，且 token 字段名是 max_completion_tokens。
        // Claude 4.7 起也不再接受 temperature，这里统一省略。
        if Self.isReasoningModel(model) {
            body["max_completion_tokens"] = config.maxTokens
        } else {
            if config.provider != .anthropic { body["temperature"] = 0.2 }
            body["max_tokens"] = config.maxTokens
        }
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.parameters
                    ]
                ]
            }
            body["tool_choice"] = "auto"
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            if (error as? URLError)?.code == .cancelled || Task.isCancelled {
                throw AIError.cancelled
            }
            throw AIError.server("网络请求失败：\(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else { throw AIError.badResponse }
        guard (200...299).contains(http.statusCode) else {
            throw Self.httpError(status: http.statusCode, data: data)
        }
        return try Self.parseCompletion(from: data)
    }

    // MARK: - 流式

    package func stream(_ request: AIChatRequest) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var emittedText = false
                do {
                    let urlRequest = try Self.makeStreamRequest(request)
                    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
                    guard let http = response as? HTTPURLResponse else { throw AIError.badResponse }
                    guard (200...299).contains(http.statusCode) else {
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                            if data.count >= 4096 { break }
                        }
                        throw Self.httpError(status: http.statusCode, data: data)
                    }

                    var content = ""
                    var thinking = ""
                    var usage: [String: Any]?
                    var calls: [Int: (id: String, name: String, arguments: String)] = [:]
                    for try await line in bytes.lines {
                        if Task.isCancelled { throw AIError.cancelled }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

                        // 用量通常出现在最后一帧；也可能单独发一帧（没有 choices）。
                        if let rawUsage = root["usage"] as? [String: Any] {
                            usage = rawUsage
                        }
                        guard let choices = root["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any] else { continue }

                        if let piece = (delta["reasoning_content"] as? String)
                            ?? (delta["reasoning"] as? String), !piece.isEmpty {
                            thinking += piece
                            continuation.yield(.reasoning(piece))
                        }
                        if let piece = delta["content"] as? String, !piece.isEmpty {
                            content += piece
                            emittedText = true
                            continuation.yield(.text(piece))
                        }
                        if let rawCalls = delta["tool_calls"] as? [[String: Any]] {
                            for raw in rawCalls {
                                let index = raw["index"] as? Int ?? calls.count
                                var entry = calls[index] ?? (id: "", name: "", arguments: "")
                                if let id = raw["id"] as? String, !id.isEmpty {
                                    entry.id = id
                                }
                                if let function = raw["function"] as? [String: Any] {
                                    if let name = function["name"] as? String, !name.isEmpty {
                                        entry.name += name
                                    }
                                    if let arguments = function["arguments"] as? String {
                                        entry.arguments += arguments
                                    }
                                }
                                calls[index] = entry
                            }
                        }
                    }

                    let toolCalls = calls.keys.sorted().compactMap { key -> AIToolCall? in
                        guard let entry = calls[key], !entry.name.isEmpty else { return nil }
                        return AIToolCall(id: entry.id.isEmpty ? "call_\(key)" : entry.id,
                                          name: entry.name,
                                          arguments: entry.arguments.isEmpty ? "{}" : entry.arguments)
                    }

                    // 端点声明支持流式但没有任何内容：退回一次性请求，避免空回答。
                    if !emittedText, toolCalls.isEmpty {
                        let completion = try await complete(request)
                        if !completion.content.isEmpty {
                            continuation.yield(.text(completion.content))
                        }
                        for call in completion.toolCalls { continuation.yield(.toolCall(call)) }
                        continuation.yield(.finished(completion))
                        continuation.finish()
                        return
                    }

                    for call in toolCalls { continuation.yield(.toolCall(call)) }
                    continuation.yield(.finished(AICompletion(
                        content: content.trimmingCharacters(in: .whitespacesAndNewlines),
                        toolCalls: toolCalls,
                        reasoning: thinking.isEmpty ? nil : thinking,
                        promptTokens: usage?["prompt_tokens"] as? Int,
                        completionTokens: usage?["completion_tokens"] as? Int
                    )))
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        continuation.finish(throwing: AIError.cancelled)
                        return
                    }
                    // 部分兼容端点不支持流式：还没吐出任何文本时退回一次性请求。
                    if !emittedText {
                        do {
                            let completion = try await complete(request)
                            if !completion.content.isEmpty {
                                continuation.yield(.text(completion.content))
                            }
                            for call in completion.toolCalls { continuation.yield(.toolCall(call)) }
                            continuation.yield(.finished(completion))
                            continuation.finish()
                            return
                        } catch {
                            continuation.finish(throwing: error)
                            return
                        }
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func makeStreamRequest(_ request: AIChatRequest) throws -> URLRequest {
        let config = request.config
        let key = request.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.provider.requiresAPIKey, key.isEmpty { throw AIError.missingKey }
        let model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            throw AIError.server("请先在设置 › 助手中填写模型名称")
        }
        guard let url = endpointURL(for: config.baseURL) else { throw AIError.invalidBaseURL }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 180
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !key.isEmpty {
            urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if config.provider == .anthropic {
            urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }

        var body: [String: Any] = [
            "model": model,
            "messages": request.messages.map(encode),
            "stream": true
        ]
        if isReasoningModel(model) {
            body["max_completion_tokens"] = config.maxTokens
        } else {
            if config.provider != .anthropic { body["temperature"] = 0.2 }
            body["max_tokens"] = config.maxTokens
        }
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": tool.parameters
                    ]
                ]
            }
            body["tool_choice"] = "auto"
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        return urlRequest
    }

    /// 推理模型（o 系列 / GPT-5，含 OpenRouter 的 openai/ 前缀）走不同的参数。
    private static func isReasoningModel(_ model: String) -> Bool {
        var name = model.lowercased()
        if name.hasPrefix("openai/") { name.removeFirst("openai/".count) }
        return name.hasPrefix("o1") || name.hasPrefix("o3") || name.hasPrefix("o4")
            || name.hasPrefix("gpt-5")
    }

    private static func encode(_ message: AIRequestMessage) -> [String: Any] {
        var payload: [String: Any] = ["role": message.role]

        if message.role == "tool" {
            payload["content"] = message.text
            payload["tool_call_id"] = message.toolCallID ?? ""
            return payload
        }

        if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
            payload["content"] = message.text.isEmpty ? NSNull() : message.text
            payload["tool_calls"] = toolCalls.map { call in
                [
                    "id": call.id,
                    "type": "function",
                    "function": [
                        "name": call.name,
                        "arguments": call.arguments
                    ]
                ]
            }
            return payload
        }

        if message.images.isEmpty {
            payload["content"] = message.text
        } else {
            var parts: [[String: Any]] = [["type": "text", "text": message.text]]
            for image in message.images {
                parts.append(["type": "image_url", "image_url": ["url": image]])
            }
            payload["content"] = parts
        }
        return payload
    }

    private static func endpointURL(for baseURL: String) -> URL? {
        var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        let endpoint = base.hasSuffix("/chat/completions") ? base : base + "/chat/completions"
        guard let url = URL(string: endpoint), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    private static func httpError(status: Int, data: Data) -> AIError {
        let message = serverMessage(from: data)
        switch status {
        case 401, 403:
            return .unauthorized
        case 429:
            return .rateLimited
        default:
            return .server(message ?? "请求失败（HTTP \(status)）")
        }
    }

    private static func serverMessage(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8).map { String($0.prefix(300)) }
        }
        if let error = root["error"] as? [String: Any] {
            return error["message"] as? String
        }
        if let message = root["message"] as? String {
            return message
        }
        return nil
    }

    private static func parseCompletion(from data: Data) throws -> AICompletion {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw AIError.badResponse
        }

        var toolCalls: [AIToolCall] = []
        if let rawCalls = message["tool_calls"] as? [[String: Any]] {
            for raw in rawCalls {
                guard let id = raw["id"] as? String,
                      let function = raw["function"] as? [String: Any],
                      let name = function["name"] as? String else { continue }
                let arguments: String
                if let string = function["arguments"] as? String {
                    arguments = string
                } else if let object = function["arguments"],
                          let argumentData = try? JSONSerialization.data(withJSONObject: object),
                          let string = String(data: argumentData, encoding: .utf8) {
                    arguments = string
                } else {
                    arguments = "{}"
                }
                toolCalls.append(AIToolCall(id: id, name: name, arguments: arguments))
            }
        }

        let content = parseContent(from: message)
        guard !content.isEmpty || !toolCalls.isEmpty else { throw AIError.badResponse }
        let usage = root["usage"] as? [String: Any]
        return AICompletion(
            content: content,
            toolCalls: toolCalls,
            reasoning: (message["reasoning_content"] as? String) ?? (message["reasoning"] as? String),
            promptTokens: usage?["prompt_tokens"] as? Int,
            completionTokens: usage?["completion_tokens"] as? Int
        )
    }

    private static func parseContent(from message: [String: Any]) -> String {
        if let content = message["content"] as? String {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 少数兼容实现会把 content 拆成多段。
        if let parts = message["content"] as? [[String: Any]] {
            let text = parts.compactMap { $0["text"] as? String }.joined()
            if !text.isEmpty { return text }
        }
        if let reasoning = message["reasoning_content"] as? String {
            return reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }
}
