import Foundation

/// Labels are stored with the interview language so an exported document does
/// not change when the user later changes the macOS interface language.
struct InterviewMarkdownLabels {
    let interviewTitle: String
    let interviewer: String
    let ai: String
    let noAnswer: String
    let answerStatus: String
    let incomplete: String
    let originalTranscript: String
    let empty: String
    let started: String
    let ended: String
    let notFinished: String

    init(language: InterviewLanguage) {
        switch language {
        case .chinese:
            self = Self("面试", "面试官：", "AI：", "（未生成回答）", "回答状态：", "未完成", "原始转写", "暂无内容。", "开始：", "结束：", "未正常结束")
        case .english:
            self = Self(
                "Interview", "Interviewer:", "AI:", "(No answer generated)", "Answer status:", "Incomplete",
                "Original transcript", "No content yet.", "Started:", "Ended:", "Not ended normally")
        case .korean:
            self = Self(
                "면접", "면접관:", "AI:", "(생성된 답변 없음)", "답변 상태:", "미완료", "원본 전사", "아직 내용이 없습니다.", "시작:", "종료:",
                "정상적으로 종료되지 않음")
        case .japanese:
            self = Self(
                "面接", "面接官：", "AI：", "（回答は生成されていません）", "回答の状態：", "未完了", "元の文字起こし", "内容はまだありません。", "開始：", "終了：",
                "正常に終了していません")
        case .russian:
            self = Self(
                "Собеседование", "Интервьюер:", "ИИ:", "(Ответ не создан)", "Статус ответа:", "Не завершён",
                "Исходная расшифровка", "Пока нет записей.", "Начало:", "Окончание:", "Не завершено обычным образом")
        case .french:
            self = Self(
                "Entretien", "Recruteur :", "IA :", "(Aucune réponse générée)", "État de la réponse :", "Incomplet",
                "Transcription originale", "Aucun contenu pour le moment.", "Début :", "Fin :", "Fin anormale")
        case .portuguese:
            self = Self(
                "Entrevista", "Entrevistador:", "IA:", "(Nenhuma resposta gerada)", "Estado da resposta:", "Incompleto",
                "Transcrição original", "Ainda não há conteúdo.", "Início:", "Fim:", "Não encerrado normalmente")
        }
    }

    /// Older records stored Chinese status prose. Translate only known stable
    /// values; keep arbitrary provider error details verbatim for diagnosis.
    func statusDescription(_ status: String, language: InterviewLanguage) -> String {
        if status.hasPrefix("生成失败：") {
            let detail = String(status.dropFirst("生成失败：".count))
            return L10n.localizedText(
                "生成失败：%@",
                localeIdentifier: language.localizationCode,
                arguments: [detail]
            )
        }
        let localized = L10n.localizedText(status, localeIdentifier: language.localizationCode)
        if localized != status { return localized }
        switch status {
        case "未配置 AI 接口":
            switch language {
            case .chinese: return status
            case .english: return "AI API not configured"
            case .korean: return "AI API가 설정되지 않음"
            case .japanese: return "AI API が設定されていません"
            case .russian: return "API ИИ не настроен"
            case .french: return "API d’IA non configurée"
            case .portuguese: return "API de IA não configurada"
            }
        case "生成中（部分回答）", "回答生成中", "generating":
            switch language {
            case .chinese: return "生成中（部分回答）"
            case .english: return "Generating (partial answer)"
            case .korean: return "생성 중 (부분 답변)"
            case .japanese: return "生成中（回答は未完了）"
            case .russian: return "Формируется (частичный ответ)"
            case .french: return "Génération en cours (réponse partielle)"
            case .portuguese: return "Gerando (resposta parcial)"
            }
        case "回答中断":
            switch language {
            case .chinese: return status
            case .english: return "Answer interrupted"
            case .korean: return "답변 중단됨"
            case .japanese: return "回答が中断されました"
            case .russian: return "Ответ прерван"
            case .french: return "Réponse interrompue"
            case .portuguese: return "Resposta interrompida"
            }
        default:
            return status
        }
    }

    private init(
        _ interviewTitle: String,
        _ interviewer: String,
        _ ai: String,
        _ noAnswer: String,
        _ answerStatus: String,
        _ incomplete: String,
        _ originalTranscript: String,
        _ empty: String,
        _ started: String,
        _ ended: String,
        _ notFinished: String
    ) {
        self.interviewTitle = interviewTitle
        self.interviewer = interviewer
        self.ai = ai
        self.noAnswer = noAnswer
        self.answerStatus = answerStatus
        self.incomplete = incomplete
        self.originalTranscript = originalTranscript
        self.empty = empty
        self.started = started
        self.ended = ended
        self.notFinished = notFinished
    }
}
