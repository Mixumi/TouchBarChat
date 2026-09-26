import AVFoundation
import Foundation

/// Selects Apple's newer, long-form on-device transcription when the device
/// and selected locale support it. The older SFSpeechRecognizer is a local-only
/// compatibility path; a failure after choosing the new engine never silently
/// switches engines or sends audio to a speech service.
@MainActor
final class LocalSpeechTranscriber {
    var onTranscription: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?
    var onStopped: ((Bool) -> Void)?

    private enum Engine { case none, modern, legacy }
    private let locale: Locale
    private let legacy: LiveSpeechTranscriber
    private var engine: Engine = .none
    private var isStarting = false
    private var generation: UInt64 = 0
    private var modernStorage: AnyObject?
    @available(macOS 26.0, *)
    private var modern: ModernSpeechTranscriber? {
        get { modernStorage as? ModernSpeechTranscriber }
        set { modernStorage = newValue }
    }

    init(locale: Locale = Locale(identifier: "zh-CN")) {
        self.locale = locale
        legacy = LiveSpeechTranscriber(locale: locale)
        legacy.onTranscription = { [weak self] text, isFinal in
            self?.onTranscription?(text, isFinal)
        }
        legacy.onError = { [weak self] error in
            self?.onError?(error)
        }
        legacy.onStopped = { [weak self] timedOut in
            guard let self else { return }
            self.engine = .none
            self.onStopped?(timedOut)
        }
    }

    var isRunning: Bool {
        switch engine {
        case .none: return false
        case .legacy: return legacy.isRunning
        case .modern:
            if #available(macOS 26.0, *) { return modern?.isRunning == true }
            return false
        }
    }

    var usesOnDeviceRecognition: Bool {
        switch engine {
        case .none: return false
        case .legacy: return legacy.usesOnDeviceRecognition
        case .modern: return true
        }
    }

    var usesModernRecognition: Bool {
        if case .modern = engine { return true }
        return false
    }

    static func canUseModernLocalRecognition(locale: Locale = Locale(identifier: "zh-CN")) async -> Bool {
        if #available(macOS 26.0, *) {
            return await ModernSpeechTranscriber.supports(locale)
        }
        return false
    }

    func start() async throws {
        guard !isStarting, !isRunning else {
            throw LiveSpeechTranscriberError.alreadyRunning
        }
        // A preceding fatal recognition error may have ended an engine without
        // its normal onStopped callback; do not retain that stale session.
        cancelSelectedEngine()
        isStarting = true
        let startGeneration = generation
        defer { isStarting = false }

        if #available(macOS 26.0, *), await ModernSpeechTranscriber.supports(locale) {
            guard startGeneration == generation, !Task.isCancelled else {
                throw LiveSpeechTranscriberError.cancelled
            }
            let selected = ModernSpeechTranscriber(locale: locale)
            selected.onTranscription = { [weak self] text, isFinal in
                self?.onTranscription?(text, isFinal)
            }
            selected.onError = { [weak self] error in
                self?.onError?(error)
            }
            selected.onStopped = { [weak self] timedOut in
                guard let self else { return }
                self.engine = .none
                self.modern = nil
                self.onStopped?(timedOut)
            }
            modern = selected
            engine = .modern
            do {
                try await selected.start()
            } catch {
                if startGeneration == generation {
                    selected.cancel()
                    modern = nil
                    engine = .none
                }
                throw error
            }
        } else {
            guard startGeneration == generation, !Task.isCancelled else {
                throw LiveSpeechTranscriberError.cancelled
            }
            engine = .legacy
            do {
                try await legacy.start()
            } catch {
                if startGeneration == generation {
                    legacy.cancel()
                    engine = .none
                }
                throw error
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        switch engine {
        case .none: break
        case .legacy: legacy.append(buffer)
        case .modern:
            if #available(macOS 26.0, *) { modern?.append(buffer) }
        }
    }

    func rolloverIfQuiet(silenceDuration: TimeInterval) {
        if case .legacy = engine {
            legacy.rolloverIfQuiet(silenceDuration: silenceDuration)
        }
    }

    func stop() {
        switch engine {
        case .none: break
        case .legacy: legacy.stop()
        case .modern:
            if #available(macOS 26.0, *) { modern?.stop() }
        }
    }

    func cancel() {
        generation &+= 1
        cancelSelectedEngine()
    }

    private func cancelSelectedEngine() {
        switch engine {
        case .none: break
        case .legacy: legacy.cancel()
        case .modern:
            if #available(macOS 26.0, *) {
                modern?.cancel()
                modern = nil
            }
        }
        engine = .none
    }
}
