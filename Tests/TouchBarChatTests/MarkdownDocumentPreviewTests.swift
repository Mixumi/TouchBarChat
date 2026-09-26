import AppKit
import Testing

@testable import TouchBarChat

@MainActor
struct MarkdownDocumentPreviewTests {
    @Test
    func previewKeepsQuestionAnswerParagraphsAndListItemsSeparate() throws {
        let markdown = "**面试官：** 你好\n\n**AI：** 回答\n\n- 第一条\n- 第二条"
        let rendered = MarkdownDocumentPreview.render(markdown)

        #expect(rendered.string == "面试官： 你好\n\nAI： 回答\n\n• 第一条\n• 第二条")

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        textView.textStorage?.setAttributedString(rendered)
        let container = try #require(textView.textContainer)
        let layoutManager = try #require(textView.layoutManager)
        container.containerSize = NSSize(width: 500, height: 10_000)
        layoutManager.ensureLayout(for: container)
        #expect(layoutManager.usedRect(for: container).height > 40)
    }
}
