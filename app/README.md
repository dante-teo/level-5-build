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

The staged SwiftPM app is not produced by Xcode. `script/build_and_run.sh` therefore handles two app-bundle details explicitly:

- It compiles `Resources/Assets.xcassets` with `xcrun actool` so the staged app gets the same `Assets.car`, `AppIcon.icns`, `CFBundleIconFile`, and `CFBundleIconName` behavior as the generated Xcode app.
- It copies SwiftPM resource bundles such as `Level5Build_Level5BuildApp.bundle` and `Level5Build_Level5Design.bundle` next to `dist/Level5 Build.app`, matching SwiftPM's generated `Bundle.module` lookup path for bundled resources.

## Layout

```text
app/
├── Package.swift
├── project.yml
├── Resources/
│   ├── AppIconSource.png
│   └── Assets.xcassets/
├── Sources/
│   ├── Level5BuildApp/
│   ├── Level5Design/
│   └── Level5Core/
└── Tests/
    ├── Level5BuildAppTests/
    ├── Level5DesignTests/
    └── Level5CoreTests/
```

`Level5Core` is the provider-neutral module where reusable runtime/domain code will grow. `Level5Design` owns native SwiftUI design primitives and reusable design resources. `Level5BuildApp` is the SwiftUI app target. The current UI is a minimal native shell only; full workspace layout, persistence, runtime integration, signing, notarization, and packaging are deferred to follow-up issues.

## Design primitives

Import `Level5Design` from app views and use the typed `L5` APIs instead of hardcoding local visual values:

- `L5Color` for adaptive semantic colors.
- `L5Font` for Barlow and Departure Mono-backed type styles.
- `L5Spacing`, `L5Radius`, and `L5Elevation` for documented token scales.
- `L5Asset.mark` for the in-app Level5 identity mark.
- `L5ButtonStyle`, `l5Surface`, `l5InputSurface`, and `l5CompactControl` for primitive SwiftUI styling.

`Level5BuildApp.init()` calls `Level5DesignResources.registerFonts()` so the bundled fonts are available before views render. The resources live under `Sources/Level5Design/Resources/Fonts` and `Sources/Level5Design/Resources/Assets`.

Native views should follow macOS system behavior and use adaptive materials. The legacy Electrobun CSS remains reference material only; do not copy its web gradients or Tailwind classes into SwiftUI. The primitive glass surfaces fall back to SwiftUI materials for the macOS 14 deployment target, while future SDK-specific Liquid Glass adoption should stay behind availability checks.

Issue #5 should consume `Level5Design` for the real sidebar, workspace, composer, and window shell.

## Assets

The native app icon lives in `Resources/Assets.xcassets/AppIcon.appiconset`. `project.yml` lists `Resources/Assets.xcassets` directly so Xcode compiles it with `actool`; do not change it to a folder reference. A successful Xcode build emits `Assets.car` and `AppIcon.icns` into the app bundle resources.

`Resources/AppIconSource.png` is the 1024x1024 source artwork used to regenerate the app icon sizes. Regenerate all files in `AppIcon.appiconset` from that source when the icon changes; do not edit only one size. The SwiftPM run script also compiles this same asset catalog, so the Xcode-built app and `dist/Level5 Build.app` stay visually aligned.

`Sources/Level5BuildApp/Resources/WindowBackground.jpeg` is a temporary scaffold background for visually checking glass/material surfaces. It is app-owned, not part of `Level5Design`, and should be removed or replaced when the real issue #5 shell/workspace lands.
