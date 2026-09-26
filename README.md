<div align="center">

<sub>MACOS · ON-DEVICE SPEECH · OPTIONAL AI</sub>

# TouchBarChat

### Hear the question. Keep the answer in view.

An open-source interview companion that transcribes **audio playing on your Mac** locally, streams optional AI answer suggestions, and keeps the conversation in a Markdown-friendly record.

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-1c1c22?logo=apple&logoColor=white)](#requirements)
[![Swift 6](https://img.shields.io/badge/Swift-6-f05138?logo=swift&logoColor=white)](#build-from-source)
[![On-device speech](https://img.shields.io/badge/speech-on--device-6f42c1)](#how-it-works)
[![MIT License](https://img.shields.io/badge/license-MIT-2ea44f)](LICENSE)

[Explore the experience](#the-experience) · [How it works](#how-it-works) · [Build](#build-from-source) · [简体中文](README.zh-CN.md)

</div>

![Illustrative Touch Bar states for live Mac-playback transcription and optional AI answers](Docs/assets/touchbar-flow.svg)

<p align="center"><sub>Enlarged illustration with fictional text, not a device screenshot. The transcript and answer states appear one at a time.</sub></p>

The person icon marks the **live transcript**; sparkles mark an **AI answer**. Both stream in a rolling two-line window—not a character-by-character animation. Subtle previous/next controls or `Control + Option + ←/→` let you reread an answer without dropping incoming text. The transcript has no paging.

## The experience

| 01 · TRANSCRIBE | 02 · SUGGEST | 03 · REVIEW |
| :--- | :--- | :--- |
| Apple on-device speech turns **Mac playback** into a live transcript. No microphone or saved audio. | A configured API streams a suggested answer to a two-line Touch Bar view. It can be skipped entirely. | A local text record preserves the exchange; after the interview, edit, restore, delete, or export Markdown. |

### Main window and records

![Illustrative TouchBarChat interface with synthetic interview content](Docs/assets/touchbarchat-overview.svg)

<p align="center"><sub>Illustrative preview with sample data; not an unedited app screenshot.</sub></p>

**No Touch Bar?** The main-window record still works. **No API?** Transcription and local notes still work. During capture, the record stays read-only.

> [!IMPORTANT]
> Capture conversations only when participants have been informed and the interview, meeting, or platform rules allow recording and AI assistance. TouchBarChat cannot identify speakers or decide whether a particular use is permitted. It is not designed to evade disclosure, monitoring, or interview rules.

## How it works

`Mac playback → ScreenCaptureKit → Apple local speech → turn detection → optional AI → Touch Bar + local record`

1. **Capture audio only.** ScreenCaptureKit reads the Mac's playback. A display anchors its capture filter, but no video output is attached; microphone input and audio/video files are not used.
2. **Recognize on-device.** On supported macOS 26 configurations, SpeechAnalyzer/SpeechTranscriber is preferred. Otherwise, `SFSpeechRecognizer` runs only when it supports on-device recognition. There is no silent cloud-speech fallback.
3. **Decide when to answer.** Local sound activity, Apple SoundAnalysis, transcript stability, and question heuristics help find the end of a turn. This is a timing heuristic, not speaker identification; the menu bar also offers **Generate answer now**.
4. **Stream and save.** If configured, a Chat Completions-compatible endpoint receives text context and streams a suggestion. Transcript and answer updates reach the display and local record as they arrive. See the [turn-taking design](Docs/InterviewFlowDesign.md) and [runtime pipeline](Docs/InterviewRuntime.md) for interruptions, late answers, and partial responses.

<details>
<summary>Source map for contributors</summary>

| Concern | Entry point |
| --- | --- |
| System playback capture | [`SystemAudioCapture.swift`](Sources/TouchBarChat/SystemAudioCapture.swift) |
| Local speech engine selection | [`LocalSpeechTranscriber.swift`](Sources/TouchBarChat/LocalSpeechTranscriber.swift) |
| Turn and interruption rules | [`InterviewQuestionEndPolicy.swift`](Sources/TouchBarChat/InterviewQuestionEndPolicy.swift), [`InterviewInterruptionPolicy.swift`](Sources/TouchBarChat/InterviewInterruptionPolicy.swift) |
| Streaming AI client | [`AIAnswerClient.swift`](Sources/TouchBarChat/AIAnswerClient.swift) |
| Touch Bar and main window | [`TouchBarController.swift`](Sources/TouchBarChat/TouchBarController.swift), [`AppUIController.swift`](Sources/TouchBarChat/AppUIController.swift) |
| Local text record | [`InterviewStore.swift`](Sources/TouchBarChat/InterviewStore.swift) |

</details>

## Languages

The interface has Simplified Chinese, English, Korean, Japanese, Russian, French, and Brazilian Portuguese resources. In **Settings → Languages**, it can follow macOS or use one of those seven languages explicitly. A missing translation may still fall back to Simplified Chinese.

Transcription and answer language are separate settings:

| Layer | Behavior |
| --- | --- |
| Interface | Follows macOS by default; can be overridden in Settings. |
| Interviewer transcription | `zh-CN`, `en-US`, `ko-KR`, `ja-JP`, `ru-RU`, `fr-FR`, or `pt-BR`, **only if** Apple's on-device recognizer supports the selected locale on this Mac. |
| AI answer | Follows the interviewer language by default, or requests a separately selected language from your model. The model may not always comply. |
| Saved record | Keeps its interview-language labels, so changing the interface language does not relabel an earlier document. |

A language appearing in Settings does **not** mean its Apple model is installed, available on every Mac, or validated with real meeting audio. The app checks local speech support before capture; an unavailable locale fails visibly instead of sending audio to a remote recognizer.

## Requirements

| Component | Requirement / status |
| --- | --- |
| macOS | Package minimum: **13**. Development and automated tests have run on macOS **26.7**. The packaged app still needs independent runtime testing on macOS 13–25 and other hardware. |
| Build tools | Xcode or Apple Command Line Tools with a Swift 6-capable toolchain. |
| Speech models | The chosen language needs Apple on-device recognition on the current Mac. A model may need to be downloaded on first use. |
| Touch Bar | Optional. Presentation uses an **undocumented AppKit interface**, which may stop working in a future macOS release; the main-window record remains usable. |
| AI | Optional network access to your own Chat Completions-compatible endpoint. Provider fees, availability, retention, and output quality are outside this project. |

## Quick start

### Build from source

From the repository root:

```bash
./Scripts/check.sh
./Scripts/build-app.sh
open Build/TouchBarChat.app
```

`check.sh` runs strict Swift format lint and the test suite. These checks do not validate every speech locale or real Touch Bar hardware. `build-app.sh` creates `Build/TouchBarChat.app` with **ad-hoc signing by default**; it does not inspect or select your private signing identities. For a stable local development identity, opt in explicitly:

```bash
TOUCHBARCHAT_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./Scripts/build-app.sh
```

The identity shown is a placeholder, not a project credential. Keep the app path, bundle identifier (`dev.touchbarchat.app`), and signing identity stable while testing macOS privacy permissions; an ad-hoc rebuild may require permission again. Do not commit certificates, provisioning profiles, keys, transcripts, or signed build products.

### First run

1. Follow **Permissions → AI connection → Answer preferences → Welcome**. Select the interviewer's language and allow **Screen & System Audio Recording**. The older `SFSpeechRecognizer` path may also request **Speech Recognition** permission; a supported macOS 26 SpeechTranscriber path does not use it.
2. Optionally provide a **complete Chat Completions endpoint URL**, exact model name, API key, and personal background. Remote URLs must use HTTPS; HTTP is allowed only for loopback. A remote endpoint requires a key; a loopback endpoint may omit one. Skip these steps for transcription-only mode.
3. Press the start icon in the main window. The app checks permissions, local speech availability, and any partially configured API settings, then begins capture, minimizes the main window, and adds a menu-bar control.
4. Use that control to **pause**, **resume**, **end**, **generate the current answer manually**, or **reopen the window**. Edit, delete, or export the Markdown record after ending the interview.

## Privacy and data flow

| Data | Destination |
| --- | --- |
| Playback audio | Processed on this Mac by ScreenCaptureKit and Apple speech/sound-analysis frameworks. TouchBarChat does not save it or send it to the configured AI API. Apple's first-use local model download may require a network connection. |
| Interview text | Stored by default in `~/Library/Application Support/TouchBarChat/interviews.json`. This is a **local, unencrypted text file**, not a secret vault; exported Markdown goes wherever you choose. Records are not automatically uploaded to GitHub. |
| API configuration | The API key is in macOS Keychain. Endpoint, model name, and personal background are in local user preferences, not in source code. |
| Optional AI request | Your selected endpoint receives the current question, personal background, and up to three recent question/answer drafts as text, plus a Bearer credential when configured. The provider may retain or process that data under its own terms. |

Review your interview rules and your API provider's privacy policy before use. Remove names, keys, and real interview content from screenshots, logs, issues, and pull requests.

## Known limits

- Capture includes **eligible Mac playback**, which may include meeting participants, videos, music, or notifications. It cannot determine who is speaking and does not capture what you say into the microphone.
- Recognition quality and locale availability depend on Apple's models, the Mac, OS version, and audio quality. Partial transcripts may change; final results may arrive late or omit words.
- Turn-end and interruption decisions are heuristic. `SpeechDetector` is not currently used as an endpoint signal; the [design notes](Docs/InterviewFlowDesign.md#参考与取舍) explain the rationale and test result.
- AI output can be late, incorrect, incomplete, or inconsistent with your real experience. Treat it as a suggestion, not a verified fact.
- The Touch Bar path relies on an undocumented AppKit selector, is unsuitable for Mac App Store distribution in its current form, and has no notarized release here.
- Local records are unencrypted. Enabling AI sends **text** to the provider you choose.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| App is missing from Screen & System Audio Recording | Request permission in the app, open macOS privacy settings, and restart the **same signed app** if asked. Avoid replacing it with a differently signed build during testing. |
| “Recognizing” but no text | Confirm speech is playing **on this Mac**, not only spoken into its microphone. Check the selected interviewer language and local model availability. |
| Incomplete or delayed transcript | Check meeting playback level, audio quality, and selected language. Partial results can be revised and final results can arrive later. Use only a short, non-private sample in bug reports. |
| No AI suggestion | Verify the full Chat Completions URL, exact model, and complete API configuration. Try the menu-bar manual-answer action if automatic turn detection waits. |
| No Touch Bar content | Verify hardware and macOS interface support. The main-window record is the fallback. `swift run TouchBarChat --probe` checks selector availability without starting an interview. |
| Privacy permission is lost after rebuilding | Use a stable app path, bundle ID, and signing identity; ad-hoc signatures may not retain TCC grants. |

## Contributing

`./Scripts/check.sh` covers formatting and automated tests for settings validation, text persistence, turn boundaries, AI streaming, and Touch Bar paging. It is **not** a substitute for consenting, non-private real-device tests of each locale or Touch Bar hardware. See [CONTRIBUTING.md](CONTRIBUTING.md) for style and safety guidance, and [third-party notices](THIRD_PARTY_NOTICES.md) for design references. The package currently links no third-party library.

Licensed under [MIT](LICENSE).
