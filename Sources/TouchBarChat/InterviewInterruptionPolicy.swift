import Foundation

/// Audio activity is only a hint that something is playing; it cannot tell
/// whether the interviewer has started another question. During an AI answer,
/// wait for changed transcript content before invalidating that answer.
enum InterviewInterruptionPolicy {
    enum Decision: Equatable {
        case unchanged
        case waitForMoreSpeech
        case reviseCurrentQuestion
        case extendCurrentQuestion
        case newSpeech(String)
    }

    static func classify(
        submittedQuestion: String,
        currentQuestion: String,
        submittedTranscript: String,
        currentTranscript: String,
        language: InterviewLanguage = .chinese
    ) -> Decision {
        let submitted = meaningfulText(submittedQuestion)
        let current = meaningfulText(currentQuestion)
        guard current != submitted else { return .unchanged }

        // A change inside the question already sent to the model can change
        // its meaning even if it is short (for example, "是" -> "不是").
        guard current.hasPrefix(submitted) else { return .reviseCurrentQuestion }

        let addedText = newSpeech(
            submittedTranscript: submittedTranscript,
            currentTranscript: currentTranscript
        )
        let addedMeaning = meaningfulText(addedText)
        guard !addedMeaning.isEmpty else { return .reviseCurrentQuestion }

        // A pause inside one question is common. An added constraint beginning
        // with a connective belongs to the original prompt, even if it is
        // longer than the display threshold used for independent speech.
        if !InterviewQuestionGate.isCandidate(addedText, language: language),
            beginsWithContinuation(addedText, language: language)
        {
            return .extendCurrentQuestion
        }

        // A short acknowledgement is not yet a new interview turn. A compact
        // follow-up such as "为什么" is, while longer continued speech is
        // displayed even before its question wording becomes complete.
        if shouldReplaceAnswerWithTranscript(addedText, language: language) {
            return .newSpeech(addedText)
        }
        return .waitForMoreSpeech
    }

    /// Project cumulative recognition onto the speech after an interrupted
    /// answer. A previous question's marker must not make an unrelated new
    /// statement look like an answerable prompt.
    static func newSpeech(submittedTranscript: String, currentTranscript: String) -> String {
        var nextSpeech = TranscriptTurnBoundary()
        nextSpeech.reset(committedPrefix: submittedTranscript)
        nextSpeech.update(currentTranscript)
        let leadingSeparators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "，。！？,.!?;；:："))
        return String(
            nextSpeech.pendingText.drop(while: { character in
                character.unicodeScalars.allSatisfy { leadingSeparators.contains($0) }
            }))
    }

    /// Use the same threshold after an answer has completed. Starting a new
    /// Touch Bar transcript for a one-word backchannel would erase the answer
    /// before there is evidence of an actual next turn.
    static func shouldReplaceAnswerWithTranscript(
        _ text: String,
        language: InterviewLanguage = .chinese
    ) -> Bool {
        if InterviewQuestionGate.isCandidate(text, language: language) { return true }

        // This threshold only controls when to replace an existing Touch Bar
        // answer with new live text; it does not submit the text to the model.
        // Non-CJK languages need a word threshold rather than six letters,
        // which could be only a single short acknowledgement or filler.
        switch language {
        case .chinese:
            return meaningfulText(text).count >= 6
        case .japanese, .korean:
            return meaningfulText(text).count >= 9
        case .english, .russian, .french, .portuguese:
            return text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count >= 4
        }
    }

    private static func meaningfulText(_ text: String) -> String {
        String(text.filter { $0.isLetter || $0.isNumber }).lowercased()
    }

    private static func beginsWithContinuation(
        _ text: String,
        language: InterviewLanguage
    ) -> Bool {
        let prefixes = continuationPrefixes[language, default: []]
        if language == .chinese || language == .korean || language == .japanese {
            let compact = meaningfulText(text)
            return prefixes.contains { compact.hasPrefix(meaningfulText($0)) }
        }

        // Match whole words so an English name such as "Andrew" is not
        // mistaken for the connective "and" after spaces are stripped.
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return prefixes.contains { prefix in
            let prefixWords = prefix.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            return words.starts(with: prefixWords)
        }
    }

    private static let continuationPrefixes: [InterviewLanguage: [String]] = [
        .chinese: [
            "以及", "并且", "同时", "包括", "比如", "例如", "尤其是", "特别是",
            "也就是说", "就是说", "补充一下", "其中", "还有一点", "并谈谈",
        ],
        .english: ["and", "also", "including", "for example", "more specifically", "in particular"],
        .korean: ["그리고", "또한", "예를들어", "특히", "추가로"],
        .japanese: ["そして", "また", "例えば", "特に", "加えて"],
        .russian: ["и", "атакже", "например", "особенно", "крометого"],
        .french: ["et", "aussi", "parexemple", "enparticulier", "deplus"],
        .portuguese: ["e", "também", "porexemplo", "emespecial", "alémdisso"],
    ]
}
