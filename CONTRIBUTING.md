# Contributing to Tapwire

Thanks for helping. Bug reports, feature ideas and pull requests are all welcome.

## Reporting a bug

Open a [bug report](https://github.com/chandanklc/Tapwire/issues/new?template=bug_report.yml). The most
useful details are:

- Tapwire version (Tapwire → About Tapwire) and macOS version
- The client: iPhone, Android phone, emulator, Simulator or the Mac itself
- Steps to reproduce, and what you expected instead
- A HAR export of the failing call (right-click it → Export as HAR…), with secrets removed

Don't post tokens, cookies or passwords from captured traffic.

## Building

```bash
brew install xcodegen
```

```bash
xcodegen generate
```

```bash
open Tapwire.xcodeproj
```

Choose the **Tapwire** scheme and Run (⌘R). The Xcode project is generated from `project.yml`, so change
that file rather than the project, and don't commit `Tapwire.xcodeproj` changes by hand.

## Running the tests

```bash
xcodebuild test -scheme Tapwire -derivedDataPath build/DD
```

The integration tests start a local echo server and proxy, so they need no network access.

## Code layout

- `Sources/TapwireCore`: proxy engine (SwiftNIO), certificates, rules, storage. No UI code here.
- `Sources/Tapwire`: the SwiftUI app. Colours and building blocks are in `UI/Theme.swift`.
- `Tests/TapwireCoreTests`: unit and integration tests.
- `DECISIONS.md`: why things are the way they are. Worth a read before larger changes.

## Pull requests

- Keep each pull request to one change, and add or update tests for engine changes.
- Run the tests before opening it.
- For UI changes, add a before/after screenshot.
- For a big feature, open an issue first so we can agree on the approach.

By contributing you agree that your work is released under the [MIT licence](LICENSE).
