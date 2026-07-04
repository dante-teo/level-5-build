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

# Run package tests including the opt-in ACP mock subprocess integration.
LEVEL5_RUN_ACP_PROCESS_INTEGRATION=1 swift test

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

`Level5Core` is the provider-neutral module where reusable runtime/domain code will grow. It currently owns recent-project persistence through GRDB and ACP protocol primitives. `Level5Design` owns native SwiftUI design primitives and reusable design resources. `Level5BuildApp` is the SwiftUI app target. The current UI is a native shell backed by an app-private agent session lifecycle model: a `NavigationSplitView` sidebar/detail layout, native window titlebar and command menus, startup session listing, selectable/deletable session rows, an unsent New Chat draft state, transcript replay, a native tokenized composer, per-session prompt queues, and a new-session-only project picker.

`Level5BuildApp` also depends on SwiftUI Introspect for narrow AppKit interop. It is currently used by `TranscriptView` to inspect the backing `NSScrollView` so follow-tail behavior can use real scroll metrics instead of SwiftUI layout-preference guesses.

Without an available backend, agent actions are disabled and the composer shows “Agent runtime unavailable”; there is no fake local “message captured” behavior in the active app path. Devin runtime process supervision is deferred to the Devin backend issue. In DEBUG builds only, `LEVEL5_USE_ACP_MOCK=1` selects the repo-local ACP mock backend for development. Release/Homebrew-style builds ignore mock env vars.

To exercise the current native mock path manually from the repo root:

```bash
./script/run_mock_app.sh
```

Mock mode connects to an independently running TCP mock server. `script/run_mock_app.sh` starts `acp-mock-server/start-tcp.sh`, waits for `127.0.0.1:58945`, then launches the app with `LEVEL5_USE_ACP_MOCK=1` plus `LEVEL5_ACP_MOCK_HOST` and `LEVEL5_ACP_MOCK_PORT`. The app does not spawn or supervise the mock process. This keeps development mock lifecycle outside the macOS app process; Devin runtime process supervision remains deferred to the Devin backend issue.

Once connected, the app initializes ACP, discovers mock model/slash-command metadata, and calls `session/list` so existing mock sessions appear in the sidebar. New Chat remains an unsent draft and creates no hidden ACP session until the first send. First send calls `session/new`, applies the selected New Chat model with `session/set_config_option` only when it differs from the reported model, inserts/selects the session row, then sends structured `session/prompt` content blocks; later sends reuse that `sessionId`. Selecting a row calls `session/load`, clears that session's in-memory transcript state, rebuilds it from backend replay events, and adopts backend session model config. Selection itself does not change sidebar recency; only sent or received live message activity updates app-observed recency. Delete uses ACP `session/delete`, refreshes the list, and returns to New Chat if the deleted session was active.

The native model supports multiple sessions with running turns at once. Each session has one active turn and an in-memory FIFO queue; sending again while that same session is running queues an immutable structured prompt snapshot for that session, and queued prompts render above the composer until they start or are removed. Queue and transcript caches are intentionally in-memory only for now.

The composer uses a narrow AppKit-backed `NSTextView` bridge for multiline editing and Return/Shift-Return handling, with SwiftUI owning the structured draft. The text area starts at one line, grows with content, and caps at 12 lines before internal scrolling. The `+` menu can add files through `NSOpenPanel` or insert backend slash commands. Attachments are capped at 10, deduped by standardized path, rendered as removable chips, and serialized as ACP `resource_link` blocks without reading file contents. Accepted commands are stored as tokens and serialized inline as slash text with minimal spacing. The toolbar model selector is populated from backend discovery/config; New Chat keeps the last selected model for the current backend when still available, and existing-session changes save optimistically through `session/set_config_option`, rolling back only the affected session if saving fails.

The composer toolbar also owns the app-private approval mode selector. Approval mode defaults to `Ask for approval` and is persisted per backend in `UserDefaults`. In `Ask for approval`, ACP `session/request_permission` requests are stored by `sessionId`; only the active session's pending request takes over the composer, while background session requests mark that sidebar row as awaiting approval. In `Approve for me`, the mock backend chooses an allow-like option when possible, falls back to the first option, and emits a compact status note. In `Full access`, the app chooses the same allow-like fallback silently. User-selected responses use ACP's selected outcome shape, `{ "outcome": { "outcome": "selected", "optionId": "<id>" } }`. Reject-with-instructions answers with a reject-like option and sends the typed instructions as the next prompt for that same session through the normal queue/send path.

Transcripts are stored as app-private structured state, not flat local role/text rows. ACP updates normalize into deterministic transcript events for message chunks, plans, tool calls, usage, statuses, errors, and stop reasons. Messages merge by `messageId` when available and fall back to contiguous same-role merging without an ID. Unsupported non-text blocks are retained as compact unsupported-block counts. Plans, tool calls, and usage render as compact inline operational cards; detailed dashboards, diffs, and terminal panes are intentionally deferred.

Transcript views follow the tail by default per session. When the user scrolls away from the bottom, that session stops auto-scrolling; it resumes only after the user scrolls back to the bottom. Reselecting a session preserves its existing follow-tail state. The native scroll controller reads `NSScrollView` document bounds, visible rect, and user input events; new transcript content only settles to bottom while follow-tail was already enabled. This state is in-memory and scoped per active session.

Prompt sends append an optimistic local user row only when the prompt starts. Backend user echo chunks are suppressed against a per-session pending echo queue, and failed prompts clear their pending echo entry so later sends do not duplicate user rows.

## Local persistence

The native shell persists recent project folders in SQLite via GRDB at `~/.level5build/level5.sqlite`. Runtime code uses that default path; tests inject temporary database URLs.

Recent projects are keyed by normalized absolute path, store display name plus created/opened timestamps, and are pruned to the 10 most recently opened folders. Selecting a project does not restore across launches: the selected project is window-local shell state, available only for the current new chat until the first message is sent. Missing recent folders remain listed as disabled rows so users can remove them explicitly.

## Design primitives

Import `Level5Design` from app views and use the typed `L5` APIs instead of hardcoding local visual values:

- `L5Color` for adaptive semantic colors.
- `L5Font` for Barlow and Departure Mono-backed type styles.
- `L5Spacing`, `L5Radius`, `L5Size`, and `L5Elevation` for documented token scales.
- `L5Asset.mark` for the in-app Level5 identity mark.
- `L5ButtonStyle`, `l5Surface`, `l5InputSurface`, and `l5CompactControl` for primitive SwiftUI styling.

`Level5BuildApp.init()` calls `Level5DesignResources.registerFonts()` so the bundled fonts are available before views render. The resources live under `Sources/Level5Design/Resources/Fonts` and `Sources/Level5Design/Resources/Assets`.

Native views should follow macOS system behavior and use adaptive materials. The legacy Electrobun CSS remains reference material only; do not copy its web gradients or Tailwind classes into SwiftUI. The primitive glass surfaces fall back to SwiftUI materials for the macOS 14 deployment target, while future SDK-specific Liquid Glass adoption should stay behind availability checks.

The shell views in `Sources/Level5BuildApp/Views/` should continue to consume `Level5Design` primitives while keeping runtime/domain state out of the design module.

## Assets

The native app icon lives in `Resources/Assets.xcassets/AppIcon.appiconset`. `project.yml` lists `Resources/Assets.xcassets` directly so Xcode compiles it with `actool`; do not change it to a folder reference. A successful Xcode build emits `Assets.car` and `AppIcon.icns` into the app bundle resources.

`Resources/AppIconSource.png` is the 1024x1024 source artwork used to regenerate the app icon sizes. Regenerate all files in `AppIcon.appiconset` from that source when the icon changes; do not edit only one size. The SwiftPM run script also compiles this same asset catalog, so the Xcode-built app and `dist/Level5 Build.app` stay visually aligned.

`Sources/Level5BuildApp/Resources/WindowBackground.jpeg` is a leftover scaffold asset and is no longer used by the active shell UI. Do not reintroduce it as product chrome or a design-system asset.
