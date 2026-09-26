import AppKit
import Darwin

if CommandLine.arguments.contains("--speech-self-test") {
    // Run under the existing signed app identity, but without creating the
    // normal UI, interview store, capture stream, or settings controller.
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    Task { @MainActor in
        exit(await SpeechSelfTest.run())
    }
    application.run()
    exit(EXIT_FAILURE)
} else if CommandLine.arguments.contains("--probe") {
    SystemModalTouchBar.printProbe()
    exit(SystemModalTouchBar.isSupported ? EXIT_SUCCESS : EXIT_FAILURE)
}

let application = NSApplication.shared
let applicationDelegate = TouchBarChatAppDelegate()

application.setActivationPolicy(.regular)
application.delegate = applicationDelegate
application.run()
