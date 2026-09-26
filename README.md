# TouchBarChat

[简体中文](README.zh-CN.md)

TouchBarChat is an open-source macOS app for interview transcription and optional real-time AI answer suggestions. It captures **audio played by your Mac**, transcribes it with Apple's on-device speech APIs, and shows the current transcript or a suggested answer on a Touch Bar. The main window keeps a text record for later review, editing, and Markdown export. A Touch Bar is optional.

> **Use responsibly.** Only capture a conversation when its participants have been informed and the interview, meeting, or platform rules permit recording or AI assistance. TouchBarChat does not identify speakers or determine whether a particular use is permitted. It is not designed to evade disclosure, monitoring, or interview rules.

## What it does

- Streams the Mac's playback audio into Apple local speech recognition. It does **not** capture your microphone, read screen pixels, or save audio/video.
- Shows rolling two-line transcript and answer views on the Touch Bar. During an AI answer, discreet previous/next controls and `Control + Option + ←/→` let you review lines without losing incoming text.
- Uses local sound activity, Apple SoundAnalysis, transcript stability, and question heuristics to decide when to request an answer. The menu-bar action **Generate answer now** is available if automatic detection waits too long.
- Sends a recognized question to a user-configured Chat Completions-compatible endpoint only when AI answers are enabled. Responses stream to the display and the local record.
- Saves text as an interview progresses. After the interview, you can edit the Markdown document, restore the generated version, delete a record, or export a `.md` file.
- Provides a first-run guide, permission checks, a menu-bar controller, and light/dark/system appearance settings. Without an API configuration, transcription and local records still work.

For the turn-taking state machine and its edge cases, see [Interview flow design](Docs/InterviewFlowDesign.md) and [runtime notes](Docs/InterviewRuntime.md).

## Requirements and compatibility

| Item | Requirement or status |
| --- | --- |
| Operating system | macOS 13 or later is the package minimum. Development and automated tests have run on macOS 26.7; this does not prove the packaged app on macOS 13–25 or other hardware. Those combinations need independent runtime testing. |
| Build tools | Xcode or Apple Command Line Tools with a Swift 6-capable toolchain. |
| Speech | The selected locale must support Apple's **on-device** speech recognition on that Mac. macOS 26 prefers SpeechAnalyzer/SpeechTranscriber; earlier or unsupported configurations use local-only SFSpeechRecognizer. A model may need to be downloaded. No cloud-speech fallback is enabled. |
| Touch Bar | Optional. The app still records and displays interviews in its main window without one. Touch Bar presentation uses an undocumented AppKit interface and may stop working on future macOS releases. |
| AI answers | Optional network access to your own compatible API. The provider, its availability, charges, retention, and output quality are outside this project. |

### Languages

The app has interface translation resources for Simplified Chinese, English, Korean, Japanese, Russian, French, and Brazilian Portuguese. In **Settings → Languages**, the interface can follow the Mac's preferred language or use any of those seven languages explicitly. Untranslated strings may fall back to Simplified Chinese while localization is being completed.

The **interviewer language** and **AI answer language** are separate settings. The interviewer-language choices are `zh-CN`, `en-US`, `ko-KR`, `ja-JP`, `ru-RU`, `fr-FR`, and `pt-BR`. The AI answer can follow that language or use a different one. The app checks local speech availability for the selected interviewer language before capture; listing a locale is **not** a claim that its Apple model is installed or has been tested on every Mac. AI response language is a request to your configured model, not a guarantee about its output.

| Layer | Language behavior |
| --- | --- |
| Interface | Seven bundled localizations; follows macOS by default or uses a language selected in Settings, with a Chinese fallback for missing strings. |
| Transcription | Uses the chosen interviewer locale only if Apple's on-device recognizer supports it on the current Mac. Never silently sends audio to a remote recognizer. |
| AI answer | Uses the chosen answer language, or follows the interviewer language by default, if an API is configured. |
| Saved document | Keeps labels associated with the interview language, so later interface-language changes do not relabel an existing record. |

## Build and run

From the repository root:

```bash
./Scripts/check.sh
./Scripts/build-app.sh
open Build/TouchBarChat.app
```

The check script runs strict Swift formatting lint and the test suite. These checks do not validate every speech locale or real Touch Bar hardware.

The build script creates `Build/TouchBarChat.app` with **ad-hoc signing by default**. It does not inspect or select your private signing identities automatically. To use an Apple Development identity explicitly:

```bash
TOUCHBARCHAT_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./Scripts/build-app.sh
```

The value above is a **placeholder**, not a project credential. Do not commit certificates, provisioning profiles, API keys, transcripts, or locally signed build products. The default ad-hoc signature may require macOS privacy permissions to be granted again after rebuilding; using a stable app path and explicit Development identity can help during local testing. The bundle identifier is `dev.touchbarchat.app`.

## Set up and use

1. Launch the app and follow **Permissions → AI connection → Answer preferences → Welcome**. Choose the language spoken by the interviewer. Allow **Screen & System Audio Recording**. Older local-speech configurations may also request **Speech Recognition** permission; macOS 26's supported SpeechTranscriber path does not use that permission.
2. Optionally enter your provider's **complete Chat Completions endpoint URL**, exact model name, API key, and personal background. Remote endpoints must use HTTPS; HTTP is accepted only for a loopback address. A remote endpoint requires a key, while a loopback endpoint may omit it. You may skip the API steps and use transcription-only mode.
3. Press the start icon in the main window. The app checks permissions, speech support, and any partially configured API settings before starting. Once capture begins, it minimizes its main window and adds a menu-bar control.
4. Use the menu-bar control to pause, resume, end, manually request the current answer, or reopen the window. During capture, the record is read-only. End the interview before editing or exporting the Markdown record.

The Touch Bar's person icon indicates **transcription**; the sparkles icon indicates an **AI answer**. Text is shown in a rolling two-line window rather than revealed one character at a time. Previous/next navigation applies to the answer view, not the live transcript.

## Privacy and data flow

| Data | Where it goes |
| --- | --- |
| Playback audio | Captured via ScreenCaptureKit and processed on this Mac by Apple speech and sound-analysis frameworks. No microphone input is requested. The app attaches only an audio output to its capture stream, not a video output. Audio is not saved by TouchBarChat or sent to the configured AI API. Apple's first-use local model download may require network access. |
| Interview text | Stored by default in `~/Library/Application Support/TouchBarChat/interviews.json`. This is a **local, unencrypted text record**, not a secret vault. The app does not automatically upload the record to GitHub. Exported Markdown is saved wherever you choose. |
| API settings | The API key is stored in macOS Keychain. The endpoint, model, and personal background are kept in the app's local user preferences. They are not embedded in source code. |
| AI request | When enabled, the selected endpoint receives the current question, personal background, and up to three recent question/answer drafts as text. The endpoint also receives the API key as a Bearer credential when one is configured. The provider may retain or process this data under its own terms. |

Review your interview rules and your API provider's privacy policy before enabling capture or AI answers. Keep private records and settings out of screenshots, bug reports, commits, and pull requests.

## Advantages and limitations

The design favors Apple's local transcription, text-only storage, a usable no-API mode, and an answer display that does not require switching windows. A Touch Bar is helpful but not required.

It has important limits:

- It listens to **all eligible playback audio**, which can include meeting participants, videos, music, and notifications. It cannot tell which voice is the interviewer; it does not transcribe your microphone.
- Local recognition quality and language availability depend on Apple models, audio quality, device, and OS version. Partial transcripts can be revised or omit words.
- End-of-question and interruption decisions are heuristics, not speaker identification or a guarantee of correct timing. Apple's SpeechDetector is currently not used as an endpoint signal; [the rationale and test result](Docs/InterviewFlowDesign.md#参考与取舍) are documented separately.
- AI answers can be late, wrong, incomplete, or inconsistent with your actual experience. They are suggestions for review, not verified facts.
- The Touch Bar integration depends on an undocumented AppKit selector, so compatibility is uncertain and this approach is not suitable for Mac App Store distribution. No notarized release is provided here.
- The local record is not encrypted, and enabling AI sends text to the provider you selected.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| App missing from Screen & System Audio Recording | Use the permission action in the app, then open the macOS privacy pane. If macOS asks for a restart, quit and reopen the same signed app. Do not replace the app with a differently signed build while testing permissions. |
| “Recognizing” but no text | Verify that speech is actually **playing on this Mac**, not only spoken into its microphone. Check the selected interviewer language and local speech-model availability. |
| Incomplete or delayed text | Check the meeting app's playback level and selected language. Partial results may change; final speech results can arrive later. Preserve a short, non-private example when reporting a bug. |
| No AI answer | Check that the API configuration is complete, the endpoint is the full Chat Completions URL, and the provider accepts the selected model. Try the menu-bar manual-answer action if automatic turn detection waits. |
| No Touch Bar text | The Mac must have a functioning Touch Bar and the current macOS must still expose the required private interface. The main-window record remains the fallback. Run `swift run TouchBarChat --probe` to inspect selector availability; it does not run an interview. |
| Permission is lost after rebuilding | Keep a stable bundle ID, app path, and signing identity. Ad-hoc signatures may not retain TCC grants across builds. |

## Development and contributing

Run `./Scripts/check.sh` from the repository root for strict format lint and tests. Tests cover settings validation, text persistence, turn boundaries, AI response parsing, and Touch Bar paging; they do not replace real-device checks of each speech locale or a consenting, non-private capture scenario. Follow [CONTRIBUTING.md](CONTRIBUTING.md) for style, safety, and pull-request guidance. See [third-party notices](THIRD_PARTY_NOTICES.md) for design references; the package currently links no third-party library.

## License

[MIT](LICENSE).
