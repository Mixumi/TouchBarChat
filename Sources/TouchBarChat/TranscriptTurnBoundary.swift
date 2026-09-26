import Foundation

/// Keeps the unanswered portion of a cumulative Speech transcript. Speech may
/// revise words before the current turn, so a fixed character offset is not
/// sufficient: edits before the boundary move it along with the text.
struct TranscriptTurnBoundary {
    private(set) var transcript = ""
    private(set) var committedOffset = 0

    var pendingText: String {
        String(transcript.dropFirst(committedOffset))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func reset(committedPrefix: String = "") {
        transcript = committedPrefix
        committedOffset = committedPrefix.count
    }

    mutating func update(_ newTranscript: String) {
        guard newTranscript != transcript else { return }
        let old = Array(transcript)
        let new = Array(newTranscript)
        var commonPrefix = 0
        while commonPrefix < min(old.count, new.count),
            old[commonPrefix] == new[commonPrefix]
        {
            commonPrefix += 1
        }

        var commonSuffix = 0
        while commonSuffix < old.count - commonPrefix,
            commonSuffix < new.count - commonPrefix,
            old[old.count - commonSuffix - 1] == new[new.count - commonSuffix - 1]
        {
            commonSuffix += 1
        }
        let oldEditEnd = old.count - commonSuffix
        let newEditEnd = new.count - commonSuffix

        if commonPrefix < committedOffset {
            if let anchoredBoundary = Self.revisedBoundary(
                old: old,
                new: new,
                oldBoundary: committedOffset,
                searchStart: commonPrefix
            ) {
                committedOffset = anchoredBoundary
            } else if oldEditEnd <= committedOffset {
                committedOffset += newEditEnd - oldEditEnd
            } else {
                // A revision crossed the old turn boundary and no reliable
                // anchor survived. Skip the changed span rather than resend
                // words from a previous, already answered question.
                committedOffset = newEditEnd
            }
        }

        transcript = newTranscript
        committedOffset = min(max(0, committedOffset), new.count)
    }

    mutating func commitCurrentText() {
        committedOffset = transcript.count
    }

    /// Mark only the transcription snapshot sent with an answer as handled.
    /// Short words from the next turn may have arrived while the answer was
    /// streaming; committing the live end would silently discard them.
    mutating func commitThrough(_ submittedTranscript: String) {
        var sentBoundary = Self()
        sentBoundary.reset(committedPrefix: submittedTranscript)
        sentBoundary.update(transcript)
        committedOffset = max(committedOffset, sentBoundary.committedOffset)
    }

    private static func revisedBoundary(
        old: [Character],
        new: [Character],
        oldBoundary: Int,
        searchStart: Int
    ) -> Int? {
        guard oldBoundary >= 2, searchStart < new.count else { return nil }
        let largestAnchor = min(24, oldBoundary - searchStart)
        guard largestAnchor >= 2 else { return nil }
        for anchorLength in stride(from: largestAnchor, through: 2, by: -1) {
            let anchor = Array(old[(oldBoundary - anchorLength)..<oldBoundary])
            let lastStart = new.count - anchorLength
            guard searchStart <= lastStart else { continue }
            for start in searchStart...lastStart where Array(new[start..<(start + anchorLength)]) == anchor {
                let boundary = start + anchorLength
                guard boundary == new.count || Self.looksLikeTurnSeparator(new[boundary]) else {
                    continue
                }
                return boundary
            }
        }
        return nil
    }

    private static func looksLikeTurnSeparator(_ character: Character) -> Bool {
        character.isWhitespace || "，。！？,.!?;；:：".contains(character)
            || "你请什怎为能会是有哪谈讲".contains(character)
    }
}
