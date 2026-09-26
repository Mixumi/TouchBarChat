import AppKit
import Testing

@testable import TouchBarChat

@Suite(.serialized)
@MainActor
struct TouchBarControllerTests {
    @Test
    func contentStartsOnTheLeftAndUsesAvailableWidth() throws {
        let (controller, label, _) = try makeHarness()
        let touchBar = controller.makeTouchBar()
        #expect(touchBar.principalItemIdentifier == nil)
        #expect(
            touchBar.defaultItemIdentifiers.prefix(3) == [
                NSTouchBarItem.Identifier("dev.touchbarchat.role"),
                .fixedSpaceSmall,
                NSTouchBarItem.Identifier("dev.touchbarchat.answer"),
            ])
        #expect(touchBar.defaultItemIdentifiers.count == 3)
        #expect(label.alignment == .left)
        let stack = try #require(label.superview as? NSStackView)
        #expect(
            stack.constraints.contains {
                $0.firstAttribute == .width && $0.constant == 320 && $0.priority == .defaultLow
            })
        #expect(
            stack.constraints.contains {
                $0.firstAttribute == .width && $0.relation == .greaterThanOrEqual
                    && $0.constant == 100
            })
        #expect(stack.detachesHiddenViews)
        let buttons = stack.views.compactMap { $0 as? NSButton }
        #expect(buttons.count == 2)
        #expect(buttons.allSatisfy { $0.isHidden })

        let transcript = (0..<100).map { String(format: "%03d", $0) }.joined(separator: " ")
        controller.updateTranscript(transcript)
        let wideText = label.stringValue
        label.setFrameSize(NSSize(width: 350, height: 30))
        #expect(label.stringValue != wideText)
        #expect(label.stringValue.split(separator: "\n").count <= 2)
    }

    @Test
    func answerControlsRemainInsideTheTextItemAtCompactWidths() throws {
        let (controller, label, _) = try makeHarness()
        controller.updateStreamingAnswer(String(repeating: "回答", count: 80), isFinal: false)
        let stack = try #require(label.superview as? NSStackView)
        let buttons = stack.views.compactMap { $0 as? NSButton }
        #expect(buttons.count == 2)
        #expect(buttons.allSatisfy { !$0.isHidden })
        #expect(controller.makeTouchBar().defaultItemIdentifiers.count == 3)

        stack.frame = NSRect(x: 0, y: 0, width: 160, height: 30)
        stack.layoutSubtreeIfNeeded()
        #expect(label.bounds.width >= 35)
        #expect(buttons.allSatisfy { $0.bounds.width == 23 })
        #expect(buttons.allSatisfy { $0.superview === stack })
    }

    @Test
    func transcriptRollsByOneLineAndFirstAIChunkSwitchesRole() throws {
        let (controller, label, icon) = try makeHarness()
        controller.beginTranscriptTurn()
        controller.updateTranscript(String(repeating: "甲", count: 140))
        controller.updateTranscript(
            String(repeating: "甲", count: 140) + String(repeating: "乙", count: 140)
        )
        #expect(label.stringValue.split(separator: "\n").count == 2)
        #expect(!label.stringValue.contains("甲"))
        #expect(label.stringValue.contains("乙"))
        #expect(icon.image?.accessibilityDescription == L10n.text("电脑播放声音的转录"))

        let transcriptDisplay = label.stringValue
        controller.beginAnswerGeneration()
        #expect(label.stringValue == transcriptDisplay)
        #expect(!controller.isShowingGeneratedAnswer)

        controller.updateStreamingAnswer("我会先确认目标。", isFinal: false)
        #expect(controller.isShowingGeneratedAnswer)
        #expect(icon.image?.accessibilityDescription == L10n.text("AI 回答"))
        #expect(label.stringValue == "我会先确认目标。")
        let stack = try #require(label.superview as? NSStackView)
        let buttons = stack.views.compactMap { $0 as? NSButton }
        #expect(buttons.count == 2)
        #expect(buttons.allSatisfy { !$0.isHidden })
        #expect(!buttons[0].isEnabled)
        #expect(!buttons[1].isEnabled)
    }

    @Test
    func retractedSpeechFragmentClearsTheTouchBarTranscript() throws {
        let (controller, label, icon) = try makeHarness()
        controller.beginTranscriptTurn()
        controller.updateTranscript("我")
        #expect(label.stringValue == "我")

        controller.updateTranscript("")
        #expect(label.stringValue == L10n.text("正在转写…"))
        #expect(icon.image?.accessibilityDescription == L10n.text("电脑播放声音的转录"))
    }

    @Test
    func answerReviewStaysPutUntilTheUserCatchesUp() throws {
        let (controller, label, icon) = try makeHarness()
        controller.beginTranscriptTurn()
        controller.updateTranscript("请介绍一次协作经历")
        let firstAnswer = ["甲", "乙", "丙", "丁"].map {
            String(repeating: $0, count: 45)
        }.joined()
        controller.updateStreamingAnswer(firstAnswer, isFinal: false)
        let newestBeforeReview = label.stringValue

        controller.previousPage()
        let reviewedText = label.stringValue
        #expect(reviewedText != newestBeforeReview)
        let stack = try #require(label.superview as? NSStackView)
        let buttons = stack.views.compactMap { $0 as? NSButton }
        #expect(buttons.count == 2)
        #expect(buttons[1].isEnabled)
        let newestLines = newestBeforeReview.split(separator: "\n")
        let reviewedLines = reviewedText.split(separator: "\n")
        #expect(newestLines.count == 2)
        #expect(reviewedLines.count == 2)
        #expect(reviewedLines[1] == newestLines[0])

        controller.updateStreamingAnswer(
            firstAnswer + String(repeating: "戊", count: 100),
            isFinal: false
        )
        #expect(label.stringValue == reviewedText)

        for _ in 0..<20 { controller.nextPage() }
        #expect(label.stringValue.contains("戊"))
        controller.updateStreamingAnswer(
            firstAnswer + String(repeating: "戊", count: 100) + String(repeating: "己", count: 100),
            isFinal: true
        )
        #expect(label.stringValue.contains("己"))

        controller.beginTranscriptTurn()
        #expect(!controller.isShowingGeneratedAnswer)
        #expect(icon.image?.accessibilityDescription == L10n.text("电脑播放声音的转录"))
        #expect(label.stringValue == L10n.text("正在转写…"))
        #expect(buttons.allSatisfy { $0.isHidden })
    }

    @Test
    func secondQuestionReplacesFirstAnswerAndCompletionDoesNotMoveReviewWindow() throws {
        let (controller, label, icon) = try makeHarness()
        controller.updateTranscript("第一题是什么？")
        controller.updateStreamingAnswer(String(repeating: "甲", count: 180), isFinal: false)
        #expect(icon.image?.accessibilityDescription == L10n.text("AI 回答"))

        controller.beginTranscriptTurn()
        controller.updateTranscript("第二题为什么要这样做？")
        #expect(icon.image?.accessibilityDescription == L10n.text("电脑播放声音的转录"))
        #expect(label.stringValue == "第二题为什么要这样做？")
        #expect(!label.stringValue.contains("甲"))

        let secondAnswer = String(repeating: "乙", count: 160)
        controller.beginAnswerGeneration()
        #expect(label.stringValue == "第二题为什么要这样做？")
        controller.updateStreamingAnswer(secondAnswer, isFinal: false)
        controller.previousPage()
        let reviewedText = label.stringValue
        controller.updateStreamingAnswer(secondAnswer + String(repeating: "丙", count: 90), isFinal: true)
        #expect(label.stringValue == reviewedText)
        #expect(controller.isShowingGeneratedAnswer)
    }

    private func makeHarness() throws -> (TouchBarController, NSTextField, NSImageView) {
        let controller = TouchBarController()
        controller.startLiveDisplay()
        let touchBar = NSTouchBar()
        let contentIdentifier = NSTouchBarItem.Identifier("dev.touchbarchat.answer")
        let roleIdentifier = NSTouchBarItem.Identifier("dev.touchbarchat.role")
        let contentItem = try #require(
            controller.touchBar(touchBar, makeItemForIdentifier: contentIdentifier)
                as? NSCustomTouchBarItem
        )
        let roleItem = try #require(
            controller.touchBar(touchBar, makeItemForIdentifier: roleIdentifier)
                as? NSCustomTouchBarItem
        )
        let stack = try #require(contentItem.view as? NSStackView)
        let label = try #require(stack.views.first as? NSTextField)
        let icon = try #require(roleItem.view.subviews.first as? NSImageView)
        return (controller, label, icon)
    }
}
