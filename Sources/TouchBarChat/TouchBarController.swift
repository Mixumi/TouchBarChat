import AppKit

@MainActor
private final class TouchBarContentLabel: NSTextField {
    var onWidthChange: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        let oldWidth = frame.width
        super.setFrameSize(newSize)
        if abs(newSize.width - oldWidth) > 1 {
            onWidthChange?()
        }
    }
}

@MainActor
final class TouchBarController: NSObject, NSTouchBarDelegate {
    private enum ItemIdentifier {
        static let role = NSTouchBarItem.Identifier("dev.touchbarchat.role")
        static let answer = NSTouchBarItem.Identifier("dev.touchbarchat.answer")
    }

    private enum ContentRole {
        case transcript
        case answer
    }

    private static let contentFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    // A Touch Bar may leave much less room after Escape and Control Strip.
    // The content item must fit before AppKit will offer it any extra space.
    private static let preferredContentWidth: CGFloat = 320
    private static let compactContentWidth: CGFloat = 160
    private static let minimumContentWidth: CGFloat = 100
    private static let contentHorizontalInset: CGFloat = 16

    private var presentedTouchBar: NSTouchBar?
    private var roleTile: NSView?
    private var roleImageView: NSImageView?
    private var contentStack: NSStackView?
    private var contentLabel: NSTextField?
    private var contentWidthConstraint: NSLayoutConstraint?
    private var previousButton: NSButton?
    private var nextButton: NSButton?
    private var usesCompactLayout = false

    private var livePlaceholder = L10n.text("等待电脑播放的声音…")
    private var transcriptText = ""
    private var answerText = ""
    private var answerLines: [String] = []
    // nil follows the newest two lines; an index holds that window while AI streams.
    private var reviewStartLine: Int?
    private var statusMessage: String?
    private var isCapturePaused = false

    private(set) var isLiveDisplaying = false
    private(set) var isShowingGeneratedAnswer = false

    var isPresented: Bool {
        presentedTouchBar != nil
    }

    /// AppKit reports item visibility only when the item is in a currently
    /// visible bar; successfully invoking a private presentation selector is
    /// not proof that this Mac has a visible Touch Bar.
    var hasVisibleAnswerItem: Bool {
        presentedTouchBar?.item(forIdentifier: ItemIdentifier.answer)?.isVisible == true
    }

    var visibilitySummary: String {
        guard let presentedTouchBar else { return L10n.text("未显示 Touch Bar 内容") }
        let identifiers = [ItemIdentifier.role, ItemIdentifier.answer]
        let visibleCount = identifiers.reduce(into: 0) { count, identifier in
            if presentedTouchBar.item(forIdentifier: identifier)?.isVisible == true {
                count += 1
            }
        }
        let navigation =
            hasVisibleAnswerItem && shouldShowAnswerNavigation
                && previousButton?.isHidden == false && nextButton?.isHidden == false
            ? L10n.text("，AI 翻页按钮可见") : ""
        return L10n.text("%d/%d 个 Touch Bar 项目可见%@", visibleCount, identifiers.count, navigation)
    }

    /// AppKit can omit an oversized custom item while still showing the role icon.
    /// Only compact when that omission is observed on a genuinely visible bar.
    /// Returns true once when the fallback width is applied; repeated calls are safe.
    @discardableResult
    func recoverContentVisibilityIfNeeded() -> Bool {
        guard let presentedTouchBar,
            !usesCompactLayout,
            presentedTouchBar.item(forIdentifier: ItemIdentifier.role)?.isVisible == true,
            presentedTouchBar.item(forIdentifier: ItemIdentifier.answer)?.isVisible == false
        else {
            return false
        }
        usesCompactLayout = true
        contentWidthConstraint?.constant = Self.compactContentWidth
        contentStack?.needsLayout = true
        contentStack?.layoutSubtreeIfNeeded()
        return true
    }

    @discardableResult
    func show() -> Bool {
        dismiss()

        let touchBar = makeTouchBar()
        guard SystemModalTouchBar.present(touchBar) else { return false }
        presentedTouchBar = touchBar
        updateDisplayedContent()
        return true
    }

    // Kept separate from presentation so layout can be checked without a
    // physical Touch Bar or the private modal presentation call.
    func makeTouchBar() -> NSTouchBar {
        let touchBar = NSTouchBar()
        touchBar.delegate = self
        touchBar.customizationIdentifier = NSTouchBar.CustomizationIdentifier("dev.touchbarchat.touchbar")
        touchBar.defaultItemIdentifiers = [ItemIdentifier.role, .fixedSpaceSmall, ItemIdentifier.answer]
        // A principal item is centered by AppKit; this bar reads from the left.
        touchBar.principalItemIdentifier = nil
        return touchBar
    }

    func dismiss() {
        if let presentedTouchBar {
            SystemModalTouchBar.dismiss(presentedTouchBar)
        }
        presentedTouchBar = nil
        roleTile = nil
        roleImageView = nil
        contentStack = nil
        contentLabel = nil
        contentWidthConstraint = nil
        previousButton = nil
        nextButton = nil
        usesCompactLayout = false
    }

    func startLiveDisplay() {
        isLiveDisplaying = true
        isCapturePaused = false
        resetTurnContent()
        livePlaceholder = L10n.text("等待电脑播放的声音…")
        updateDisplayedContent()
    }

    func updateLiveStatus(_ status: String) {
        guard isLiveDisplaying else { return }
        livePlaceholder = Self.compactStatus(status, fallback: L10n.text("正在聆听…"))
        if !isShowingGeneratedAnswer && transcriptText.isEmpty { updateDisplayedContent() }
    }

    /// A recognition event without a text snapshot can still update the placeholder.
    func updateRecognitionActivity(hasText: Bool, isFinal: Bool) {
        guard isLiveDisplaying, !isShowingGeneratedAnswer else { return }
        if hasText {
            livePlaceholder =
                isFinal
                ? L10n.text("等待下一段声音…") : L10n.text("正在转写…")
            if transcriptText.isEmpty { updateDisplayedContent() }
        }
    }

    /// Start a new interviewer turn. This can be called before or after `show()`.
    /// It immediately removes the old answer and its navigation controls.
    func beginTranscriptTurn() {
        resetTurnContent()
        livePlaceholder = L10n.text("正在转写…")
        updateDisplayedContent()
    }

    /// Replace the current turn's transcript with Speech's latest partial/final snapshot.
    /// Recognition may revise prior words, so this is not an append-only API.
    func updateTranscript(_ text: String) {
        transcriptText = Self.normalizedText(text)
        statusMessage = nil
        if !isShowingGeneratedAnswer { updateDisplayedContent() }
    }

    /// Keep the transcript in view while the AI request waits for its first text chunk.
    func beginAnswerGeneration() {
        statusMessage = nil
        if transcriptText.isEmpty { livePlaceholder = L10n.text("正在生成回答…") }
        updateDisplayedContent()
    }

    /// Replace the cumulative AI answer snapshot; the first nonempty snapshot switches roles.
    /// While reviewing older lines, new text is accumulated without moving the review window.
    func updateStreamingAnswer(_ text: String, isFinal: Bool) {
        let normalized = Self.normalizedText(text)
        guard !normalized.isEmpty else {
            if isFinal { showGenerationStatus(L10n.text("AI 未返回回答")) }
            return
        }
        if !isShowingGeneratedAnswer { reviewStartLine = nil }
        answerText = normalized
        isShowingGeneratedAnswer = true
        answerLines = Self.wrappedLines(normalized, width: contentLineWidth)
        statusMessage = nil
        if let reviewStartLine {
            self.reviewStartLine = min(reviewStartLine, newestAnswerStartLine)
        }
        updateDisplayedContent()
    }

    func stopLiveDisplay() {
        guard isLiveDisplaying else { return }
        isLiveDisplaying = false
        isCapturePaused = false
        resetTurnContent()
        updateDisplayedContent()
    }

    /// Compatibility entry point for a complete, non-streaming answer.
    func showGeneratedAnswer(_ text: String) {
        updateStreamingAnswer(text, isFinal: true)
    }

    /// Error/hold messages are not answer content and never enable AI navigation.
    func showGenerationStatus(_ status: String) {
        statusMessage = Self.compactStatus(status, fallback: L10n.text("正在生成回答…"))
        updateDisplayedContent()
    }

    func setCapturePaused(_ paused: Bool) {
        guard isLiveDisplaying else { return }
        isCapturePaused = paused
        updateDisplayedContent()
    }

    func clearAnswerForNextTurn() {
        beginTranscriptTurn()
    }

    /// Safe to call from an application-wide keyboard shortcut. Moves one line.
    func previousPage() {
        guard !isCapturePaused, isShowingGeneratedAnswer, statusMessage == nil else { return }
        let currentStart = reviewStartLine ?? newestAnswerStartLine
        guard currentStart > 0 else { return }
        reviewStartLine = currentStart - 1
        updateDisplayedContent()
    }

    /// Safe to call from an application-wide keyboard shortcut. Catches up one line.
    func nextPage() {
        guard !isCapturePaused, isShowingGeneratedAnswer, statusMessage == nil,
            let reviewStartLine
        else { return }
        let nextStart = reviewStartLine + 1
        self.reviewStartLine = nextStart >= newestAnswerStartLine ? nil : nextStart
        updateDisplayedContent()
    }

    func touchBar(
        _ touchBar: NSTouchBar,
        makeItemForIdentifier identifier: NSTouchBarItem.Identifier
    ) -> NSTouchBarItem? {
        switch identifier {
        case ItemIdentifier.role:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let tile = NSView()
            tile.translatesAutoresizingMaskIntoConstraints = false
            tile.widthAnchor.constraint(equalToConstant: 28).isActive = true
            tile.heightAnchor.constraint(equalToConstant: 28).isActive = true
            tile.wantsLayer = true
            tile.layer?.cornerRadius = 5

            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyDown
            tile.addSubview(imageView)
            NSLayoutConstraint.activate([
                imageView.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
                imageView.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 17),
                imageView.heightAnchor.constraint(equalToConstant: 17),
            ])
            roleTile = tile
            roleImageView = imageView
            item.view = tile
            item.customizationLabel = L10n.text("内容来源")
            item.visibilityPriority = .high
            updateDisplayedContent()
            return item

        case ItemIdentifier.answer:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let label = TouchBarContentLabel(labelWithString: "")
            label.font = Self.contentFont
            label.textColor = .labelColor
            label.alignment = .left
            label.lineBreakMode = .byClipping
            label.maximumNumberOfLines = 2
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentHuggingPriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.init(rawValue: 100), for: .horizontal)

            let previous = makeNavigationButton(
                symbol: "chevron.up",
                fallback: "⌃",
                action: #selector(previousPageAction),
                label: L10n.text("查看上一行 AI 回答")
            )
            let next = makeNavigationButton(
                symbol: "chevron.down",
                fallback: "⌄",
                action: #selector(nextPageAction),
                label: L10n.text("查看下一行 AI 回答")
            )
            previous.isHidden = true
            next.isHidden = true

            // The buttons share the text's item. AppKit cannot hide them
            // independently when space is tight, and a live answer no longer
            // relies on changing defaultItemIdentifiers after presentation.
            let stack = NSStackView(views: [label, previous, next])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.distribution = .fill
            stack.spacing = 4
            stack.detachesHiddenViews = true
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.setContentHuggingPriority(.defaultLow, for: .horizontal)
            stack.setContentCompressionResistancePriority(.init(rawValue: 100), for: .horizontal)
            let preferredWidth = stack.widthAnchor.constraint(equalToConstant: Self.preferredContentWidth)
            preferredWidth.priority = .defaultLow
            preferredWidth.isActive = true
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumContentWidth).isActive = true
            stack.heightAnchor.constraint(equalToConstant: 30).isActive = true
            label.heightAnchor.constraint(equalToConstant: 30).isActive = true
            contentStack = stack
            contentLabel = label
            contentWidthConstraint = preferredWidth
            previousButton = previous
            nextButton = next
            label.onWidthChange = { [weak self] in self?.contentWidthDidChange() }
            item.view = stack
            item.customizationLabel = L10n.text("实时转录与 AI 回答")
            item.visibilityPriority = .high
            updateDisplayedContent()
            return item

        default:
            return nil
        }
    }

    private func makeNavigationButton(
        symbol: String,
        fallback: String,
        action: Selector,
        label: String
    ) -> NSButton {
        let button: NSButton
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) {
            button = NSButton(image: image, target: self, action: action)
            button.imagePosition = .imageOnly
        } else {
            button = NSButton(title: fallback, target: self, action: action)
        }
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.focusRingType = .none
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 23).isActive = true
        button.toolTip = label
        return button
    }

    private func resetTurnContent() {
        transcriptText = ""
        answerText = ""
        answerLines = []
        reviewStartLine = nil
        statusMessage = nil
        isShowingGeneratedAnswer = false
    }

    private static func normalizedText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private var contentLineWidth: CGFloat {
        let laidOutWidth = contentLabel?.bounds.width ?? 0
        // AppKit briefly assigns a near-zero frame before its constraints run.
        let preferredWidth =
            usesCompactLayout
            ? Self.compactContentWidth : Self.preferredContentWidth
        let navigationWidth: CGFloat = shouldShowAnswerNavigation ? 54 : 0
        let availableWidth =
            laidOutWidth >= 35
            ? laidOutWidth : max(35, preferredWidth - navigationWidth)
        return max(1, availableWidth - Self.contentHorizontalInset)
    }

    private func contentWidthDidChange() {
        guard !answerText.isEmpty else {
            updateDisplayedContent()
            return
        }
        let oldLineCount = answerLines.count
        let oldReviewStart = reviewStartLine
        answerLines = Self.wrappedLines(answerText, width: contentLineWidth)
        if let oldReviewStart {
            // Preserve the user's reading position as closely as possible
            // when the system resizes the Touch Bar or its Control Strip.
            let distanceFromNewest = max(0, oldLineCount - 2 - oldReviewStart)
            reviewStartLine = max(0, newestAnswerStartLine - distanceFromNewest)
        }
        updateDisplayedContent()
    }

    private static func wrappedLines(_ text: String, width: CGFloat) -> [String] {
        var lines: [String] = []
        var currentLine = ""
        let attributes: [NSAttributedString.Key: Any] = [.font: contentFont]

        for character in text {
            if currentLine.isEmpty && character == " " { continue }
            let candidate = currentLine + String(character)
            if !currentLine.isEmpty,
                (candidate as NSString).size(withAttributes: attributes).width > width
            {
                lines.append(currentLine.trimmingCharacters(in: .whitespaces))
                currentLine = character == " " ? "" : String(character)
            } else {
                currentLine = candidate
            }
        }
        if !currentLine.isEmpty {
            lines.append(currentLine.trimmingCharacters(in: .whitespaces))
        }
        return lines
    }

    private static func compactStatus(_ status: String, fallback: String) -> String {
        let normalized = normalizedText(status)
        guard !normalized.isEmpty else { return fallback }
        return normalized.count > 42 ? String(normalized.prefix(41)) + "…" : normalized
    }

    private var newestAnswerStartLine: Int {
        max(0, answerLines.count - 2)
    }

    private var shouldShowAnswerNavigation: Bool {
        isLiveDisplaying && !isCapturePaused && isShowingGeneratedAnswer && statusMessage == nil
    }

    private func updateDisplayedContent() {
        updateRoleIndicator()
        updateNavigationButtons()

        let displayText: String
        if !isLiveDisplaying {
            displayText = "TouchBarChat"
        } else if isCapturePaused {
            displayText = L10n.text("已暂停")
        } else if let statusMessage {
            displayText = statusMessage
        } else if isShowingGeneratedAnswer {
            let start = reviewStartLine ?? newestAnswerStartLine
            displayText = answerLines.dropFirst(start).prefix(2).joined(separator: "\n")
        } else if !transcriptText.isEmpty {
            displayText = Self.wrappedLines(transcriptText, width: contentLineWidth)
                .suffix(2).joined(separator: "\n")
        } else {
            displayText = livePlaceholder
        }
        if contentLabel?.stringValue != displayText {
            contentLabel?.stringValue = displayText
        }
    }

    private func updateRoleIndicator() {
        let role: ContentRole = isShowingGeneratedAnswer ? .answer : .transcript
        let symbolName = role == .answer ? "sparkles" : "person.fill"
        let accessibilityLabel =
            role == .answer
            ? L10n.text("AI 回答") : L10n.text("电脑播放声音的转录")
        roleImageView?.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityLabel
        )
        roleImageView?.toolTip = accessibilityLabel
        roleTile?.setAccessibilityLabel(accessibilityLabel)
        if role == .answer {
            roleTile?.layer?.backgroundColor =
                NSColor(
                    calibratedRed: 56 / 255, green: 39 / 255, blue: 85 / 255, alpha: 1
                ).cgColor
            roleImageView?.contentTintColor = NSColor(
                calibratedRed: 218 / 255, green: 197 / 255, blue: 255 / 255, alpha: 1
            )
        } else {
            roleTile?.layer?.backgroundColor =
                NSColor(
                    calibratedRed: 22 / 255, green: 54 / 255, blue: 58 / 255, alpha: 1
                ).cgColor
            roleImageView?.contentTintColor = NSColor(
                calibratedRed: 154 / 255, green: 240 / 255, blue: 234 / 255, alpha: 1
            )
        }
    }

    private func updateNavigationButtons() {
        let showNavigation = shouldShowAnswerNavigation
        previousButton?.isHidden = !showNavigation
        nextButton?.isHidden = !showNavigation
        previousButton?.isEnabled =
            showNavigation
            && (reviewStartLine ?? newestAnswerStartLine) > 0
        nextButton?.isEnabled = showNavigation && reviewStartLine != nil
    }

    @objc private func previousPageAction() { previousPage() }
    @objc private func nextPageAction() { nextPage() }
}
