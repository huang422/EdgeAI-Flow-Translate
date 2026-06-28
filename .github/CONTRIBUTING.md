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

Requirements: macOS 15+ on Apple Silicon, **Xcode 16+**, and
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
make run           # regenerates, builds Debug, and launches the app
```

Please make sure `make test` passes before opening a pull request.

## Pull request checklist

1. Branch off `main` and keep changes focused.
2. Follow the existing Swift style; keep `FlowTranslateCore` free of
   platform/UI dependencies (Foundation only).
3. Add or update tests when you change behavior.
4. Run `make test` (and `make run` for app changes) locally.
5. Write a clear PR description of what changed and why.
6. Agree to the [CLA](CLA.md) when prompted.

## Reporting bugs / ideas

Open a GitHub issue with steps to reproduce, what you expected, and what
happened (logs/screenshots help). For security-sensitive reports, email
**huang1473690@gmail.com** instead of filing a public issue.

## Code of conduct

Be respectful and constructive. Harassment or abusive behavior isn't welcome.
