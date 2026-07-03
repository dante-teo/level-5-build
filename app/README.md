# Level5 Build Native macOS App

`app/` now contains the native macOS scaffold for Level5 Build. It uses SwiftUI, Swift Package Manager modules, Swift Testing, and XcodeGen as the source of truth for the generated Xcode project.

The previous Electrobun proof of concept moved to `../legacy/electrobun-app/` for reference. It remains buildable from that directory, but it is no longer the active app path.

## Requirements

- macOS 14 or newer
- Xcode 16 or newer. The package uses Swift 6 and Swift Testing.
- XcodeGen (`brew install xcodegen`)

## Commands

```bash
# Generate the local Xcode project. The generated .xcodeproj is ignored.
xcodegen generate --spec project.yml --project .

# Run package tests.
swift test

# Run Xcode build and test checks without signing.
xcodebuild test \
  -project "Level5 Build.xcodeproj" \
  -scheme "Level5 Build" \
  -destination "platform=macOS" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=""
```

From the repo root, Codex Run is wired to:

```bash
./script/build_and_run.sh
```

The script builds the Swift package, stages a local `dist/Level5 Build.app`, and launches it as a foreground macOS app. Normal verification should use `swift test` and `xcodebuild test`; do not launch the GUI unless you are intentionally running the app locally.

## Layout

```text
app/
├── Package.swift
├── project.yml
├── Resources/
│   └── Assets.xcassets/
├── Sources/
│   ├── Level5BuildApp/
│   └── Level5Core/
└── Tests/
    ├── Level5BuildAppTests/
    └── Level5CoreTests/
```

`Level5Core` is the provider-neutral module where reusable runtime/domain code will grow. `Level5BuildApp` is the SwiftUI app target. The current UI is a minimal native shell only; full workspace layout, design tokens, persistence, runtime integration, signing, notarization, and packaging are deferred to follow-up issues.

## Assets

The native app icon lives in `Resources/Assets.xcassets/AppIcon.appiconset`. `project.yml` lists `Resources/Assets.xcassets` directly so Xcode compiles it with `actool`; do not change it to a folder reference. A successful Xcode build emits `Assets.car` and `AppIcon.icns` into the app bundle resources.
