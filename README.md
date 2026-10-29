# Cleanori

A small macOS cleaner for developers. Cleanori finds caches and builds that tools can regenerate, big files you have
not opened in a while, and shows where your disk space goes.

- **Developer Junk**: Xcode DerivedData, `node_modules`, npm / pnpm / Yarn / Bun caches, Gradle caches and old
  wrappers, project builds (Android, iOS, `.next`, `.expo`), CocoaPods, Homebrew and other tool caches, unavailable
  iOS simulators, and (unticked by default) old SDKs, DeviceSupport, Archives and Android emulators.
- **Large Files**: files of 100 MB or more in your home folder, oldest-opened first. Nothing is ticked until you choose.
- **Disk Map**: the biggest folders as bubbles; click one to look inside. It only shows sizes.

## Install

```bash
brew install --cask ahmadanshori/tap/cleanori
```

Cleanori needs macOS 15 Sequoia or later, on Apple Silicon or Intel.

### Opening it the first time

Cleanori is not notarized by Apple, so macOS blocks it the first time you open it:

1. Open Cleanori. macOS says it cannot check it for malicious software; click **Done**.
2. Open **System Settings → Privacy & Security**, scroll down to "Cleanori was blocked…" and click **Open Anyway**.

If you would rather not do that, build it yourself (see below).

### Full Disk Access

Give Cleanori Full Disk Access in **System Settings → Privacy & Security → Full Disk Access**, then quit and reopen it.
Without it, macOS asks for each protected folder and some sizes are only estimates (marked `≈`).

## What it deletes

- Only what its built-in catalog finds inside your home folder, and only after you confirm the list.
- Caches and builds that tools download or rebuild on their own are deleted permanently. Unavailable simulators are
  deleted with `xcrun simctl`. Things that cannot be rebuilt (Archives, SDKs, Android emulators) and every Large File
  go to the Trash.
- Anything an app is still using (DerivedData while Xcode runs, Gradle caches while a Gradle daemon runs) is locked and
  left alone.
- Every action is written to `~/Library/Logs/Cleanori/clean-YYYY-MM-DD.jsonl`.

Look over the list before you press **Clean**. Cleanori comes with no warranty (see the license).

## Build from source

You need Xcode 26 (Swift 6.2) and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```bash
xcodegen generate
open Cleanori.xcodeproj
```

The core logic lives in the `CleanoriCore` Swift package and has its own tests:

```bash
swift test --package-path Packages/CleanoriCore
```

`scripts/make-release.sh` builds a universal (Apple Silicon and Intel) release and zips it for a GitHub release.
`scripts/make-app-icon.swift` redraws the app icon.

## License

MIT. See [LICENSE](LICENSE).
