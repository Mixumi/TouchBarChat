import Carbon
import Foundation

/// Global page controls are registered only while an interview is active.
/// Carbon hot keys do not require Accessibility or Input Monitoring permission.
@MainActor
final class GlobalPageHotkeys {
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?

    private static let signature: OSType = 0x5442_4348  // "TBCH"
    private static let previousID: UInt32 = 1
    private static let nextID: UInt32 = 2

    private var eventHandler: EventHandlerRef?
    private var previousHotKey: EventHotKeyRef?
    private var nextHotKey: EventHotKeyRef?

    var isActive: Bool {
        previousHotKey != nil && nextHotKey != nil && eventHandler != nil
    }

    func start() {
        guard !isActive else { return }
        stop()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else {
                    return OSStatus(eventNotHandledErr)
                }

                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr,
                    hotKeyID.signature == GlobalPageHotkeys.signature
                else {
                    return OSStatus(eventNotHandledErr)
                }

                let controller = Unmanaged<GlobalPageHotkeys>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                let pressedID = hotKeyID.id
                Task { @MainActor in
                    controller.handle(pressedID)
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard handlerStatus == noErr else {
            stop()
            return
        }

        let modifiers = UInt32(controlKey | optionKey)
        let previousStatus = RegisterEventHotKey(
            UInt32(kVK_LeftArrow),
            modifiers,
            EventHotKeyID(signature: Self.signature, id: Self.previousID),
            GetApplicationEventTarget(),
            0,
            &previousHotKey
        )
        let nextStatus = RegisterEventHotKey(
            UInt32(kVK_RightArrow),
            modifiers,
            EventHotKeyID(signature: Self.signature, id: Self.nextID),
            GetApplicationEventTarget(),
            0,
            &nextHotKey
        )
        guard previousStatus == noErr, nextStatus == noErr else {
            stop()
            return
        }
    }

    func stop() {
        if let previousHotKey {
            UnregisterEventHotKey(previousHotKey)
            self.previousHotKey = nil
        }
        if let nextHotKey {
            UnregisterEventHotKey(nextHotKey)
            self.nextHotKey = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private func handle(_ pressedID: UInt32) {
        guard isActive else { return }
        switch pressedID {
        case Self.previousID:
            onPrevious?()
        case Self.nextID:
            onNext?()
        default:
            break
        }
    }
}
