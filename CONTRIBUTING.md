# Contributing to TouchBarChat

Thank you for helping improve TouchBarChat. Changes to audio capture, transcription, turn-taking, API requests, and privacy deserve particular care because a small regression can lose words or disclose interview content.

## Before you start

- Read [README.md](README.md), [Interview flow design](Docs/InterviewFlowDesign.md), and [runtime notes](Docs/InterviewRuntime.md) for the current product boundaries.
- Keep the app's primary capture source as **Mac playback audio**, not microphone input. Do not add remote speech recognition or automatic upload of audio, transcripts, or profiles without an explicit product decision and a clear user-facing consent flow.
- Use Apple public APIs where possible. The existing Touch Bar presentation uses an undocumented AppKit selector; contain that dependency and preserve a main-window fallback.
- Do not use a real interview for a test or screenshot unless everyone involved has consented and the setting permits it. Prefer synthetic audio and fictional text.

## Local development

From the repository root, use an Xcode or Command Line Tools installation with a Swift 6-capable toolchain:

```bash
./Scripts/check.sh
```

This runs `swift format lint --strict` with the repository's `.swift-format` configuration, followed by `swift test --disable-sandbox`. Passing local tests is not a seven-language, multi-OS, or real Touch Bar acceptance test.

The package declares macOS 13 as its minimum deployment target. A successful build or test on a newer Mac does not establish runtime compatibility with every supported OS version. If your change affects packaging or entitlements, build the app separately with `./Scripts/build-app.sh` and verify the signed app, its bundled localization resources, and macOS permissions on a suitable machine. Do not commit `Build/` or `.build/`.

The repository's `.swift-format` specifies four-space indentation, a 120-column line length, and trailing commas for multi-element collections. Match nearby Swift style, use descriptive names, and keep comments focused on **why** a boundary or workaround exists rather than restating each statement.

## Tests and verification

- Add or update a focused test for changed turn boundaries, text correction, saved-record behavior, API parsing, and settings validation.
- Test both ordinary and adverse paths: silence in the middle of a question, short acknowledgements, revised partial transcripts, delayed AI fragments, pause/resume/end, unavailable local models, and missing Touch Bar.
- For localization changes, update all seven resource tables: `zh-Hans`, `en`, `ko`, `ja`, `ru`, `fr`, and `pt-BR`. Check both the **Follow System** setting and explicit UI-language selection; keep those settings separate from interview and AI-answer languages. Do not claim an Apple speech locale is supported merely because its picker entry or translation exists.
- For privacy-sensitive changes, inspect exactly what reaches disk and the configured API. Confirm that audio, screen frames, API keys, and private profiles are not accidentally logged.
- Describe what you tested and what remains unverified in the pull request. Automated tests are not a substitute for consenting, real-device validation of capture permissions, local speech, and Touch Bar behavior.

## Pull requests

Keep each pull request scoped. Include the problem, the behavior change, affected macOS versions or locales, tests run, and any privacy or migration implications. Update the README or design docs when user-visible behavior changes. If you need screenshots, use fictional records and check the whole image for personal data, API credentials, menu-bar account details, and notification previews.

Never commit or paste:

- API keys, personal profiles, transcripts, recorded audio, crash reports containing user data, or diagnostic logs containing those values;
- local signing certificates, provisioning profiles, or signed `.app` bundles;
- machine-specific paths, account names, or screenshots with private information.

If a key is exposed, revoke or rotate it immediately; deleting it from a later commit does not remove it from Git history. Report a suspected security or privacy issue privately to the repository maintainer rather than attaching secrets to a public issue.

## Responsible use

Contributions should make permission state, capture scope, and failure modes clearer to the user. Do not add features whose purpose is to hide capture, evade an interview platform's rules, or impersonate a speaker. AI suggestions must remain distinguishable from the interviewer's words and from verified facts about the user.
