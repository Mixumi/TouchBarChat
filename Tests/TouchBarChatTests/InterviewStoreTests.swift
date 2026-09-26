import Foundation
import Testing

@testable import TouchBarChat

@MainActor
struct InterviewStoreTests {
    @Test
    func persistsInterviewAndReviewEditsWithoutLosingOriginals() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = InterviewStore(directoryURL: directory)
        let sessionID = store.startSession()
        store.updateTranscript("面试官：请介绍自己。")
        let exchangeID = try #require(
            store.appendExchange(
                question: "请介绍自己。",
                answer: nil,
                status: "generating"
            ))
        store.updateExchangeAnswer(id: exchangeID, answer: "我有相关经验。", status: "answered")

        // Review edits are deliberately unavailable while recording.
        store.updateQuestion(id: exchangeID, text: "请做一个自我介绍。")
        #expect(store.sessions[0].exchanges[0].editedQuestion == nil)

        store.finishSession()
        store.updateSessionTitle(id: sessionID, title: "产品经理面试")
        store.updateSessionTranscript(id: sessionID, text: "面试官：请做一个自我介绍。")
        store.updateQuestion(id: exchangeID, text: "请做一个自我介绍。")
        store.updateAnswer(id: exchangeID, text: "我有五年相关经验。")

        let reopened = InterviewStore(directoryURL: directory)
        let session = try #require(reopened.sessions.first)
        let exchange = try #require(session.exchanges.first)
        #expect(session.title == "产品经理面试")
        #expect(session.transcript == "面试官：请介绍自己。")
        #expect(session.displayTranscript == "面试官：请做一个自我介绍。")
        #expect(exchange.originalQuestion == "请介绍自己。")
        #expect(exchange.displayQuestion == "请做一个自我介绍。")
        #expect(exchange.originalAnswer == "我有相关经验。")
        #expect(exchange.displayAnswer == "我有五年相关经验。")
        #expect(reopened.exportMarkdown(id: sessionID)?.contains("我有五年相关经验。") == true)
        #expect(session.generatedMarkdown.contains("**面试官：** 请做一个自我介绍。"))
        #expect(session.generatedMarkdown.contains("**AI：** 我有五年相关经验。"))
        #expect(session.generatedMarkdown.contains("## 原始转写"))

        reopened.restoreQuestion(id: exchangeID)
        reopened.restoreAnswer(id: exchangeID)
        reopened.restoreSessionTranscript(id: sessionID)
        #expect(reopened.sessions[0].exchanges[0].displayQuestion == "请介绍自己。")
        #expect(reopened.sessions[0].exchanges[0].displayAnswer == "我有相关经验。")
        #expect(reopened.sessions[0].displayTranscript == "面试官：请介绍自己。")
    }

    @Test
    func deletionIsAvailableOnlyAfterInterviewEnds() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = InterviewStore(directoryURL: directory)
        let sessionID = store.startSession()
        let exchangeID = try #require(
            store.appendExchange(
                question: "问题",
                answer: "回答",
                status: "answered"
            ))
        store.deleteExchange(id: exchangeID)
        store.deleteSession(id: sessionID)
        #expect(store.sessions.count == 1)
        #expect(store.sessions[0].exchanges.count == 1)

        store.finishSession()
        store.deleteExchange(id: exchangeID)
        #expect(store.sessions[0].exchanges.isEmpty)
        store.deleteSession(id: sessionID)
        #expect(store.sessions.isEmpty)
        #expect(InterviewStore(directoryURL: directory).sessions.isEmpty)
    }

    @Test
    func previousInterviewRemainsReadOnlyDuringANewInterview() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = InterviewStore(directoryURL: directory)
        let previousID = store.startSession()
        let exchangeID = try #require(
            store.appendExchange(
                question: "旧问题",
                answer: "旧回答",
                status: "已生成"
            ))
        store.finishSession()
        _ = store.startSession()

        store.updateSessionTitle(id: previousID, title: "不能改名")
        store.updateSessionMarkdown(id: previousID, text: "不能修改 Markdown")
        store.updateQuestion(id: exchangeID, text: "不能修改")
        store.deleteSession(id: previousID)

        let previous = try #require(store.sessions.first(where: { $0.id == previousID }))
        #expect(previous.title != "不能改名")
        #expect(previous.editedMarkdown == nil)
        #expect(previous.exchanges.first?.displayQuestion == "旧问题")
        #expect(store.sessions.count == 2)
    }

    @Test
    func existingJSONWithoutMarkdownOverrideRemainsReadableAndUntouched() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("interviews.json")
        let legacyJSON = """
            [{
              "id": "00000000-0000-0000-0000-000000000001",
              "title": "旧面试",
              "startedAt": 0,
              "endedAt": 1,
              "transcript": "旧转写",
              "editedTranscript": null,
              "exchanges": [{
                "id": "00000000-0000-0000-0000-000000000002",
                "createdAt": 0,
                "originalQuestion": "旧问题",
                "editedQuestion": null,
                "originalAnswer": "旧回答",
                "editedAnswer": null,
                "status": "已生成"
              }]
            }]
            """
        let originalData = Data(legacyJSON.utf8)
        try originalData.write(to: fileURL)

        let store = InterviewStore(directoryURL: directory)
        let session = try #require(store.sessions.first)
        #expect(store.persistenceError == nil)
        #expect(session.editedMarkdown == nil)
        #expect(session.language == .chinese)
        #expect(session.answerLanguage == .chinese)
        #expect(session.displayMarkdown.contains("**面试官：** 旧问题"))
        #expect(session.displayMarkdown.contains("**AI：** 旧回答"))
        #expect(session.displayMarkdown.contains("## 原始转写\n\n旧转写"))
        #expect(try Data(contentsOf: fileURL) == originalData)
    }

    @Test
    func interviewLanguagePersistsAndLabelsTheExportedDocument() throws {
        for language in InterviewLanguage.allCases {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = InterviewStore(directoryURL: directory)
            let answerLanguage: InterviewLanguage = language == .japanese ? .english : language
            let sessionID = store.startSession(language: language, answerLanguage: answerLanguage)
            store.updateTranscript("spoken words")
            _ = store.appendExchange(question: "question", answer: "answer", status: "answered")
            store.finishSession()

            let reopened = InterviewStore(directoryURL: directory)
            let session = try #require(reopened.sessions.first)
            let labels = InterviewMarkdownLabels(language: language)
            #expect(session.language == language)
            #expect(session.languageCode == language.rawValue)
            #expect(session.answerLanguage == answerLanguage)
            #expect(session.answerLanguageCode == answerLanguage.rawValue)
            #expect(session.generatedMarkdown.contains("**\(labels.interviewer)** question"))
            #expect(session.generatedMarkdown.contains(session.originalTranscriptHeading))
            #expect(reopened.exportMarkdown(id: sessionID)?.contains(labels.started) == true)
        }
    }

    @Test
    func markdownReviewEditPersistsAndExportsTheExactDisplayedBody() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = InterviewStore(directoryURL: directory)
        let sessionID = store.startSession()
        store.updateTranscript("原始转写")
        _ = store.appendExchange(question: "为什么？", answer: "因为这样。", status: "已生成")
        store.updateSessionMarkdown(id: sessionID, text: "进行中不能编辑")
        #expect(store.sessions[0].editedMarkdown == nil)

        store.finishSession()
        let original = store.sessions[0].generatedMarkdown
        let edited = "## 复盘\n\n**面试官：** 修改后的问题\n\n**AI：** 修改后的回答\n"
        store.updateSessionMarkdown(id: sessionID, text: edited)

        let reopened = InterviewStore(directoryURL: directory)
        let session = try #require(reopened.sessions.first)
        #expect(session.editedMarkdown == edited)
        #expect(session.displayMarkdown == edited)
        #expect(session.generatedMarkdown == original)
        #expect(session.transcript == "原始转写")
        #expect(session.exchanges.first?.originalQuestion == "为什么？")
        #expect(reopened.exportMarkdown(id: sessionID)?.hasSuffix("\n\n" + edited) == true)

        reopened.updateSessionMarkdown(id: sessionID, text: original)
        #expect(reopened.sessions[0].editedMarkdown == nil)
        reopened.updateSessionMarkdown(id: sessionID, text: edited)
        reopened.restoreSessionMarkdown(id: sessionID)
        #expect(reopened.sessions[0].displayMarkdown == original)
    }

    @Test
    func generatedMarkdownHandlesUnansweredTranscriptOnlyAndEmptySessions() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InterviewStore(directoryURL: directory)

        _ = store.startSession()
        _ = store.appendExchange(question: "问题", answer: nil, status: "未配置 AI 接口")
        store.finishSession()
        #expect(store.sessions[0].generatedMarkdown == "**面试官：** 问题\n\n**AI：** （未生成回答）\n\n> 回答状态：未配置 AI 接口")

        _ = store.startSession()
        store.updateTranscript("仅识别到的讲话")
        store.finishSession()
        #expect(store.sessions[0].generatedMarkdown == "## 原始转写\n\n仅识别到的讲话")

        _ = store.startSession()
        store.finishSession()
        #expect(store.sessions[0].generatedMarkdown == "暂无内容。")
    }

    @Test
    func generatedMarkdownMarksIncompleteAnswersWithoutChangingCompletedAnswers() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InterviewStore(directoryURL: directory)

        _ = store.startSession()
        _ = store.appendExchange(question: "第一题", answer: "完整回答", status: "已生成")
        _ = store.appendExchange(question: "第二题", answer: "部分回答", status: "生成中（部分回答）")
        _ = store.appendExchange(question: "第三题", answer: "中断前内容", status: "回答中断")
        _ = store.appendExchange(question: "第四题", answer: nil, status: "生成失败：网络中断")

        #expect(
            store.sessions[0].generatedMarkdown == """
                **面试官：** 第一题

                **AI：** 完整回答

                **面试官：** 第二题

                **AI：** 部分回答

                > 回答状态：生成中（部分回答）

                **面试官：** 第三题

                **AI：** 中断前内容

                > 回答状态：回答中断

                **面试官：** 第四题

                **AI：** （未生成回答）

                > 回答状态：生成失败：网络中断
                """)
    }

    @Test
    func unreadableHistoryIsNotOverwritten() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("interviews.json")
        let corruptedData = Data("{ not valid JSON".utf8)
        try corruptedData.write(to: fileURL)

        let store = InterviewStore(directoryURL: directory)
        #expect(store.persistenceError != nil)
        _ = store.startSession()
        #expect(try Data(contentsOf: fileURL) == corruptedData)
    }

    @Test
    func interruptedSessionCanBeReviewedOnNextLaunch() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstProcess = InterviewStore(directoryURL: directory)
        let sessionID = firstProcess.startSession()
        firstProcess.updateTranscript("还没来得及点击结束的内容")

        let nextProcess = InterviewStore(directoryURL: directory)
        let recovered = try #require(nextProcess.sessions.first)
        #expect(nextProcess.activeSessionID == nil)
        #expect(recovered.endedAt != nil)
        #expect(recovered.transcript == "还没来得及点击结束的内容")
        nextProcess.updateSessionTitle(id: sessionID, title: "恢复后的面试")
        #expect(nextProcess.sessions.first?.title == "恢复后的面试")
    }

    @Test
    func liveAnswerSnapshotsReplaceOriginalAndCoalesceUntilFinal() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = InterviewStore(directoryURL: directory, transcriptSaveInterval: 0.4)
        _ = store.startSession()
        let exchangeID = try #require(
            store.appendExchange(
                question: "请介绍自己。",
                answer: "我有",
                status: "回答生成中"
            ))
        #expect(try savedSessions(in: directory)[0].exchanges[0].originalAnswer == "我有")

        store.updateLiveExchange(id: exchangeID, answer: "我有相关经验", status: "回答生成中", final: false)
        #expect(store.sessions[0].exchanges[0].originalAnswer == "我有相关经验")
        #expect(store.sessions[0].exchanges[0].editedAnswer == nil)
        #expect(try savedSessions(in: directory)[0].exchanges[0].originalAnswer == "我有")

        #expect(
            try await waitForSavedSessions(in: directory) {
                $0[0].exchanges[0].originalAnswer == "我有相关经验"
            })

        store.updateLiveExchange(id: exchangeID, answer: "我有五年相关经验。", status: "已生成", final: true)
        let persisted = try #require(savedSessions(in: directory)[0].exchanges.first)
        #expect(persisted.originalAnswer == "我有五年相关经验。")
        #expect(persisted.editedAnswer == nil)
        #expect(persisted.status == "已生成")
    }

    @Test
    func liveAnswerUpdatesCannotOverwriteReviewedOrInactiveExchanges() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = InterviewStore(directoryURL: directory)
        let previousID = store.startSession()
        let previousExchangeID = try #require(
            store.appendExchange(
                question: "旧问题", answer: "旧回答", status: "已生成"
            ))
        store.finishSession()
        store.updateAnswer(id: previousExchangeID, text: "用户复盘修改")

        _ = store.startSession()
        let activeExchangeID = try #require(
            store.appendExchange(
                question: "新问题", answer: "部分回答", status: "回答生成中"
            ))
        store.updateLiveExchange(
            id: previousExchangeID, answer: "迟到的旧回答", status: "已生成", final: true
        )
        let previous = try #require(store.sessions.first(where: { $0.id == previousID })?.exchanges.first)
        #expect(previous.originalAnswer == "旧回答")
        #expect(previous.editedAnswer == "用户复盘修改")
        #expect(previous.displayAnswer == "用户复盘修改")

        // A failed request may have no new text; the last received partial remains.
        store.updateLiveExchange(id: activeExchangeID, answer: nil, status: "回答中断", final: true)
        #expect(store.sessions[0].exchanges[0].originalAnswer == "部分回答")
        #expect(store.sessions[0].exchanges[0].status == "回答中断")
        store.finishSession()
        store.updateLiveExchange(id: activeExchangeID, answer: "结束后的迟到文字", status: "已生成", final: true)
        #expect(store.sessions[0].exchanges[0].originalAnswer == "部分回答")
    }

    @Test
    func firstLiveAnswerPartialSurvivesAnInterruptedSession() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstProcess = InterviewStore(directoryURL: directory, transcriptSaveInterval: 60)
        _ = firstProcess.startSession()
        let exchangeID = try #require(
            firstProcess.appendExchange(
                question: "问题", answer: "第一段", status: "回答生成中"
            ))
        firstProcess.updateLiveExchange(
            id: exchangeID, answer: "第一段，尚未合并写盘的第二段", status: "回答生成中", final: false
        )

        // Simulates the process exiting before the scheduled coalesced write.
        let restarted = InterviewStore(directoryURL: directory)
        let recovered = try #require(restarted.sessions.first?.exchanges.first)
        #expect(restarted.activeSessionID == nil)
        #expect(recovered.originalAnswer == "第一段")
        #expect(recovered.editedAnswer == nil)
        // Cancel the simulated process's pending timer before removing temp data.
        firstProcess.flush()
    }

    @Test
    func partialTranscriptsAreCoalescedButFlushSavesImmediately() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = InterviewStore(directoryURL: directory, transcriptSaveInterval: 0.4)
        _ = store.startSession()
        store.updateTranscript("第一段")
        store.updateTranscript("第一段，第二段")

        #expect(store.sessions[0].transcript == "第一段，第二段")
        #expect(try savedSessions(in: directory)[0].transcript == "第一段")

        #expect(
            try await waitForSavedSessions(in: directory) {
                $0[0].transcript == "第一段，第二段"
            })

        store.updateTranscript("第一段，第二段，第三段")
        store.flush()
        #expect(try savedSessions(in: directory)[0].transcript == "第一段，第二段，第三段")
    }

    private func savedSessions(in directory: URL) throws -> [InterviewSession] {
        let data = try Data(contentsOf: directory.appendingPathComponent("interviews.json"))
        return try JSONDecoder().decode([InterviewSession].self, from: data)
    }

    private func waitForSavedSessions(
        in directory: URL,
        matching predicate: ([InterviewSession]) -> Bool
    ) async throws -> Bool {
        for _ in 0..<60 {
            if predicate(try savedSessions(in: directory)) { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TouchBarChatTests-\(UUID().uuidString)", isDirectory: true)
    }
}
