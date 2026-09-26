import AppKit
import SwiftUI

/// A selectable, read-only Markdown document that grows with its content.
/// The enclosing SwiftUI ScrollView owns scrolling; this view has none of its own.
struct MarkdownDocumentPreview: NSViewRepresentable {
    let markdown: String

    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        return textView
    }

    func updateNSView(_ textView: NSTextView, context: Context) {
        guard
            context.coordinator.markdown != markdown
                || context.coordinator.colorScheme != colorScheme
        else { return }

        let rendered = Self.render(markdown)
        textView.textStorage?.setAttributedString(rendered)
        textView.invalidateIntrinsicContentSize()
        context.coordinator.markdown = markdown
        context.coordinator.colorScheme = colorScheme
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView textView: NSTextView,
        context: Context
    ) -> CGSize? {
        let width = max(1, proposal.width ?? textView.bounds.width)
        textView.frame.size.width = width
        guard let container = textView.textContainer,
            let layoutManager = textView.layoutManager
        else {
            return CGSize(width: width, height: 1)
        }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let height = ceil(
            layoutManager.usedRect(for: container).maxY
                + textView.textContainerInset.height * 2)
        return CGSize(width: width, height: max(1, height))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var markdown: String?
        var colorScheme: ColorScheme?
    }

    // Foundation keeps block structure as presentation intents, but the raw
    // attributed string has no paragraph separators or fonts. NSTextView's
    // TextKit 1 layout otherwise places an entire document on one line.
    static func render(_ source: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .full,
            failurePolicy: .throwError
        )
        guard let parsed = try? NSAttributedString(markdown: source, options: options) else {
            return NSAttributedString(
                string: source,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 16),
                    .foregroundColor: NSColor.labelColor,
                ]
            )
        }

        let result = NSMutableAttributedString(string: "")
        let wholeRange = NSRange(location: 0, length: parsed.length)
        var previous: BlockStyle?
        parsed.enumerateAttribute(presentationIntentKey, in: wholeRange) { value, range, _ in
            let intent = value as? PresentationIntent
            let style = BlockStyle(intent: intent)
            let block = NSMutableAttributedString(attributedString: parsed.attributedSubstring(from: range))
            style.apply(to: block)

            if let previous {
                result.append(NSAttributedString(string: style.separator(after: previous)))
            }
            if !style.prefix.isEmpty {
                result.append(
                    NSAttributedString(
                        string: style.prefix,
                        attributes: [
                            .font: style.font,
                            .foregroundColor: NSColor.labelColor,
                            .paragraphStyle: style.paragraphStyle,
                        ]
                    ))
            }
            result.append(block)
            previous = style
        }
        return result
    }

    private static let presentationIntentKey = NSAttributedString.Key("NSPresentationIntent")
    private static let inlineIntentKey = NSAttributedString.Key("NSInlinePresentationIntent")

    @MainActor private struct BlockStyle {
        enum Kind: Equatable {
            case paragraph
            case heading(Int)
            case listItem(listID: Int, ordered: Bool, ordinal: Int, depth: Int)
            case quote
            case code
            case tableCell(rowID: Int, header: Bool)
            case thematicBreak
        }

        let kind: Kind

        init(intent: PresentationIntent?) {
            let components = intent?.components ?? []
            var resolved: Kind = .paragraph
            var listItem: (ordinal: Int, depth: Int)?
            var list: (id: Int, ordered: Bool)?
            var tableRow: (id: Int, header: Bool)?
            var isTableCell = false

            for component in components {
                switch component.kind {
                case .header(let level):
                    resolved = .heading(level)
                case .codeBlock:
                    resolved = .code
                case .blockQuote:
                    resolved = .quote
                case .thematicBreak:
                    resolved = .thematicBreak
                case .listItem(let ordinal):
                    listItem = (
                        ordinal,
                        components.filter {
                            if case .listItem = $0.kind { return true }
                            return false
                        }.count
                    )
                case .orderedList:
                    list = (component.identity, true)
                case .unorderedList:
                    list = (component.identity, false)
                case .tableCell:
                    isTableCell = true
                case .tableHeaderRow:
                    tableRow = (component.identity, true)
                case .tableRow:
                    tableRow = (component.identity, false)
                default:
                    break
                }
            }

            if let listItem, let list {
                resolved = .listItem(
                    listID: list.id,
                    ordered: list.ordered,
                    ordinal: listItem.ordinal,
                    depth: listItem.depth
                )
            } else if isTableCell, let tableRow {
                resolved = .tableCell(rowID: tableRow.id, header: tableRow.header)
            }
            kind = resolved
        }

        var font: NSFont {
            switch kind {
            case .heading(let level):
                return NSFont.systemFont(
                    ofSize: [24, 21, 18, 16, 15, 14][min(max(level, 1), 6) - 1],
                    weight: .semibold
                )
            case .code:
                return NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
            case .tableCell(_, true):
                return NSFont.systemFont(ofSize: 16, weight: .semibold)
            default:
                return NSFont.systemFont(ofSize: 16)
            }
        }

        var prefix: String {
            switch kind {
            case .listItem(_, let ordered, let ordinal, _):
                return ordered ? "\(ordinal). " : "• "
            case .quote:
                return "│ "
            default:
                return ""
            }
        }

        var paragraphStyle: NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 5
            switch kind {
            case .listItem(_, _, _, let depth):
                style.firstLineHeadIndent = CGFloat(max(0, depth - 1) * 18)
                style.headIndent = style.firstLineHeadIndent + 20
            case .quote:
                style.headIndent = 16
            case .code:
                style.firstLineHeadIndent = 8
                style.headIndent = 8
            default:
                break
            }
            return style
        }

        func separator(after previous: BlockStyle) -> String {
            switch (previous.kind, kind) {
            case (.tableCell(let previousRow, _), .tableCell(let row, _)):
                return previousRow == row ? "  |  " : "\n"
            case (.listItem(let previousList, _, _, _), .listItem(let list, _, _, _))
            where previousList == list:
                return "\n"
            default:
                return "\n\n"
            }
        }

        func apply(to block: NSMutableAttributedString) {
            guard block.length > 0 else { return }
            let wholeRange = NSRange(location: 0, length: block.length)
            var inlineRuns: [(NSRange, InlinePresentationIntent)] = []
            var linkRuns: [NSRange] = []
            block.enumerateAttribute(MarkdownDocumentPreview.inlineIntentKey, in: wholeRange) {
                value, range, _ in
                if let number = value as? NSNumber {
                    inlineRuns.append((range, InlinePresentationIntent(rawValue: number.uintValue)))
                }
            }
            block.enumerateAttribute(.link, in: wholeRange) { value, range, _ in
                if value != nil { linkRuns.append(range) }
            }

            block.removeAttribute(MarkdownDocumentPreview.presentationIntentKey, range: wholeRange)
            block.removeAttribute(MarkdownDocumentPreview.inlineIntentKey, range: wholeRange)
            block.addAttributes(
                [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraphStyle,
                ],
                range: wholeRange
            )
            if case .code = kind {
                block.addAttribute(.backgroundColor, value: NSColor.controlBackgroundColor, range: wholeRange)
            }
            for (range, intent) in inlineRuns {
                var styledFont = font
                if intent.contains(.code) {
                    styledFont = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
                } else if intent.contains(.stronglyEmphasized) {
                    styledFont = NSFont.systemFont(ofSize: font.pointSize, weight: .bold)
                }
                if intent.contains(.emphasized) {
                    styledFont = NSFontManager.shared.convert(styledFont, toHaveTrait: .italicFontMask)
                }
                block.addAttribute(.font, value: styledFont, range: range)
                if intent.contains(.strikethrough) {
                    block.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                }
            }
            for range in linkRuns {
                block.addAttribute(.foregroundColor, value: NSColor.linkColor, range: range)
            }
        }
    }
}
