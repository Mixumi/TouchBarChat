import Foundation
import Testing

@testable import TouchBarChat

@Suite(.serialized)
struct AIAnswerClientTests {
    @Test
    func sendsProfileAndQuestionToExactEndpoint() async throws {
        StubURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "https://example.test/custom/chat/completions?group=test")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test-only")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

            let body = try #require(Self.requestBody(request))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["model"] as? String == "test-model")
            let messages = try #require(json["messages"] as? [[String: String]])
            #expect(messages.count == 2)
            #expect(messages[0]["role"] == "system")
            #expect(messages[0]["content"]?.contains("我有五年产品经验") == true)
            #expect(messages[0]["content"]?.contains("[[TOUCHBARCHAT_WAIT]]") == false)
            #expect(messages[1]["role"] == "user")
            #expect(messages[1]["content"] == "请介绍一下自己")
            return (200, #"{"choices":[{"message":{"content":"我有五年产品经验。"}}]}"#.data(using: .utf8)!)
        }
        defer { StubURLProtocol.handler = nil }

        let answer = try await makeClient().answer(
            endpoint: URL(string: "https://example.test/custom/chat/completions?group=test")!,
            model: "test-model",
            apiKey: "sk-test-only",
            userProfile: "我有五年产品经验",
            question: "请介绍一下自己"
        )
        #expect(answer == "我有五年产品经验。")
    }

    @Test(arguments: InterviewLanguage.allCases)
    func answersUseSelectedLanguageEvenWhenQuestionDiffers(language: InterviewLanguage) async throws {
        let expectedInstruction: [InterviewLanguage: String] = [
            .chinese: "只用简体中文回答",
            .english: "answer only in English",
            .korean: "한국어로만 작성하세요",
            .japanese: "日本語のみで書いてください",
            .russian: "отвечайте только по-русски",
            .french: "répondez uniquement en français",
            .portuguese: "responda somente em português do Brasil",
        ]
        StubURLProtocol.handler = { request in
            let body = try #require(Self.requestBody(request))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let messages = try #require(json["messages"] as? [[String: String]])
            let prompt = try #require(messages.first?["content"])
            #expect(prompt.contains(expectedInstruction[language] ?? "unavailable"))
            #expect(prompt.contains("负责过三个项目"))
            #expect(messages.last?["content"] == "你如何协调项目中的冲突？")
            return (200, Data(#"{"choices":[{"message":{"content":"A concise answer."}}]}"#.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let response = try await makeClient().answer(
            endpoint: URL(string: "https://example.test/v1/chat/completions")!,
            model: "test-model",
            apiKey: "sk-test-only",
            userProfile: "负责过三个项目",
            question: "你如何协调项目中的冲突？",
            language: language
        )
        #expect(response == "A concise answer.")
    }

    @Test @MainActor
    func streamedLiveTurnKeepsAnswerLanguageSeparateFromQuestionLanguage() async throws {
        StubURLProtocol.handler = { request in
            let body = try #require(Self.requestBody(request))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let messages = try #require(json["messages"] as? [[String: String]])
            #expect(messages.first?["content"]?.contains("répondez uniquement en français") == true)
            #expect(messages.first?["content"]?.contains("[[TOUCHBARCHAT_WAIT]]") == true)
            #expect(messages.first?["content"]?.contains("Earlier AI answers are drafts") == true)
            #expect(messages.last?["content"] == "Tell me about your experience")
            return (
                200,
                Data(
                    "data: {\"choices\":[{\"delta\":{\"content\":\"J'ai travaillé sur ce projet.\"}}]}\n\ndata: [DONE]\n\n"
                        .utf8)
            )
        }
        defer { StubURLProtocol.handler = nil }

        var published: [String] = []
        let result = try await makeClient().streamAnswerForLiveTurn(
            endpoint: URL(string: "https://example.test/v1/chat/completions")!,
            model: "test-model",
            apiKey: "sk-test-only",
            userProfile: "",
            question: "Tell me about your experience",
            recentContext: "Earlier question about teamwork",
            language: .french,
            onPartialAnswer: { published.append($0) }
        )
        #expect(result == .answer("J'ai travaillé sur ce projet."))
        #expect(published == ["J'ai travaillé sur ce projet."])
    }

    @Test
    func liveTurnDefersOnlyOnExactTrimmedSentinel() async throws {
        var requestCount = 0
        StubURLProtocol.handler = { request in
            requestCount += 1
            let body = try #require(Self.requestBody(request))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let messages = try #require(json["messages"] as? [[String: String]])
            #expect(messages.count == 2)
            #expect(messages[0]["content"]?.contains("[[TOUCHBARCHAT_WAIT]]") == true)
            #expect(messages[1]["content"] == "我想问的是，关于你之前的")
            return (200, Data(#"{"choices":[{"message":{"content":"  [[TOUCHBARCHAT_WAIT]]\n"}}]}"#.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let outcome = try await makeClient().answerForLiveTurn(
            endpoint: URL(string: "https://example.test/v1/chat/completions")!,
            model: "test-model",
            apiKey: "sk-test-only",
            userProfile: "我有五年产品经验",
            question: "我想问的是，关于你之前的"
        )
        #expect(outcome == .needsMoreSpeech)
        #expect(requestCount == 1)
    }

    @Test
    func liveTurnReturnsNormalAnswer() async throws {
        StubURLProtocol.handler = { request in
            let body = try #require(Self.requestBody(request))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let messages = try #require(json["messages"] as? [[String: String]])
            #expect(messages[0]["content"]?.contains("上一题关于项目进度") == true)
            return (200, Data(#"{"choices":[{"message":{"content":"我会先明确用户需求，再用数据验证方案。"}}]}"#.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let outcome = try await makeClient().answerForLiveTurn(
            endpoint: URL(string: "https://example.test/v1/chat/completions")!,
            model: "test-model",
            apiKey: "sk-test-only",
            userProfile: "",
            question: "你会如何确定产品优先级？",
            recentContext: "上一题关于项目进度"
        )
        #expect(outcome == .answer("我会先明确用户需求，再用数据验证方案。"))
    }

    @Test
    func liveTurnDoesNotDeferForSentinelMixedWithAnswer() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data(#"{"choices":[{"message":{"content":"[[TOUCHBARCHAT_WAIT]] 我会先确认目标。"}}]}"#.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let outcome = try await makeClient().answerForLiveTurn(
            endpoint: URL(string: "https://example.test/v1/chat/completions")!,
            model: "test-model",
            apiKey: "sk-test-only",
            userProfile: "",
            question: "你会怎么推进？"
        )
        #expect(outcome == .answer("[[TOUCHBARCHAT_WAIT]] 我会先确认目标。"))
    }

    @Test
    func acceptsTextPartResponses() async throws {
        StubURLProtocol.handler = { _ in
            (
                200,
                #"{"choices":[{"message":{"content":[{"type":"text","text":"第一句。"},{"type":"text","text":"第二句。"}]}}]}"#
                    .data(using: .utf8)!
            )
        }
        defer { StubURLProtocol.handler = nil }

        let answer = try await makeClient().answer(
            endpoint: URL(string: "https://example.test/v1/chat/completions")!,
            model: "test-model",
            apiKey: "sk-test-only",
            userProfile: "",
            question: "问题"
        )
        #expect(answer == "第一句。第二句。")
    }

    @Test
    func redactsAPIKeyFromProviderError() async throws {
        StubURLProtocol.handler = { _ in
            (401, #"{"error":{"message":"Invalid key: sk-test-only"}}"#.data(using: .utf8)!)
        }
        defer { StubURLProtocol.handler = nil }

        do {
            _ = try await makeClient().answer(
                endpoint: URL(string: "https://example.test/v1/chat/completions")!,
                model: "test-model",
                apiKey: "sk-test-only",
                userProfile: "",
                question: "问题"
            )
            Issue.record("Expected a 401 error")
        } catch let error as AIAnswerClientError {
            #expect(error.errorDescription?.contains("401") == true)
            #expect(error.errorDescription?.contains("sk-test-only") == false)
        }
    }

    @Test
    func rejectsMalformedSuccessfulResponse() async throws {
        StubURLProtocol.handler = { _ in (200, Data(#"{"choices":[]}"#.utf8)) }
        defer { StubURLProtocol.handler = nil }

        do {
            _ = try await makeClient().answer(
                endpoint: URL(string: "https://example.test/v1/chat/completions")!,
                model: "test-model",
                apiKey: "sk-test-only",
                userProfile: "",
                question: "问题"
            )
            Issue.record("Expected an invalid response error")
        } catch let error as AIAnswerClientError {
            guard case .invalidResponse = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }

    @Test
    func preventsSendingKeyToPlainHTTPRemoteHost() async throws {
        StubURLProtocol.handler = { _ in
            Issue.record("Request must not be sent")
            return (200, Data())
        }
        defer { StubURLProtocol.handler = nil }

        do {
            _ = try await makeClient().answer(
                endpoint: URL(string: "http://example.test/v1/chat/completions")!,
                model: "test-model",
                apiKey: "sk-test-only",
                userProfile: "",
                question: "问题"
            )
            Issue.record("Expected insecure endpoint error")
        } catch let error as AIAnswerClientError {
            guard case .insecureEndpoint = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
        }
    }

    @Test
    func permitsKeylessLoopbackAndOmitsAuthorization() async throws {
        StubURLProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            return (200, Data(#"{"choices":[{"message":{"content":"本地回答"}}]}"#.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        let answer = try await makeClient().answer(
            endpoint: URL(string: "http://127.0.0.1:12345/v1/chat/completions")!,
            model: "local-model",
            apiKey: "",
            userProfile: "",
            question: "问题"
        )
        #expect(answer == "本地回答")
    }

    @Test @MainActor
    func streamedAnswerPublishesCumulativeText() async throws {
        StubURLProtocol.handler = { request in
            let body = try #require(Self.requestBody(request))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["stream"] as? Bool == true)
            let sse = """
                data: {"choices":[{"delta":{"role":"assistant","content":"我会"}}]}

                data: {"choices":[{"delta":{"content":"先确认"}}]}

                data: {"choices":[{"delta":{"content":[{"type":"text","text":"目标。"}]}}]}

                data: [DONE]

                """
            return (200, Data(sse.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        var published: [String] = []
        let answer = try await makeClient().streamAnswer(
            endpoint: URL(string: "https://example.test/v1/chat/completions")!,
            model: "test-model",
            apiKey: "sk-test-only",
            userProfile: "",
            question: "你会怎么做？",
            onPartialAnswer: { published.append($0) }
        )
        #expect(answer == "我会先确认目标。")
        #expect(published == ["我会", "我会先确认", "我会先确认目标。"])
    }

    @Test @MainActor
    func streamedLiveTurnNeverPublishesWaitSentinel() async throws {
        StubURLProtocol.handler = { _ in
            let sse = """
                data: {"choices":[{"delta":{"content":"  [[TOUCH"}}]}

                data: {"choices":[{"delta":{"content":"BARCHAT_WAIT]]  "}}]}

                data: [DONE]

                """
            return (200, Data(sse.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        var published: [String] = []
        let outcome = try await makeClient().streamAnswerForLiveTurn(
            endpoint: URL(string: "https://example.test/v1/chat/completions")!,
            model: "test-model",
            apiKey: "sk-test-only",
            userProfile: "",
            question: "我想问的是，关于你之前的",
            onPartialAnswer: { published.append($0) }
        )
        #expect(outcome == .needsMoreSpeech)
        #expect(published.isEmpty)
    }

    @Test @MainActor
    func streamedLiveTurnReleasesNonSentinelAnswer() async throws {
        StubURLProtocol.handler = { _ in
            let sse = """
                data: {"choices":[{"delta":{"content":"[[TOUCH"}}]}

                data: {"choices":[{"delta":{"content":"BARCHAT_WAIT]] 我会先确认目标。"}}]}

                data: [DONE]

                """
            return (200, Data(sse.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        var published: [String] = []
        let outcome = try await makeClient().streamAnswerForLiveTurn(
            endpoint: URL(string: "https://example.test/v1/chat/completions")!,
            model: "test-model",
            apiKey: "sk-test-only",
            userProfile: "",
            question: "你会怎么推进？",
            onPartialAnswer: { published.append($0) }
        )
        #expect(outcome == .answer("[[TOUCHBARCHAT_WAIT]] 我会先确认目标。"))
        #expect(published == ["[[TOUCHBARCHAT_WAIT]] 我会先确认目标。"])
    }

    @Test @MainActor
    func streamingFallsBackToNormalJSONCompletion() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data(#"{"choices":[{"message":{"content":"兼容接口的完整回答。"}}]}"#.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        var published: [String] = []
        let answer = try await makeClient().streamAnswer(
            endpoint: URL(string: "https://example.test/v1/chat/completions")!,
            model: "test-model",
            apiKey: "sk-test-only",
            userProfile: "",
            question: "问题",
            onPartialAnswer: { published.append($0) }
        )
        #expect(answer == "兼容接口的完整回答。")
        #expect(published == ["兼容接口的完整回答。"])
    }

    @Test @MainActor
    func streamedHTTPFailureRedactsKey() async throws {
        StubURLProtocol.handler = { _ in
            (401, Data(#"{"error":{"message":"Invalid key sk-test-only"}}"#.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        do {
            _ = try await makeClient().streamAnswer(
                endpoint: URL(string: "https://example.test/v1/chat/completions")!,
                model: "test-model",
                apiKey: "sk-test-only",
                userProfile: "",
                question: "问题",
                onPartialAnswer: { _ in Issue.record("HTTP failure must not publish text") }
            )
            Issue.record("Expected a 401 error")
        } catch let error as AIAnswerClientError {
            #expect(error.errorDescription?.contains("401") == true)
            #expect(error.errorDescription?.contains("sk-test-only") == false)
        }
    }

    @Test @MainActor
    func streamedProviderErrorRedactsKey() async throws {
        StubURLProtocol.handler = { _ in
            (200, Data("data: {\"error\":{\"message\":\"Invalid sk-test-only\"}}\n\n".utf8))
        }
        defer { StubURLProtocol.handler = nil }

        do {
            _ = try await makeClient().streamAnswer(
                endpoint: URL(string: "https://example.test/v1/chat/completions")!,
                model: "test-model",
                apiKey: "sk-test-only",
                userProfile: "",
                question: "问题",
                onPartialAnswer: { _ in Issue.record("Provider error must not publish text") }
            )
            Issue.record("Expected streamed provider error")
        } catch let error as AIAnswerClientError {
            #expect(error.errorDescription?.contains("Invalid") == true)
            #expect(error.errorDescription?.contains("sk-test-only") == false)
        }
    }

    @Test @MainActor
    func acceptsCRLFAndFinalEventWithoutDone() async throws {
        StubURLProtocol.handler = { _ in
            let sse =
                ": keepalive\r\n\r\ndata: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\r\n\r\ndata: {\"choices\":[{\"delta\":{\"content\":\"回答。\"}}]}"
            return (200, Data(sse.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        var published: [String] = []
        let answer = try await makeClient().streamAnswer(
            endpoint: URL(string: "https://example.test/v1/chat/completions")!,
            model: "test-model",
            apiKey: "sk-test-only",
            userProfile: "",
            question: "问题",
            onPartialAnswer: { published.append($0) }
        )
        #expect(answer == "回答。")
        #expect(published == ["回答。"])
    }

    @Test
    func cancelledStreamNeverSendsRequest() async throws {
        StubURLProtocol.handler = { _ in
            Issue.record("Cancelled request must not be sent")
            return (200, Data())
        }
        defer { StubURLProtocol.handler = nil }

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await makeClient().streamAnswer(
                endpoint: URL(string: "https://example.test/v1/chat/completions")!,
                model: "test-model",
                apiKey: "sk-test-only",
                userProfile: "",
                question: "问题",
                onPartialAnswer: { _ in Issue.record("Cancelled stream must not publish text") }
            )
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
    }

    @Test @MainActor
    func transportCancellationWithoutTaskCancellationIsARecoverableFailure() async throws {
        StubURLProtocol.handler = { _ in throw URLError(.cancelled) }
        defer { StubURLProtocol.handler = nil }

        do {
            _ = try await makeClient().streamAnswer(
                endpoint: URL(string: "https://example.test/v1/chat/completions")!,
                model: "test-model",
                apiKey: "sk-test-only",
                userProfile: "",
                question: "问题",
                onPartialAnswer: { _ in Issue.record("Cancelled transport must not publish text") }
            )
            Issue.record("Expected transport failure")
        } catch let error as AIAnswerClientError {
            guard case .networkFailure = error else {
                Issue.record("Expected a recoverable network failure")
                return
            }
        } catch {
            Issue.record("Unexpected silent cancellation: \(error)")
        }
    }

    @Test @MainActor
    func cancellingAfterFirstDeltaStopsLaterDisplayUpdates() async throws {
        StubURLProtocol.handler = { _ in
            let sse = """
                data: {"choices":[{"delta":{"content":"第一句"}}]}

                data: {"choices":[{"delta":{"content":"第二句"}}]}

                data: [DONE]

                """
            return (200, Data(sse.utf8))
        }
        defer { StubURLProtocol.handler = nil }

        var published: [String] = []
        let task = Task { @MainActor in
            try await makeClient().streamAnswer(
                endpoint: URL(string: "https://example.test/v1/chat/completions")!,
                model: "test-model",
                apiKey: "sk-test-only",
                userProfile: "",
                question: "问题",
                onPartialAnswer: { text in
                    published.append(text)
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            )
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation after first delta")
        } catch is CancellationError {
            #expect(published == ["第一句"])
        }
    }

    private func makeClient() -> AIAnswerClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return AIAnswerClient(session: URLSession(configuration: configuration))
    }

    private static func requestBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var bytes = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count < 0 { return nil }
            if count == 0 { return body }
            body.append(contentsOf: bytes[..<count])
        }
    }
}

private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw StubError.noHandler }
            let (status, data) = try handler(request)
            guard let url = request.url,
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
            else {
                throw StubError.invalidURL
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private enum StubError: Error {
        case noHandler
        case invalidURL
    }
}
