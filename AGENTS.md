# Agent notes

This repo currently hosts `app/`, a native macOS scaffold using SwiftUI, Swift Package Manager modules, Swift Testing, and XcodeGen. The retired Electrobun POC lives in `legacy/electrobun-app/` for reference only, and `acp-mock-server/` remains active shared test infrastructure. See `docs/adr/0001-native-macos-client.md`, `docs/ARCHITECTURE.md`, and `docs/DESIGN.md`.

## Setup & running

Requires Xcode 16+ and XcodeGen (`brew install xcodegen`) for the native app.

```bash
cd app
xcodegen generate --spec project.yml --project .
swift test
xcodebuild test -project "Level5 Build.xcodeproj" -scheme "Level5 Build" -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
```

## Verification

From `app/`, these should succeed after native scaffold changes:

```bash
swift test
xcodebuild test -project "Level5 Build.xcodeproj" -scheme "Level5 Build" -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=""
```

Avoid actually launching the GUI unless asked. `script/build_and_run.sh` opens a real window; use it only when local app launch is the intended check.

## Gotchas

- Generated Xcode projects are not committed. Update `app/project.yml`, then regenerate locally with XcodeGen.
- Keep `Resources/Assets.xcassets` as a direct XcodeGen source entry, not a folder reference, so Xcode compiles it with `actool` and emits `Assets.car` plus `AppIcon.icns`.
- Keep `Level5Core` provider-neutral. App-specific SwiftUI code belongs in `Level5BuildApp`.
- `legacy/electrobun-app/` is reference-only. Its old Electrobun/Tailwind gotchas still apply there, but new product work should land in the native app unless explicitly directed otherwise.
