//
//  GeminiAPI.swift
//  leanring-buddy
//
//  Free replacement for ClaudeAPI. Same method signatures, but talks straight
//  to Google's Gemini API (free tier) instead of going through the Cloudflare
//  Worker. No proxy is needed because the key is read locally on your Mac.
//
//  Where the API key comes from (first match wins):
//    1. GEMINI_API_KEY environment variable (Xcode scheme > Run > Arguments)
//    2. UserDefaults key "GeminiAPIKey"  (defaults write <bundle id> GeminiAPIKey "...")
//    3. Info.plist key "GeminiAPIKey"
//
//  Optional: set GEMINI_MODEL (environment variable) to try a different model
//  without rebuilding.
//

import Foundation

class GeminiAPI {

    /// Model IDs change often. Check Google AI Studio for models that are
    /// currently free, and change these two lines (or set GEMINI_MODEL) if a
    /// request fails with "model not found" or "limit: 0".
    static let defaultModel = "gemini-3.6-flash"
    static let liteModel = "gemini-3.5-flash-lite"

    var model: String
    private let session: URLSession

    private static let baseURLString = "https://generativelanguage.googleapis.com/v1beta/models"

    init(model: String = GeminiAPI.defaultModel) {
        self.model = model

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 300
        config.waitsForConnectivity = true
        config.urlCache = nil
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
    }

    // MARK: - Configuration

    static func loadAPIKey() -> String? {
        if let value = ProcessInfo.processInfo.environment["GEMINI_API_KEY"],
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let value = UserDefaults.standard.string(forKey: "GeminiAPIKey"),
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return AppBundleConfiguration.stringValue(forKey: "GeminiAPIKey")
    }

    /// The model actually sent to Google. Falls back to the default if a
    /// leftover Claude model name is still saved in settings.
    private func resolvedModelID() -> String {
        if let override = ProcessInfo.processInfo.environment["GEMINI_MODEL"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return override.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if model.hasPrefix("gemini") || model.hasPrefix("gemma") {
            return model
        }
        return Self.defaultModel
    }

    private func makeAPIRequest(apiKey: String, streaming: Bool) -> URLRequest {
        let method = streaming ? "streamGenerateContent?alt=sse" : "generateContent"
        let url = URL(string: "\(Self.baseURLString)/\(resolvedModelID()):\(method)")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        return request
    }

    private func missingKeyError() -> NSError {
        NSError(
            domain: "GeminiAPI",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey:
                "No Gemini API key found. Set GEMINI_API_KEY in the Xcode scheme (Product > Scheme > Edit Scheme > Run > Arguments)."]
        )
    }

    // MARK: - Request building

    /// Detects the MIME type of image data by inspecting the first bytes.
    private func detectImageMediaType(for imageData: Data) -> String {
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            if [UInt8](imageData.prefix(4)) == pngSignature {
                return "image/png"
            }
        }
        return "image/jpeg"
    }

    private func buildRequestBody(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)],
        userPrompt: String,
        maxOutputTokens: Int,
        structuredOutput: Bool
    ) -> [String: Any] {

        var contents: [[String: Any]] = []

        // Earlier turns. Gemini calls the assistant role "model".
        for (userPlaceholder, assistantResponse) in conversationHistory {
            contents.append(["role": "user", "parts": [["text": userPlaceholder]]])
            contents.append(["role": "model", "parts": [["text": assistantResponse]]])
        }

        // Newest turn: every labeled screenshot, then the spoken question.
        var currentParts: [[String: Any]] = []
        for image in images {
            currentParts.append([
                "inline_data": [
                    "mime_type": detectImageMediaType(for: image.data),
                    "data": image.data.base64EncodedString()
                ]
            ])
            currentParts.append(["text": image.label])
        }
        currentParts.append(["text": userPrompt])
        contents.append(["role": "user", "parts": currentParts])

        var generationConfig: [String: Any] = [
            "maxOutputTokens": maxOutputTokens,
            "temperature": structuredOutput ? 0.55 : 0.7
        ]
        if structuredOutput {
            generationConfig["responseMimeType"] = "application/json"
            generationConfig["responseSchema"] = [
                "type": "OBJECT",
                "properties": [
                    "s": [
                        "type": "ARRAY",
                        "maxItems": 5,
                        "items": [
                            "type": "OBJECT",
                            "properties": [
                                "t": ["type": "STRING"],
                                "p": [
                                    "type": "OBJECT",
                                    "properties": [
                                        "x": ["type": "NUMBER"],
                                        "y": ["type": "NUMBER"],
                                        "l": ["type": "STRING"],
                                        "n": ["type": "INTEGER"]
                                    ],
                                    "required": ["x", "y"]
                                ],
                                "d": [
                                    "type": "ARRAY",
                                    "maxItems": 4,
                                    "items": [
                                        "type": "OBJECT",
                                        "properties": [
                                            "k": ["type": "STRING", "enum": ["c", "b", "a", "l"]],
                                            "v": ["type": "ARRAY", "items": ["type": "NUMBER"]],
                                            "l": ["type": "STRING"],
                                            "n": ["type": "INTEGER"]
                                        ],
                                        "required": ["k", "v"]
                                    ]
                                ],
                                "g": ["type": "STRING"]
                            ],
                            "required": ["t"]
                        ]
                    ]
                ],
                "required": ["s"]
            ]
        }

        return [
            "system_instruction": ["parts": [["text": systemPrompt]]],
            "contents": contents,
            // Thinking tokens can count toward this limit, so keep it roomy.
            "generationConfig": generationConfig
        ]
    }

    // MARK: - Response parsing

    private static func extractText(from payload: [String: Any]) -> String {
        guard let candidates = payload["candidates"] as? [[String: Any]],
              let content = candidates.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return ""
        }
        var combinedText = ""
        for part in parts {
            // Skip hidden "thinking" text if the API ever includes it.
            if (part["thought"] as? Bool) == true { continue }
            if let text = part["text"] as? String {
                combinedText += text
            }
        }
        return combinedText
    }

    private static func describeEmptyResponse(finishReason: String?, blockReason: String?) -> NSError {
        let details = "finishReason: \(finishReason ?? "none"), blockReason: \(blockReason ?? "none")"
        return NSError(
            domain: "GeminiAPI",
            code: -3,
            userInfo: [NSLocalizedDescriptionKey: "Gemini returned no text (\(details))."]
        )
    }

    // MARK: - Public API (same shape as ClaudeAPI)

    /// Send a vision request to Gemini with streaming.
    /// Calls `onTextChunk` on the main actor with the full text accumulated so far.
    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        structuredOutput: Bool = false,
        onTextChunk: @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        guard let apiKey = Self.loadAPIKey() else { throw missingKeyError() }

        var request = makeAPIRequest(apiKey: apiKey, streaming: true)
        let body = buildRequestBody(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            maxOutputTokens: 2048,
            structuredOutput: structuredOutput
        )
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData
        let payloadMB = Double(bodyData.count) / 1_048_576.0
        print("🌐 Gemini streaming request (\(resolvedModelID())): \(String(format: "%.1f", payloadMB))MB, \(images.count) image(s)")

        let (byteStream, response) = try await session.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "GeminiAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"]
            )
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBodyChunks: [String] = []
            for try await line in byteStream.lines {
                errorBodyChunks.append(line)
            }
            let errorBody = errorBodyChunks.joined(separator: "\n")
            throw NSError(
                domain: "GeminiAPI",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Gemini API error (\(httpResponse.statusCode)): \(errorBody)"]
            )
        }

        // Server-sent events: every event is a line like  data: {json}
        var accumulatedResponseText = ""
        var lastFinishReason: String?
        var lastBlockReason: String?

        for try await line in byteStream.lines {
            guard line.hasPrefix("data:") else { continue }
            let jsonString = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard jsonString != "[DONE]",
                  let jsonData = jsonString.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }

            if let candidates = payload["candidates"] as? [[String: Any]],
               let reason = candidates.first?["finishReason"] as? String {
                lastFinishReason = reason
            }
            if let feedback = payload["promptFeedback"] as? [String: Any],
               let reason = feedback["blockReason"] as? String {
                lastBlockReason = reason
            }

            let textChunk = Self.extractText(from: payload)
            if !textChunk.isEmpty {
                accumulatedResponseText += textChunk
                let currentAccumulatedText = accumulatedResponseText
                await onTextChunk(currentAccumulatedText)
            }
        }

        guard !accumulatedResponseText.isEmpty else {
            throw Self.describeEmptyResponse(finishReason: lastFinishReason, blockReason: lastBlockReason)
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: accumulatedResponseText, duration: duration)
    }

    /// Non-streaming version for short requests.
    func analyzeImage(
        images: [(data: Data, label: String)],
        systemPrompt: String,
        conversationHistory: [(userPlaceholder: String, assistantResponse: String)] = [],
        userPrompt: String,
        structuredOutput: Bool = false
    ) async throws -> (text: String, duration: TimeInterval) {
        let startTime = Date()

        guard let apiKey = Self.loadAPIKey() else { throw missingKeyError() }

        var request = makeAPIRequest(apiKey: apiKey, streaming: false)
        let body = buildRequestBody(
            images: images,
            systemPrompt: systemPrompt,
            conversationHistory: conversationHistory,
            userPrompt: userPrompt,
            maxOutputTokens: 1024,
            structuredOutput: structuredOutput
        )
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let responseString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "GeminiAPI",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "Gemini API error: \(responseString)"]
            )
        }

        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(
                domain: "GeminiAPI",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response format"]
            )
        }

        let text = Self.extractText(from: payload)
        guard !text.isEmpty else {
            let finishReason = (payload["candidates"] as? [[String: Any]])?.first?["finishReason"] as? String
            let blockReason = (payload["promptFeedback"] as? [String: Any])?["blockReason"] as? String
            throw Self.describeEmptyResponse(finishReason: finishReason, blockReason: blockReason)
        }

        let duration = Date().timeIntervalSince(startTime)
        return (text: text, duration: duration)
    }

    /// Asks Gemini to draw a diagram as a self-contained HTML/SVG fragment.
    /// Text only (no screenshot). Used by the diagram window.
    func generateDiagramHTML(
        description: String,
        userQuestion: String,
        systemPrompt: String
    ) async throws -> String {
        guard let apiKey = Self.loadAPIKey() else { throw missingKeyError() }

        var request = makeAPIRequest(apiKey: apiKey, streaming: false)
        request.timeoutInterval = 180

        let requestText = "diagram request: \(description)\n\nthe user's question was: \(userQuestion)"
        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": systemPrompt]]],
            "contents": [["role": "user", "parts": [["text": requestText]]]],
            // Diagrams are long, and thinking tokens count toward this limit.
            "generationConfig": [
                "maxOutputTokens": 16000,
                "temperature": 0.25
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        print("📐 Diagram request (\(resolvedModelID())): \(description)")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let responseString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "GeminiAPI",
                code: (response as? HTTPURLResponse)?.statusCode ?? -1,
                userInfo: [NSLocalizedDescriptionKey: "Gemini API error: \(responseString.prefix(300))"]
            )
        }

        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "GeminiAPI", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid response format"])
        }

        let text = Self.extractText(from: payload)
        guard !text.isEmpty else {
            let finishReason = (payload["candidates"] as? [[String: Any]])?.first?["finishReason"] as? String
            let blockReason = (payload["promptFeedback"] as? [String: Any])?["blockReason"] as? String
            throw Self.describeEmptyResponse(finishReason: finishReason, blockReason: blockReason)
        }
        return text
    }
}
