import Combine
import Foundation

struct InterviewExchange: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var createdAt: Date
    var originalQuestion: String
    var editedQuestion: String?
    var originalAnswer: String?
    var editedAnswer: String?
    var status: String

    var displayQuestion: String { editedQuestion ?? originalQuestion }
    var displayAnswer: String? { editedAnswer ?? originalAnswer }
}

struct InterviewSession: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var title: String
    var startedAt: Date
    var endedAt: Date?
    /// The complete, unedited transcript received during the interview.
    var transcript: String
    var editedTranscript: String?
    var exchanges: [InterviewExchange]
    /// A review-time document override. The captured transcript and exchanges
    /// remain intact so older records and the original interview can be recovered.
    var editedMarkdown: String?
    /// Optional for backward compatibility with records saved before language
    /// selection existed; those sessions remain Chinese.
    var languageCode: String? = nil
    /// Stored separately because an interview can be transcribed in one
    /// language while AI replies in another. Legacy records use the speech
    /// language for both.
    var answerLanguageCode: String? = nil

    var displayTranscript: String { editedTranscript ?? transcript }
    var language: InterviewLanguage {
        languageCode.flatMap(InterviewLanguage.init(rawValue:)) ?? .chinese
    }
    var answerLanguage: InterviewLanguage {
        answerLanguageCode.flatMap(InterviewLanguage.init(rawValue:)) ?? language
    }
    var originalTranscriptHeading: String {
        "## \(InterviewMarkdownLabels(language: language).originalTranscript)"
    }

    var generatedMarkdown: String {
        let labels = InterviewMarkdownLabels(language: language)
        var sections = exchanges.map { exchange in
            let exchangeText =
                "**\(labels.interviewer)** \(exchange.displayQuestion)\n\n**\(labels.ai)** \(exchange.displayAnswer ?? labels.noAnswer)"
            guard exchange.status != "已生成", exchange.status != "answered" else {
                return exchangeText
            }
            let status = exchange.status.components(separatedBy: .newlines)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            let description =
                status.isEmpty
                ? labels.incomplete : labels.statusDescription(status, language: language)
            return "\(exchangeText)\n\n> \(labels.answerStatus)\(description)"
        }
        if !displayTranscript.isEmpty {
            let transcriptSection = "\(originalTranscriptHeading)\n\n\(displayTranscript)"
            sections.append(sections.isEmpty ? transcriptSection : "---\n\n\(transcriptSection)")
        }
        return sections.isEmpty ? labels.empty : sections.joined(separator: "\n\n")
    }

    var displayMarkdown: String { editedMarkdown ?? generatedMarkdown }
}

/// Stores text-only interview history in Application Support/TouchBarChat.
/// The UI can observe it directly; all mutations and saves run on the main actor.
@MainActor
final class InterviewStore: ObservableObject {
    @Published private(set) var sessions: [InterviewSession] = []
    @Published private(set) var activeSessionID: UUID? = nil
    @Published private(set) var persistenceError: String? = nil

    var canRetryPersistence: Bool { mayOverwriteStoreFile }

    private let fileURL: URL
    private let transcriptSaveInterval: TimeInterval
    private var mayOverwriteStoreFile = true
    private var lastPersistAttemptUptime: TimeInterval?
    private var pendingTranscriptSave: Task<Void, Never>?
    private var transcriptSaveGeneration: UInt64 = 0

    init(directoryURL: URL? = nil, transcriptSaveInterval: TimeInterval = 1.0) {
        let supportDirectory =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let directory =
            directoryURL
            ?? supportDirectory.appendingPathComponent(
                "TouchBarChat",
                isDirectory: true
            )
        fileURL = directory.appendingPathComponent("interviews.json")
        self.transcriptSaveInterval = max(0.05, transcriptSaveInterval)

        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            var loadedSessions = try JSONDecoder().decode([InterviewSession].self, from: data)
            // A previous process may have exited before finishSession(). Its
            // last saved transcript must remain reviewable on the next launch.
            let lastSaveDate =
                (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            var recoveredAnInterruptedSession = false
            for index in loadedSessions.indices where loadedSessions[index].endedAt == nil {
                loadedSessions[index].endedAt = max(loadedSessions[index].startedAt, lastSaveDate)
                recoveredAnInterruptedSession = true
            }
            sessions = loadedSessions
            if recoveredAnInterruptedSession { flush() }
        } catch {
            // Keep an unreadable file intact instead of replacing it with empty history.
            mayOverwriteStoreFile = false
            persistenceError = L10n.text("无法读取面试记录，原文件已保留：%@", error.localizedDescription)
        }
    }

    @discardableResult
    func startSession(
        language: InterviewLanguage = .chinese,
        answerLanguage: InterviewLanguage? = nil
    ) -> UUID {
        if let activeSessionID { return activeSessionID }

        let startedAt = Date()
        let labels = InterviewMarkdownLabels(language: language)
        let session = InterviewSession(
            id: UUID(),
            title: "\(labels.interviewTitle) · \(Self.titleDateFormatter.string(from: startedAt))",
            startedAt: startedAt,
            endedAt: nil,
            transcript: "",
            editedTranscript: nil,
            exchanges: [],
            editedMarkdown: nil,
            languageCode: language.rawValue,
            answerLanguageCode: (answerLanguage ?? language).rawValue
        )
        sessions.insert(session, at: 0)
        activeSessionID = session.id
        flush()
        return session.id
    }

    func updateTranscript(_ text: String) {
        guard let activeSessionID,
            let index = sessions.firstIndex(where: { $0.id == activeSessionID }),
            sessions[index].transcript != text
        else { return }
        let isFirstRecognizedText = sessions[index].transcript.isEmpty && !text.isEmpty
        sessions[index].transcript = text
        // The first recognizable words are saved immediately: a crash in the
        // first second should not leave a completely empty interview record.
        if isFirstRecognizedText {
            flush()
        } else {
            scheduleTranscriptPersistence()
        }
    }

    @discardableResult
    func appendExchange(question: String, answer: String?, status: String) -> UUID? {
        guard let activeSessionID,
            let index = sessions.firstIndex(where: { $0.id == activeSessionID })
        else {
            return nil
        }
        let exchange = InterviewExchange(
            id: UUID(),
            createdAt: Date(),
            originalQuestion: question,
            editedQuestion: nil,
            originalAnswer: answer,
            editedAnswer: nil,
            status: status
        )
        sessions[index].exchanges.append(exchange)
        flush()
        return exchange.id
    }

    func updateExchangeAnswer(id: UUID, answer: String?, status: String) {
        guard let (sessionIndex, exchangeIndex) = exchangeLocation(id: id) else { return }
        var exchange = sessions[sessionIndex].exchanges[exchangeIndex]

        if let answer {
            if exchange.originalAnswer == nil {
                exchange.originalAnswer = answer
            } else if exchange.originalAnswer != answer {
                // A later answer update does not erase the first generated answer.
                exchange.editedAnswer = answer
            }
        }
        exchange.status = status
        sessions[sessionIndex].exchanges[exchangeIndex] = exchange
        flush()
    }

    /// Replaces the captured answer for a question in the current interview.
    /// Call `appendExchange` for the first nonempty partial so it is saved
    /// immediately; later cumulative snapshots share the transcript's
    /// coalesced save. A nil answer preserves the last captured partial.
    func updateLiveExchange(id: UUID, answer: String?, status: String, final: Bool) {
        guard let activeSessionID,
            let sessionIndex = sessions.firstIndex(where: {
                $0.id == activeSessionID && $0.endedAt == nil
            }),
            let exchangeIndex = sessions[sessionIndex].exchanges.firstIndex(where: { $0.id == id })
        else {
            return
        }

        let previous = sessions[sessionIndex].exchanges[exchangeIndex]
        let capturedAnswer = answer ?? previous.originalAnswer
        if previous.originalAnswer != capturedAnswer || previous.status != status {
            sessions[sessionIndex].exchanges[exchangeIndex].originalAnswer = capturedAnswer
            sessions[sessionIndex].exchanges[exchangeIndex].status = status
        } else if !final {
            return
        }

        if final {
            // Also commits any earlier coalesced answer or transcript update.
            flush()
        } else {
            scheduleTranscriptPersistence()
        }
    }

    func finishSession() {
        guard let activeSessionID else { return }
        if let index = sessions.firstIndex(where: { $0.id == activeSessionID }) {
            sessions[index].endedAt = Date()
        }
        self.activeSessionID = nil
        flush()
    }

    func updateSessionTitle(id: UUID, title: String) {
        guard let index = editableSessionIndex(id: id),
            sessions[index].title != title
        else { return }
        sessions[index].title = title
        flush()
    }

    func updateSessionTranscript(id: UUID, text: String) {
        guard let index = editableSessionIndex(id: id) else { return }
        let editedText = text == sessions[index].transcript ? nil : text
        guard sessions[index].editedTranscript != editedText else { return }
        sessions[index].editedTranscript = editedText
        flush()
    }

    func restoreSessionTranscript(id: UUID) {
        guard let index = editableSessionIndex(id: id),
            sessions[index].editedTranscript != nil
        else { return }
        sessions[index].editedTranscript = nil
        flush()
    }

    func updateSessionMarkdown(id: UUID, text: String) {
        guard let index = editableSessionIndex(id: id) else { return }
        let editedText = text == sessions[index].generatedMarkdown ? nil : text
        guard sessions[index].editedMarkdown != editedText else { return }
        sessions[index].editedMarkdown = editedText
        flush()
    }

    func restoreSessionMarkdown(id: UUID) {
        guard let index = editableSessionIndex(id: id),
            sessions[index].editedMarkdown != nil
        else { return }
        sessions[index].editedMarkdown = nil
        flush()
    }

    func updateQuestion(id: UUID, text: String) {
        guard let (sessionIndex, exchangeIndex) = editableExchangeLocation(id: id) else { return }
        let exchange = sessions[sessionIndex].exchanges[exchangeIndex]
        let editedText = text == exchange.originalQuestion ? nil : text
        guard exchange.editedQuestion != editedText else { return }
        sessions[sessionIndex].exchanges[exchangeIndex].editedQuestion = editedText
        flush()
    }

    func updateAnswer(id: UUID, text: String) {
        guard let (sessionIndex, exchangeIndex) = editableExchangeLocation(id: id) else { return }
        let exchange = sessions[sessionIndex].exchanges[exchangeIndex]
        let editedText = text == exchange.originalAnswer ? nil : text
        guard exchange.editedAnswer != editedText else { return }
        sessions[sessionIndex].exchanges[exchangeIndex].editedAnswer = editedText
        flush()
    }

    func restoreQuestion(id: UUID) {
        guard let (sessionIndex, exchangeIndex) = editableExchangeLocation(id: id),
            sessions[sessionIndex].exchanges[exchangeIndex].editedQuestion != nil
        else { return }
        sessions[sessionIndex].exchanges[exchangeIndex].editedQuestion = nil
        flush()
    }

    func restoreAnswer(id: UUID) {
        guard let (sessionIndex, exchangeIndex) = editableExchangeLocation(id: id),
            sessions[sessionIndex].exchanges[exchangeIndex].editedAnswer != nil
        else { return }
        sessions[sessionIndex].exchanges[exchangeIndex].editedAnswer = nil
        flush()
    }

    func deleteSession(id: UUID) {
        guard let index = editableSessionIndex(id: id) else { return }
        sessions.remove(at: index)
        flush()
    }

    func deleteExchange(id: UUID) {
        guard let (sessionIndex, exchangeIndex) = editableExchangeLocation(id: id) else { return }
        sessions[sessionIndex].exchanges.remove(at: exchangeIndex)
        flush()
    }

    func exportMarkdown(id: UUID) -> String? {
        guard let session = sessions.first(where: { $0.id == id }) else { return nil }
        let labels = InterviewMarkdownLabels(language: session.language)
        let formatter = Self.exportDateFormatter(for: session.language)
        let lines = [
            "# \(session.title)",
            "",
            "\(labels.started)\(formatter.string(from: session.startedAt))",
            "\(labels.ended)\(session.endedAt.map { formatter.string(from: $0) } ?? labels.notFinished)",
            "",
            session.displayMarkdown,
        ]
        return lines.joined(separator: "\n")
    }

    private func editableSessionIndex(id: UUID) -> Int? {
        guard activeSessionID == nil,
            let index = sessions.firstIndex(where: { $0.id == id }),
            sessions[index].endedAt != nil
        else { return nil }
        return index
    }

    private func exchangeLocation(id: UUID) -> (Int, Int)? {
        for sessionIndex in sessions.indices {
            if let exchangeIndex = sessions[sessionIndex].exchanges.firstIndex(where: { $0.id == id }) {
                return (sessionIndex, exchangeIndex)
            }
        }
        return nil
    }

    private func editableExchangeLocation(id: UUID) -> (Int, Int)? {
        guard let location = exchangeLocation(id: id),
            editableSessionIndex(id: sessions[location.0].id) != nil
        else { return nil }
        return location
    }

    /// Immediately saves the latest state, including any pending partial transcript.
    /// Call before the application exits or recording is intentionally suspended.
    func flush() {
        cancelPendingTranscriptSave()
        persistNow()
    }

    private func scheduleTranscriptPersistence() {
        guard mayOverwriteStoreFile else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = lastPersistAttemptUptime.map { now - $0 } ?? transcriptSaveInterval
        if elapsed >= transcriptSaveInterval {
            flush()
            return
        }
        guard pendingTranscriptSave == nil else { return }

        let delay = transcriptSaveInterval - elapsed
        let generation = transcriptSaveGeneration
        pendingTranscriptSave = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard let self,
                !Task.isCancelled,
                generation == self.transcriptSaveGeneration
            else { return }
            self.pendingTranscriptSave = nil
            self.persistNow()
        }
    }

    private func cancelPendingTranscriptSave() {
        transcriptSaveGeneration &+= 1
        pendingTranscriptSave?.cancel()
        pendingTranscriptSave = nil
    }

    private func persistNow() {
        guard mayOverwriteStoreFile else { return }
        // Failed saves are throttled too; otherwise every partial result can
        // repeatedly hit an unavailable disk on the main actor.
        lastPersistAttemptUptime = ProcessInfo.processInfo.systemUptime
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(sessions)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: fileURL.path
            )
            persistenceError = nil
        } catch {
            persistenceError = L10n.text("面试记录保存失败：%@", error.localizedDescription)
        }
    }

    private static var titleDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }

    private static func exportDateFormatter(for language: InterviewLanguage) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = language.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }
}
