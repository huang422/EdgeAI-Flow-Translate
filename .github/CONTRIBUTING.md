# Contributing to Flow Translate

Thanks for your interest in improving Flow Translate! Contributions are
welcome — bug reports, fixes, features, and docs.

## Before you start

- **Sign the CLA.** Your first pull request must agree to the
  [Contributor License Agreement](CLA.md). An automated check will prompt you
  to post a one-line agreement comment; it's a one-time step per contributor.
- **The brand is protected.** The code is Apache-2.0, but "Flow Translate" the
  name and logo are not. Contributing code is always fine; just don't ship your
  own build under the Flow Translate name.

## Development setup

Requirements: macOS 15+ on Apple Silicon, **Xcode 26+** (macOS 26+ SDK and Metal Toolchain), and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
git clone <this-repo> Flow-Translate
cd Flow-Translate
make bootstrap     # generates the Xcode project and opens it
```

The Xcode project is generated from [`project.yml`](../project.yml); it is not
checked in. Re-run `make project` after adding or renaming files.

## Build & test

```bash
make build         # builds the FlowTranslateCore package
make test          # runs the unit tests
make install       # tests, builds Release, verifies and updates /Applications/FlowTranslate.app
make run           # alias for the same Release installation
```

## Pull request checklist

1. Branch off `main` and keep changes focused.
2. Follow the existing Swift style; keep `FlowTranslateCore` free of
   platform/UI dependencies (Foundation only).
3. Add or update tests when you change behavior.
4. Run `make install` for app changes or `make test` for core-only changes.
5. Write a clear PR description of what changed and why.
6. Agree to the [CLA](CLA.md) when prompted.

## Reporting bugs / ideas

Open a GitHub issue with steps to reproduce, what you expected, and what
happened (logs/screenshots help). For security-sensitive reports, email
**huang1473690@gmail.com** instead of filing a public issue.

## Code of conduct

Be respectful and constructive. Harassment or abusive behavior isn't welcome.

## Native lifecycle smoke checks

The optional CLI target exercises the production ASR and audio router without
recording a microphone or changing privacy permissions. It requires the existing
ASR/VAD cache; it does not set up conda or install another application.

```bash
make project
xcodebuild -project FlowTranslate.xcodeproj -scheme FlowTranslateDiagnostics \
  -configuration Release -derivedDataPath build/release ARCHS=arm64 \
  CODE_SIGNING_ALLOWED=NO build
build/release/Build/Products/Release/FlowTranslateDiagnostics --cancel-regression
build/release/Build/Products/Release/FlowTranslateDiagnostics --variant-regression
build/release/Build/Products/Release/FlowTranslateDiagnostics --router-regression
```

Pass a local audio file instead of a regression flag for two real ASR sessions
with both source tags. `--language en-US|auto` and `--tier 560ms|1120ms|2240ms`
select an already cached variant; `--cold-stop` also checks that delayed final
results survive Stop. This is ASR/VAD validation, not translation or diarization
quality evaluation. The first native load may take minutes for device-specific
Core ML specialization; the second session must reuse the resident weights.

The model-free termination target compiles the production `AppDelegate` with a
fake cleanup operation. It catches main-queue termination deadlocks and checks
that repeated Quit requests wait for one completed cleanup:

```bash
xcodebuild -project FlowTranslate.xcodeproj -scheme FlowTranslateTerminationDiagnostics \
  -configuration Release -derivedDataPath build/release ARCHS=arm64 \
  CODE_SIGNING_ALLOWED=NO build
build/release/Build/Products/Release/FlowTranslateTerminationDiagnostics
build/release/Build/Products/Release/FlowTranslateTerminationDiagnostics --sheet
build/release/Build/Products/Release/FlowTranslateTerminationDiagnostics --repeat
build/release/Build/Products/Release/FlowTranslateTerminationDiagnostics --sheet --repeat
build/release/Build/Products/Release/FlowTranslateTerminationDiagnostics --external
```

App actions, including the Quit menu, must use `AppDelegate.requestTermination()`.
Repeated direct `NSApp.terminate` calls can bypass a pending asynchronous cleanup
inside AppKit. `--external` checks one normal native event entry without the
helper; it does not log out the Mac or simulate a force quit.

`FlowTranslateDiagnostics --retry-regression` checks that a failed shared model
load stops automatic attempts and the next explicit Start retries once.
Pass `--diarization --source-prewarm` with a local audio file to time startup
using cached speaker assets and the same early preload path as app launch.
`--variant-regression` covers shared weight identity and rapid preset changes
while an earlier native load is still in progress.

## Caption UI and translation regressions

After a Release build, replay the production SwiftUI caption pane, summary card
and floating overlay without audio, model downloads or production preferences:

```bash
python3 Diagnostics/check-caption-layout.py
xcodebuild -project FlowTranslate.xcodeproj -scheme FlowTranslateTranslationDiagnostics \
  -configuration Release -derivedDataPath build/release ARCHS=arm64 \
  CODE_SIGNING_ALLOWED=NO build
build/release/Build/Products/Release/FlowTranslateTranslationDiagnostics
```

The UI script compiles the current view declarations with fixture outer chrome.
It checks three window sizes, a complete summary card and status/button rows,
an anchored lower edge, natural panel growth for one to three complete bilingual
units, intermediate roll/fade frames, and scrolling to both ends of an
over-height caption. It also opens the actual Settings sheet
from the main button, switches panes, scrolls the form and dismisses the sheet.
The close fixture sends native window-close notifications through the production
handler, with test model holders and audio input. It covers the last window,
rapid reopen during summary cancellation and the shared Quit cleanup.
Test-only colours identify the real bilingual blocks in native paint captures;
compiler scratch files are removed automatically. It does not validate live audio
or real translation quality. The translation CLI checks production queue/cache
behaviour with fake host responses, including language-session handoff, retry,
exact-input reuse and bounded cache eviction. Neither diagnostic installs an app.
