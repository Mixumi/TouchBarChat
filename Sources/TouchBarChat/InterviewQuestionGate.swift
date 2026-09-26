import Foundation

/// A conservative text-only hint for automatic answer generation.
///
/// Speech recognition often omits punctuation, and an instruction such as
/// "请介绍一下自己" is a complete interview prompt without a question mark.
/// This gate only identifies *candidates*: it cannot tell who spoke, whether
/// the speaker has finished, or whether a sentence is truly a question.
enum InterviewQuestionGate {
    static func isCandidate(
        _ transcript: String,
        language: InterviewLanguage = .chinese
    ) -> Bool {
        switch language {
        case .chinese:
            return isChineseCandidate(transcript)
        case .english, .korean, .japanese, .russian, .french, .portuguese:
            return isOtherLanguageCandidate(transcript, language: language)
        }
    }

    private static func isChineseCandidate(_ transcript: String) -> Bool {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = meaningfulText(text)

        guard !acknowledgements.contains(compact) else { return false }
        if shortFollowUps.contains(compact) { return true }
        guard compact.count >= 4 else { return false }

        if completeChinesePrompts.contains(where: { compact.contains($0) }) {
            return true
        }

        if chineseQuestionMarkers.contains(where: { compact.contains($0) }) {
            return true
        }

        // In a real interview the other side may introduce their team before
        // asking anything. Words such as “介绍一下” alone are not an instruction
        // to the candidate when the speaker is describing their own plan.
        if interviewerSelfNarration.contains(where: { compact.contains($0) }) {
            return false
        }

        // A verb alone ("谈谈") is not enough: wait for an object such as
        // "谈谈你的项目" before considering it a complete prompt.
        for directive in chineseDirectives {
            guard let range = compact.range(of: directive) else { continue }
            if compact[range.upperBound...].count >= 2 {
                return true
            }
        }

        if compact.hasSuffix("吗") || compact.hasSuffix("么") || text.hasSuffix("？") || text.hasSuffix("?") {
            return true
        }

        // English questions are common in bilingual interviews. Match whole
        // leading words, so "show" does not accidentally match "how".
        let englishWordCount = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
        guard englishWordCount >= 3 else { return false }
        return text.range(
            of: englishQuestionPattern,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func isOtherLanguageCandidate(
        _ transcript: String,
        language: InterviewLanguage
    ) -> Bool {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = meaningfulText(text)
        guard !compact.isEmpty, !languageAcknowledgements[language, default: []].contains(compact) else {
            return false
        }
        if languageShortFollowUps[language, default: []].contains(compact) {
            return true
        }

        // Recognition may omit a question mark. Conversely, a bare question
        // word or short backchannel is not enough to displace an AI answer.
        // Punctuation is accepted for complete phrases even when an ASR
        // transcript is too short for the stronger text patterns below. A
        // lone word with a question mark still needs a known follow-up form.
        let hasQuestionMark = text.hasSuffix("?") || text.hasSuffix("？")
        if hasQuestionMark {
            switch language {
            case .korean, .japanese:
                if compact.count >= 4 { return true }
            case .english, .russian, .french, .portuguese:
                if text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count >= 2 {
                    return true
                }
            case .chinese:
                break
            }
        }

        switch language {
        case .korean:
            guard compact.count >= 5 else { return false }
            return koreanQuestionMarkers.contains(where: { compact.contains($0) })
                || koreanDirectivePatterns.contains(where: { compact.contains($0) })
        case .japanese:
            guard compact.count >= 5 else { return false }
            return japaneseQuestionMarkers.contains(where: { compact.contains($0) })
                || japaneseDirectivePatterns.contains(where: { compact.contains($0) })
        case .english, .russian, .french, .portuguese:
            if completeLatinDirectives[language, default: []].contains(compact) {
                return true
            }
            let wordCount = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).count
            guard wordCount >= 3 else { return false }
            guard let pattern = promptPattern[language] else { return false }
            return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        case .chinese:
            return false
        }
    }

    private static func meaningfulText(_ text: String) -> String {
        String(text.filter { $0.isLetter || $0.isNumber }).lowercased()
    }

    private static let acknowledgements: Set<String> = [
        "好", "好的", "好的好的", "嗯", "嗯嗯", "是", "是的", "对", "对的",
        "没错", "没问题", "没有问题", "明白", "明白了", "收到", "可以",
        "你好", "您好", "早上好", "下午好", "晚上好", "谢谢", "谢谢你",
        "好的谢谢", "ok", "okay", "yes", "yeah", "right", "sure", "great",
        "thanks", "thankyou", "hello", "hi",
    ]

    private static let shortFollowUps: Set<String> = [
        "为什么", "为什么呢", "怎么做", "然后呢", "还有吗", "后来呢",
    ]

    private static let completeChinesePrompts = [
        "你怎么看", "举个例子", "举一个例子", "自我介绍", "介绍一下自己",
        "介绍下自己", "请用一句话概括", "用一句话概括", "分享一次经历",
    ]

    private static let interviewerSelfNarration = [
        "我来介绍", "我先介绍", "我们先介绍", "我会介绍", "我们会介绍",
        "接下来我介绍", "接下来我们介绍",
    ]

    private static let chineseQuestionMarkers = [
        "如何", "为什么", "为何", "怎么", "怎样", "什么", "哪些", "哪个",
        "能否", "能不能", "可不可以", "是否", "有没有", "你觉得", "你认为",
        "会不会",
    ]

    private static let chineseDirectives = [
        "请介绍", "介绍一下", "请描述", "描述一下", "请解释", "解释一下",
        "请分享", "分享一下", "请讲讲", "讲讲", "请说说", "说说", "谈谈",
        "聊聊", "举例", "讲一下", "请说明", "请谈一下", "谈一下",
        "请说一下", "说一下", "请讲述", "讲述",
    ]

    private static let englishQuestionPattern =
        #"(?:^|[.!?;:,。！？；，]\s*)(?:please\s+)?(?:how|why|what|when|where|which|who|can\s+you|could\s+you|would\s+you|will\s+you|do\s+you|did\s+you|have\s+you|tell\s+me|walk\s+me\s+through|introduce\s+yourself|describe|explain|give\s+(?:me\s+)?an?\s+example|talk\s+(?:to\s+me\s+)?about)\b"#

    /// The non-CJK patterns are anchored to a sentence start. Matching an
    /// isolated verb inside an interviewer introduction would submit an
    /// answer before the actual question has been asked.
    private static let promptPattern: [InterviewLanguage: String] = [
        .english: englishQuestionPattern,
        .russian:
            #"(?:^|[.!?;:,。！？；，]\s*)(?:пожалуйста[,. ]+)?(?:как|почему|что|когда|где|какой|какая|какие|кто|можете\s+ли\s+вы|представьтесь|расскажите|опишите|объясните|приведите\s+пример)\b"#,
        .french:
            #"(?:^|[.!?;:,。！？；，]\s*)(?:s['’]il\s+vous\s+plaît[,. ]+)?(?:comment|pourquoi|qu['’]est-ce|que|quel|quelle|quels|quelles|où|quand|pouvez-vous|pourriez-vous|présentez-vous|parlez-moi|racontez-moi|décrivez|expliquez|donnez\s+un\s+exemple)\b"#,
        .portuguese:
            #"(?:^|[.!?;:,。！？；，]\s*)(?:por\s+favor[,. ]+)?(?:como|por\s+que|por\s+quê|o\s+que|qual|quais|quando|onde|você\s+pode|poderia|apresente-se|fale\s+sobre|conte(?:-me)?|descreva|explique|dê\s+um\s+exemplo)\b"#,
    ]

    private static let languageAcknowledgements: [InterviewLanguage: Set<String>] = [
        .english: [
            "ok", "okay", "yes", "yeah", "right", "sure", "great", "thanks", "thankyou", "hello", "hi", "gotit",
        ],
        .korean: ["네", "예", "알겠습니다", "감사합니다", "좋아요", "그렇군요", "안녕하세요", "음"],
        .japanese: ["はい", "ええ", "そうです", "わかりました", "ありがとうございます", "こんにちは", "なるほど"],
        .russian: ["да", "хорошо", "спасибо", "понятно", "здравствуйте", "конечно"],
        .french: ["oui", "daccord", "merci", "bonjour", "trèsbien", "compris"],
        .portuguese: ["sim", "certo", "obrigado", "obrigada", "entendido", "tudobem", "olá"],
    ]

    private static let languageShortFollowUps: [InterviewLanguage: Set<String>] = [
        .english: ["why", "how", "whyso", "andthen", "whatnext"],
        .korean: ["왜요", "어떻게요", "그다음은요", "왜그런가요"],
        .japanese: ["なぜ", "どうして", "それから", "その理由は"],
        .russian: ["почему", "какименно", "чтодальше"],
        .french: ["pourquoi", "comment", "etensuite"],
        .portuguese: ["porque", "porquê", "comoassim", "edepois"],
    ]

    /// A few interview prompts are complete even though they contain fewer
    /// than three words; a general one-word question heuristic would be much
    /// more likely to mistake a backchannel for a new interview turn.
    private static let completeLatinDirectives: [InterviewLanguage: Set<String>] = [
        .english: ["introduceyourself"],
        .russian: ["представьтесь"],
        .french: ["présentezvous"],
        .portuguese: ["apresentese"],
    ]

    private static let koreanQuestionMarkers = [
        "어떻게", "왜그", "무엇", "무슨", "어떤", "어느", "어디", "언제", "얼마나",
        "하시나요", "하셨나요", "하시겠어요", "할수있나요", "생각하시나요",
    ]

    private static let koreanDirectivePatterns = [
        "자기소개해주세요", "자기소개를해주세요", "자기소개부탁드립니다",
        "설명해주세요", "말씀해주세요",
        "이야기해주세요", "예를들어주세요", "소개해주세요",
    ]

    private static let japaneseQuestionMarkers = [
        "どのように", "なぜ", "どうして", "何を", "何が", "どんな", "どちら", "いつ", "どこ",
        "ですか", "ますか", "でしょうか",
    ]

    private static let japaneseDirectivePatterns = [
        "自己紹介をお願いします", "自己紹介してください", "説明してください", "教えてください",
        "話してください", "例を挙げてください", "紹介してください",
    ]
}

/// Existing call sites can migrate to InterviewQuestionGate incrementally.
/// The default remains Simplified Chinese for older tests and saved sessions.
enum ChineseQuestionGate {
    static func isCandidate(
        _ transcript: String,
        language: InterviewLanguage = .chinese
    ) -> Bool {
        InterviewQuestionGate.isCandidate(transcript, language: language)
    }
}
