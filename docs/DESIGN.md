# Design System

> Product: Desktop AI Coding Agent

This document is the source of truth for visual and interaction design in the desktop app. Before changing UI, read this document and reuse the established tokens, components, and layout patterns.

## 1. Product Philosophy

The application is a desktop-native AI coding environment. It must feel calm, focused, premium, lightweight, and fast.

Priorities:

1. Clarity
2. Consistency
3. Information hierarchy
4. Speed
5. Visual beauty

Never design like a marketing website. Never imitate Windows settings panels. Never use decoration without purpose.

## 2. Visual Language

Keywords:

- Calm
- Airy
- Native
- Minimal
- Professional
- Precise

Avoid:

- Loud gradients
- Neon colors
- Rounded cartoon UI
- Gaming aesthetics
- Excessive borders
- Arbitrary decorative icons

The reference direction is a quiet macOS-style workspace: soft translucent surfaces, crisp type, subtle shadows, generous breathing room, and a restrained blue-violet accent used only for state and primary action.

## 3. Native Design Primitives

Native SwiftUI design primitives live in `app/Sources/Level5Design/`. App views should import `Level5Design` and consume typed `L5` APIs instead of hardcoding one-off colors, font sizes, radii, spacing, shadows, materials, or resource names.

The module owns:

- `L5Color`: adaptive semantic color tokens that preserve the Level5 light-mode direction and provide dark-mode-safe variants.
- `L5Font`: display, heading, body, caption, and monospace helpers backed by bundled Barlow and Departure Mono font resources.
- `L5Spacing`, `L5Radius`, `L5Size`, and `L5Elevation`: documented token scales for layout rhythm, corner treatment, fixed control dimensions, and quiet depth.
- `L5Asset`: typed access to in-app identity artwork such as the Level5 mark.
- `L5ButtonStyle` and `l5Surface`, `l5InputSurface`, `l5CompactControl` modifiers for primitive controls and glass/material surfaces.

`Level5BuildApp` calls `Level5DesignResources.registerFonts()` during startup. The app target still owns the bundle app icon in `app/Resources/Assets.xcassets/AppIcon.appiconset`; `Level5Design` owns only reusable in-app identity resources.

App icon artwork is owned by the app target, not by `Level5Design`. The source image is `app/Resources/AppIconSource.png`; generated icon sizes live in `app/Resources/Assets.xcassets/AppIcon.appiconset`. Keep the icon calm and Apple-native: a clear rounded-square silhouette, restrained material depth, and simple developer-tool symbolism. Avoid loud gradients, neon accents, busy code glyphs, childish marks, and generated-logo flourishes.

The retired Electrobun proof of concept remains useful for product direction, but native SwiftUI should not clone its Tailwind gradients or CSS implementation. Prefer system-adaptive macOS materials and standard controls. Where current SDKs expose Liquid Glass APIs, use them behind availability checks for custom app-specific surfaces; on the macOS 14 deployment target, fall back to SwiftUI materials such as `.regularMaterial` and `.thinMaterial`.

The native shell should use these primitives for sidebar, workspace, composer, and window surfaces. This design module intentionally stops at reusable primitives.

The active shell no longer uses the old `app/Sources/Level5BuildApp/Resources/WindowBackground.jpeg` scaffold image. Do not treat that image as product design direction or a reusable design-system asset.

## 4. Color Tokens

The retired Electrobun proof of concept keeps its Tailwind v4 CSS token system in `legacy/electrobun-app/src/mainview/index.css`. Native macOS design tokens are implemented in `Level5Design`; use those typed tokens and semantic SwiftUI materials rather than inventing one-off fixed colors.

Core tokens:

- Background: `#FAFAFC`
- Secondary background: `#F4F4F8`
- Surface: `rgba(255, 255, 255, 0.72)`
- Primary text: `#171717`
- Secondary text: `#6B7280`
- Muted text: `#9CA3AF`
- Border: `rgba(0, 0, 0, 0.08)`
- Success: `#16A34A`
- Warning: `#F59E0B`
- Danger: `#DC2626`

Accent:

- Use exactly one accent color throughout the application.
- Accent coverage should never exceed roughly 5% of the viewport.
- Use accent for selected navigation, focused controls, primary actions, active tabs, and small state indicators.

## 5. Typography

Primary product font direction: Barlow.

Monospace font: Departure Mono.

Native packaging now bundles these fonts in `app/Sources/Level5Design/Resources/Fonts/`. Use `L5Font` from `Level5Design` rather than constructing arbitrary `Font.custom` calls in app views.

Type scale:

- Display: `32px / 700`
- H1: `28px / 700`
- H2: `22px / 650`
- H3: `18px / 600`
- Body: `14px / 400`
- Caption: `12px / 500`

Never introduce arbitrary font sizes. Match display text to its container: use compact text inside sidebars, panels, cards, buttons, and toolbars.

## 6. Spacing Scale

Only use these spacing values:

- `4`
- `8`
- `12`
- `16`
- `20`
- `24`
- `32`
- `40`
- `48`
- `64`

No arbitrary spacing values. Layout rhythm should feel calm and readable, not loose or web-hero-like.

## 7. Radius

Use only these radius values:

- Window: `28`
- Panel: `24`
- Card: `20`
- Input: `18`
- Button: `16`
- Medium: `12`
- Small: `8`
- Chip: `999`

Do not invent new radius values.

## 8. Fixed Sizes

Use `L5Size` for repeated fixed control and icon dimensions:

- Icon: `16`
- Action: `24`
- Control/hit target: `32`

Do not hardcode these values in app views. Icon-only buttons should use tokenized hit targets for accessibility and predictable toolbar rhythm. Text-bearing buttons and menus should normally fit their content instead of using arbitrary max-width frames.

## 9. Shadow

Use only four elevations:

- E0: none
- E1: card
- E2: floating panel
- E3: modal

Never stack heavy shadows. Shadows should create quiet depth, not a floating-card collage.

## 10. App Layout

The primary layout is:

`Sidebar | Workspace | Optional Project Dashboard`

Rules:

- Sidebar is user-resizable from `260px` to `420px`.
- Collapsing the sidebar hides it completely (`0px`) rather than leaving an icon rail.
- Workspace grows to fill remaining space.
- The project dashboard adapts between reserved wide layout and compact popover/overlay behavior.
- Reserved dashboard space should still feel visually connected to the transcript area, not like a separate app column.
- Top bar always spans the full workspace width.
- Top bar actions remain right aligned and should be kept minimal.
- Window controls remain native.

The first screen should feel like a real app workspace, not a landing page.

Current native shell note: the shell uses native window chrome, a `NavigationSplitView` sidebar, a centered new-session prompt, structured transcript rows, a native composer, a new-session-only project picker backed by recent local folders, and an adaptive project dashboard for project-backed active sessions. The composer includes functional attachment chips, a `+` menu, backend slash-command insertion, a model selector, an approval-mode selector, permission-request takeovers, queued prompt previews, and a working Stop action while a turn is active.

## 11. Sidebar

Width: user-resizable from `260px` to `420px`; collapsed width is `0px`.

Contains:

- Workspace switcher
- Navigation
- Project groups
- Recent conversations
- Settings
- Account status

Rules:

- Never collapse into icon-only mode automatically.
- Manual collapse hides the sidebar completely. Keep the collapse/expand affordance outside the sidebar so it remains reachable when the sidebar is hidden.
- Selected rows use a subtle surface tint plus the accent color.
- Session rows in the current chat UI live under an `All chats` header. The empty state should sit close to the header, not centered deep in the sidebar.
- The active session row may show a compact right-aligned state indicator: spinner while running, quiet completion glyph when done, and no indicator while idle.
- Group hierarchy should be readable without heavy separators.
- Bottom account/settings areas may use a quiet divider.
- The floating app capsule sits just outside the sidebar edge. Only the collapse/expand icon inside the capsule is clickable; app logo/name text are display-only.

## 12. Workspace

The workspace is the primary content area.

Rules:

- Padding: `24`.
- Keep maximum readability for chat, plans, file lists, and diffs.
- Do not place decorative cards behind content.
- Preserve open space when the conversation is empty.
- Let the bottom composer anchor the interaction model.

## 13. Top Bar

Height: `56`.

The workspace top bar is a translucent overlay, not a second opaque app header. It should use native/material glass behavior with a top-to-bottom fade so transcript content can begin under it while remaining readable through scroll content inset. Do not hide the macOS traffic-light controls to achieve this treatment.

Keep top-bar controls sparse. For the current workspace, a single dashboard button is the default right-side control. Icon-only buttons should be circular; grouped controls should be capsule-shaped. Use design tokens and native materials instead of hardcoded frames, offsets, or one-off colors.

Contains:

- Floating app/session capsule
- Branch or context metadata
- Quick actions
- Active tool tabs when applicable

Rules:

- Top bar controls align right.
- The floating capsule stays just outside the sidebar edge and always contains the sidebar collapse/expand button.
- When no project-backed chat is active, the capsule shows the app icon and `Level5`.
- When a project-backed chat is active, the capsule may replace the app identity with a compact session title and muted project subtitle.
- Use icon buttons for compact actions.
- Use visible labels only for navigation tabs or commands that require clarity.
- Interactive controls inside draggable regions must opt out of drag behavior.
- A project-backed active session may show a top-right dashboard trigger. The trigger uses a rounded glass capsule with one icon button; when the dashboard is pinned open, the trigger should visibly highlight with the single accent color.
- The dashboard trigger and the floating app/session capsule should align on the same tokenized toolbar row. Keep their icon buttons vertically centered even when the session capsule grows to show a title/subtitle.

## 14. Project Dashboard

The project dashboard is contextual, not a permanent inspector. It appears only for project-backed active sessions and should show operational state, not raw runtime payloads.

Behavior:

- Regular and wide layouts auto-open it, but users must still be able to close it.
- Compact layouts use a temporary popover/overlay from the dashboard button.
- Resize, session changes, or project-context changes should return the dashboard to the adaptive policy.
- Reserve workspace width only when the remaining conversation pane can stay readable; narrower windows should use overlay/popover behavior instead of forcing the chat column below its useful width.
- Fit content height when possible and scroll only when content would exceed available height.
- Layout thresholds should be defined with design tokens or component-derived values, not arbitrary pixel breakpoints.

Content order:

- Environment summary: changes, local project, branch, and commit/pull-request actions when relevant.
- Plan: always expanded in the dashboard; keep the composer `Plan N/M` chip.
- Sources: references used by the agent.

References should be quiet and curated. Show web URLs and external local files. Do not show project-local file reads by default; they create noise in a coding transcript. Dedupe references by kind and URI, not by title.

## 15. Prompt Composer

The composer is docked near the bottom of the workspace.

Rules:

- Large rounded container.
- Runtime-backed composer controls such as attachments, agent/model selection, approval modes, slash commands, plan progress, and context indicators should appear only when they are backed by real behavior.
- The text input starts at one line, grows with content, and caps at 12 text lines before internal scrolling.
- Placeholder text is muted and concise.
- Send is the primary action in the composer group while idle. During an active agent turn, the same circular button becomes an enabled Stop action using `stop.fill` with native help text `Stop agent turn`. Stop immediately restores composer editing for that selected session, sends ACP `session/cancel`, cancels any pending permission request with ACP's cancelled outcome, clears queued prompts for that same session, preserves already-streamed transcript rows, suppresses stale late output from that cancelled turn, and appends a compact cancelled status. If the user sends again immediately, stale output must remain suppressed until the backend echoes the new prompt's user message so cancelled-turn output does not appear as part of the new turn.
- In the empty-chat state, the composer footer shows a `Choose project` control when no project is selected, or the selected folder name when project context exists. Its popover supports search, recent project folders, `New project`, and `Don't work in a project`.
- Recent project rows show the folder name and a muted, middle-truncated path. Missing folders are disabled, visibly marked, and removable rather than silently deleted.
- Once a chat has visible transcript content, hide the project footer and lock project context until New Chat. Project context can move to the top capsule later when runtime-backed sessions exist.
- The `+` icon button opens the composer's "Add to prompt" menu: Add file first, then backend-provided slash commands. Folder attachments, placeholders, and separate Skills groups should not appear unless a real backed behavior is added; Devin currently exposes skill-like actions as slash commands. Reuse this menu for future "insert into prompt" affordances rather than adding a second popover pattern.
- Slash-command and skill tokens typed or inserted into the composer (e.g. `/plan`, `/workspace-search`) are highlighted using the single accent color, keeping the rest of the typed text at its normal style — do not introduce a second highlight color for this.
- The approval-mode control (icon + label + chevron, next to the `+` menu) is runtime-backed and uses intrinsic width; do not give text-bearing toolbar menu controls arbitrary max-width frames. It currently uses the native SwiftUI `Menu` pattern for `Ask for approval`, `Approve for me`, and `Full access`.
- When a session has active or recently completed plan state, show a centered composer-adjacent `Plan N/M` chip above queued prompt previews. Clicking it opens a compact checklist popover with human-readable plan entries. Do not render plan updates as transcript rows.
- Once runtime usage data exists, a small context-usage ring appears immediately to the left of the Model selector: a compact circular progress indicator showing the fraction of the model's context window used so far. It uses accent below 70%, warning from 70%, and danger from 90%; warning and danger can pulse, but Reduce Motion disables that pulse. Hovering, focusing, or clicking it reveals a small info card with percent used, tokens left, used/size tokens, and optional cost. Do not render usage updates as transcript rows.
- When a permission request is pending for the active session in `Ask for approval`, the approval prompt takes over the composer's input/toolbar area inside the same rounded container. It does not appear as a separate transcript card, and the prompt textarea/toolbar are inaccessible until it is answered. It shows the request title, optional muted detail/raw-input text, one row per backend-provided option, arrow-key highlight movement, Enter/click to choose, and a reject-with-instructions field. Submitting instructions answers with a reject-like option and sends the text as the next prompt for that same session.
- The approval prompt has no separate cancel/dismiss control. If responding fails for any reason, the composer must give control back: it clears the pending prompt and shows a composer status error rather than leaving the takeover stuck with no way to type or send again. The active turn Stop action also clears the takeover by answering the pending ACP permission request with a cancelled outcome.

## 16. Chat

Assistant messages:

- Use surface background when contained.
- Prefer readable text blocks over speech bubbles.

User messages:

- Use subtle tint only.
- Do not use speech bubbles.

Rules:

- Spacing between messages: `20`.
- Timestamps and metadata use caption styling.
- Tool calls, statuses, errors, and notable stop reasons appear as compact operational transcript rows. Tool rows auto-expand while `in_progress`, auto-collapse when `completed` unless manually expanded, and remain expanded when `failed`; expanded rows show normalized status, kind, and readable detail text. Collapsed rows keep the title and a one-line detail preview. Never show raw JSON, schema payloads, or ACP identifiers.
- Avoid decorative message chrome.
- In the current chat workspace, the transcript scroll layer spans from the sidebar edge to the right edge of the window and sits behind the foreground composer/top chrome. Keep transcript content centered for readability, but do not constrain the scroll container itself to the message column.
- Native transcript scrollbars should stay hidden; scrolling must still work.
- When the composer visually overlays the tail of the scroll layer, the transcript should reserve matching space with real layout measurement rather than a static padding guess. In the legacy web implementation this used `ResizeObserver` plus `use-stick-to-bottom`; the native app currently keeps SwiftUI transcript rendering but uses SwiftUI Introspect to read the backing `NSScrollView`'s visible rect and document bounds for follow-tail decisions.

Sidebar chat rows should keep a fixed trailing state slot. State precedence is awaiting permission, running, successful completion, then idle. Delete is available only through the row context menu as `Delete Chat...` and must use native destructive confirmation before calling the backend.
- Follow-tail must match messenger behavior: stay pinned only while the user is already at the bottom, stop immediately when the user scrolls away, preserve that state per session, and resume only after the user scrolls back to the bottom. Do not use transient SwiftUI geometry readings as the sole source of truth for this behavior.

## 17. Review Panel

The review experience may appear in two modes:

- Floating right overlay for compact review.
- Right-side tool surface with tabs when review, terminal, or browser need persistent access.

Preferred floating width: `380`.

Maximum floating width: `420`.

Contains:

- Summary
- Changed files
- Diff preview
- Approval actions

Rules:

- Opening review must never shift the main workspace.
- Floating review should not become a full-height sidebar.
- Persistent tool surfaces may fill height, but must read as a mode of the workspace rather than a second app shell.
- Commit or approval actions belong at the bottom of the review surface.

## 18. Diff Viewer

Rules:

- Use monospace.
- Use split view when possible.
- Use syntax highlighting.
- Use restrained addition/deletion colors.
- Avoid excessive background color and noisy borders.
- File rows should show changed counts clearly.

## 19. Buttons

Variants:

- Primary
- Secondary
- Ghost
- Danger

Rules:

- Only one primary button per visual group.
- Loading states keep width fixed.
- Disabled opacity is `40%`.
- Prefer lucide icons inside icon buttons.
- Use text or icon+text buttons only for clear commands.

## 20. Inputs

Rules:

- Height: `44`.
- Rounded.
- No visible border until focused unless the surrounding surface needs a boundary.
- Focus uses the accent ring.
- Hit target minimum is `40x40`.

## 21. Cards

Rules:

- Padding: `20`.
- Radius: `20`.
- Soft elevation.
- Do not nest cards; split content into separate groups instead.
- Use cards for real grouped content: plans, file summaries, metrics, and modals.
- Do not use decorative cards as section backgrounds.

## 22. Motion

Allowed durations:

- `120ms`
- `180ms`
- `240ms`

Rules:

- Use ease-out.
- Avoid bounce.
- Animations should be subtle and functional.
- Motion should clarify state changes, not entertain.

## 23. Empty States

Every empty state must explain:

- What happened
- Why it happened
- The next action

Never leave blank screens unless the blank space is an intentional ready state with a clear composer or primary action.

## 24. Loading

Rules:

- Prefer skeletons.
- Avoid spinners longer than 2 seconds.
- Preserve layout dimensions during loading.

## 25. Keyboard

Rules:

- Every major action should have a shortcut.
- The app should support keyboard-first workflow.
- Visible focus states are required.
- Do not remove native focus outlines unless replacing them with accessible equivalents.

## 26. Accessibility

Rules:

- Minimum contrast: WCAG AA.
- Hit target minimum: `40x40`.
- Never rely solely on color.
- Tooltips must name unfamiliar icon-only actions.
- Text must not overflow, overlap, or become unreadable on supported window sizes.

## 27. Implementation Rules

Before changing UI:

1. Read this document.
2. Reuse existing components.
3. Reuse existing tokens.
4. Reuse existing spacing.
5. Reuse existing colors.
6. Reuse existing shadows.
7. Reuse existing layout patterns.

If unsure, reuse the closest existing pattern.

## 28. Forbidden Patterns

Do not:

- Add new visual styles.
- Mix multiple design languages.
- Introduce gradients without approval.
- Create floating windows unless specified.
- Push layout when opening overlays.
- Use arbitrary pixel values.
- Duplicate components.
- Add decorative icons.
- Add unnecessary borders.
- Create landing-page hero layouts inside the app shell.
- Use card backgrounds behind page sections.

## 29. Acceptance Checklist

Implementation is accepted only if:

- Spacing follows the scale.
- Typography follows the scale.
- Colors come from the token set.
- Radius follows the token set.
- Shadows follow the elevation set.
- Overlay panels do not shift layout.
- There is one primary CTA per section.
- Keyboard navigation works.
- Loading and empty states exist.
- No arbitrary styles are introduced.
- The result feels native, calm, precise, and fast.

## 30. Legacy Electrobun App Foundation

The retired Electrobun proof of concept renders a code-native full-bleed white gradient background (`.app-gradient-background`) with soft blue, violet, and pink light fields. Native macOS token and component implementation is deferred to the native design follow-up.

## 31. Legacy shadcn/ui Foundation

A shadcn/ui foundation exists only in the legacy Electrobun app, configured manually because Electrobun's Bun + Vite setup is not one of `shadcn init`'s recognized presets.

- Config: `legacy/electrobun-app/components.json`
- Style: `new-york`
- Base color: `neutral`
- CSS variables: enabled
- Icon library: `lucide`
- Component output: `legacy/electrobun-app/src/mainview/components/ui/`
- Utility: `cn()` in `legacy/electrobun-app/src/mainview/lib/utils.ts`

Add components from within `legacy/electrobun-app/` only when explicitly working on the legacy reference app:

```bash
bunx shadcn@latest add <component>
```

Double check generated imports resolve correctly against this project's aliases. Auto-detection may guess wrong because the bundler setup is non-standard.

## 32. Legacy Path Aliases

Aliases are configured identically in `legacy/electrobun-app/vite.config.ts` and `legacy/electrobun-app/tsconfig.json`. Update both together when adding new aliases.

- `@/*` -> `legacy/electrobun-app/src/mainview/*`
- `@shared/*` -> `legacy/electrobun-app/src/shared/*`

## 33. Legacy Styling Implementation

Tailwind CSS v4 is CSS-first in this project. There is no `tailwind.config.js`.

Theme tokens and the dark-mode variant live in `legacy/electrobun-app/src/mainview/index.css` as CSS custom properties plus an `@theme inline` block, following shadcn's standard v4 token set. Native macOS token primitives will live in the native app after the design-token follow-up lands.

## 34. Window Chrome

The window is frameless with `titleBarStyle: "hiddenInset"`:

- Native traffic lights are used.
- There is no visible native title bar.
- Electrobun is not Electron, so Electron APIs and title-bar patterns do not apply.

If a custom top bar or draggable region is added:

- Mark draggable background strips with `electrobun-webkit-app-region-drag`.
- Mark interactive controls inside a draggable region with `electrobun-webkit-app-region-no-drag`.
- Keep draggable strips clear of macOS traffic lights. The current strip starts to the right of the native controls instead of covering the full window.
- Double-clicking the current draggable background toggles maximize/fill-screen. See `docs/ARCHITECTURE.md` for why this exists in place of native drag-to-tile.
