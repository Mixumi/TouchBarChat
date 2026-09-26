import AppKit

/// Presents an `NSTouchBar` independently of the frontmost app.
///
/// Apple does not publish this behavior in the AppKit SDK. Every selector is
/// resolved at runtime so an unsupported macOS release fails closed instead of
/// crashing the app.
@MainActor
enum SystemModalTouchBar {
    private static let touchBarPresentSelector = NSSelectorFromString(
        "presentSystemModalTouchBar:systemTrayItemIdentifier:"
    )
    private static let touchBarDismissSelector = NSSelectorFromString(
        "dismissSystemModalTouchBar:"
    )
    private static let touchBarMinimizeSelector = NSSelectorFromString(
        "minimizeSystemModalTouchBar:"
    )

    // Older macOS versions used "FunctionBar" in the private selector names.
    private static let functionBarPresentSelector = NSSelectorFromString(
        "presentSystemModalFunctionBar:systemTrayItemIdentifier:"
    )
    private static let functionBarDismissSelector = NSSelectorFromString(
        "dismissSystemModalFunctionBar:"
    )

    private static var touchBarClass: AnyObject {
        NSTouchBar.self as AnyObject
    }

    static var isSupported: Bool {
        touchBarClass.responds(to: touchBarPresentSelector)
            || touchBarClass.responds(to: functionBarPresentSelector)
    }

    @discardableResult
    static func present(_ touchBar: NSTouchBar) -> Bool {
        if touchBarClass.responds(to: touchBarPresentSelector) {
            _ = touchBarClass.perform(
                touchBarPresentSelector,
                with: touchBar,
                with: nil
            )
            return true
        }

        if touchBarClass.responds(to: functionBarPresentSelector) {
            _ = touchBarClass.perform(
                functionBarPresentSelector,
                with: touchBar,
                with: nil
            )
            return true
        }

        return false
    }

    static func dismiss(_ touchBar: NSTouchBar) {
        if touchBarClass.responds(to: touchBarDismissSelector) {
            _ = touchBarClass.perform(touchBarDismissSelector, with: touchBar)
        } else if touchBarClass.responds(to: functionBarDismissSelector) {
            _ = touchBarClass.perform(functionBarDismissSelector, with: touchBar)
        }
    }

    static func minimize(_ touchBar: NSTouchBar) {
        guard touchBarClass.responds(to: touchBarMinimizeSelector) else { return }
        _ = touchBarClass.perform(touchBarMinimizeSelector, with: touchBar)
    }

    static func printProbe() {
        let probes = [
            "presentSystemModalTouchBar:systemTrayItemIdentifier:",
            "dismissSystemModalTouchBar:",
            "minimizeSystemModalTouchBar:",
            "presentSystemModalFunctionBar:systemTrayItemIdentifier:",
            "dismissSystemModalFunctionBar:",
        ]

        for name in probes {
            let available = touchBarClass.responds(to: NSSelectorFromString(name))
            print("\(name)\t\(available)")
        }
    }
}
