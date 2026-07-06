---
version: 1
name: Level5 Build Design System
description: Native macOS SwiftUI design tokens and UI rules for the Level5 Build desktop AI coding agent.
---

# Design System

This document is the source of truth for Level5 Build's native macOS visual and interaction design. Before changing UI, read this document and reuse the `Level5Design` tokens, components, and layout patterns.

## Overview

Level5 Build is a desktop-native AI coding environment. It should feel calm, focused, premium, lightweight, and fast. The design priorities are clarity, consistency, information hierarchy, speed, and visual quality.

Never design the app shell like a marketing website. Never imitate Windows settings panels. Do not use decoration without purpose.

Native SwiftUI design primitives live in `app/Sources/Level5Design/`. App views should import `Level5Design` and consume typed `L5` APIs instead of hardcoding one-off colors, font sizes, radii, spacing, shadows, materials, or resource names.

The module owns:

- `L5Color`: adaptive semantic color tokens that preserve the Level5 light-mode direction and provide dark-mode-safe variants.
- `L5Font`: display, heading, body, caption, and monospace helpers backed by bundled Barlow and Departure Mono font resources.
- `L5Spacing`, `L5Radius`, `L5Size`, and `L5Elevation`: documented token scales for layout rhythm, corner treatment, fixed control dimensions, and quiet depth.
- `L5Asset`: typed access to in-app identity artwork such as the Level5 mark.
- `L5Icon` and `L5IconView`: semantic, tintable in-app icons backed by SF Symbols.
- `L5ButtonStyle` and the `l5Surface`, `l5InputSurface`, and `l5CompactControl` modifiers for primitive controls and glass/material surfaces.

`Level5BuildApp` calls `Level5DesignResources.registerFonts()` during startup. The app target owns the bundle app icon in `app/Resources/Assets.xcassets/AppIcon.appiconset`; `Level5Design` owns only reusable in-app identity resources.

App icon artwork is owned by the app target, not by `Level5Design`. The source image is `app/Resources/AppIconSource.png`; generated icon sizes live in `app/Resources/Assets.xcassets/AppIcon.appiconset`. Keep the icon calm and Apple-native: a clear rounded-square silhouette, restrained material depth, and simple developer-tool symbolism. Avoid loud gradients, neon accents, busy code glyphs, childish marks, and generated-logo flourishes.

In-app icons are not app icon artwork. They should be vector, monochrome, template/tintable, and readable at `16px`. Do not generate raster PNG icon sets for app chrome. Keep custom icon styling centralized in `L5Icon`; use direct SF Symbols only for mechanical controls such as chevrons, close affordances, file-type glyphs, and backend-provided command icons where the exact symbol is local to that control.

The retired Electrobun proof of concept remains useful for product direction only. Native SwiftUI should not clone Tailwind gradients, shadcn implementation mechanics, CSS aliases, Electrobun window chrome, or retired scaffold images. New native UI uses `Level5Design`, system-adaptive macOS materials, and standard SwiftUI/AppKit behavior. Where current SDKs expose Liquid Glass APIs, use them behind availability checks for custom app-specific surfaces; on the macOS 14 deployment target, fall back to SwiftUI materials such as `.regularMaterial` and `.thinMaterial`.

## Colors

Use `L5Color` semantic colors and SwiftUI materials. Do not invent fixed local colors for app chrome.

Core tokens are implemented in `L5Color`:

- `background`: light `#FAFAFC`, dark `#131416`
- `secondaryBackground`: light `#F4F4F8`, dark `#1C1D20`
- `surface`: adaptive translucent white, light `72%`, dark `8%`
- `elevatedSurface`: adaptive translucent white, light `86%`, dark `12%`
- `textPrimary`: light `#171717`, dark `#F0F0F0`
- `textSecondary`: light `#6B7280`, dark `#B3B3B3`
- `textMuted`: light `#9CA3AF`, dark `#858585`
- `border`: adaptive hairline, light black `8%`, dark white `10%`
- `accent`: light `#3F5CF5`, dark `#6F8DFF`
- `accentForeground`: adaptive primary-action foreground, light white and dark near-black for contrast
- `selectedSurface`: adaptive accent tint, light `10%`, dark `18%`
- `success`: light `#16A34A`, dark `#3FD176`
- `warning`: light `#F59E0B`, dark `#FBBC05`
- `danger`: light `#DC2626`, dark `#F87171`

Accent rules:

- Use exactly one accent color throughout the application.
- Accent coverage should never exceed roughly 5% of the viewport.
- Use accent for selected navigation, focused controls, primary actions, active tabs, slash-command highlights, and small state indicators.
- Warning and danger are reserved for operational state, risk, and errors.
- Never rely solely on color; pair color with text, shape, iconography, or position.

## Typography

Primary product font direction is Barlow. Monospace text uses Departure Mono. Both families are bundled in `app/Sources/Level5Design/Resources/Fonts/`.

Use `L5Font` instead of constructing arbitrary `Font.custom` calls in app views.

Type scale:

- Display: `32 / 700`
- H1: `28 / 700`
- H2: `22 / 600`
- H3: `18 / 600`
- Body: `14 / 400`
- Caption: `12 / 500`
- Mono: `13 / 400` by default

Do not introduce arbitrary font sizes. Match display text to its container: use compact text inside sidebars, panels, cards, buttons, and toolbars.

## Layout

The primary layout is:

`Sidebar | Workspace | Optional Review Column`

Rules:

- Sidebar is user-resizable from `260px` to `420px`.
- Collapsing the sidebar hides it completely (`0px`) rather than leaving an icon rail.
- Workspace grows to fill remaining space.
- Review, when open, is a true third column to the right of the workspace.
- Review should preserve at least a `520px` workspace; hide the Review toggle when the window cannot fit the workspace, resize handle, and default Review column even after sidebar collapse.
- The Review column is user-resizable for the current open interaction and should keep a visible drag target between the workspace and Review.
- The project dashboard adapts inside the workspace between reserved wide layout and compact popover/overlay behavior.
- Reserved dashboard space should still feel visually connected to the transcript area, not like a separate app column.
- Top bar always spans the full workspace width.
- Top bar actions remain right aligned and should be kept minimal.
- Window controls remain native.

Use only the `L5Spacing` scale: `4`, `8`, `12`, `16`, `20`, `24`, `32`, `40`, `48`, and `64`. Layout rhythm should feel calm and readable, not loose or web-hero-like.

The first screen should feel like a real app workspace, not a landing page. The current native shell uses native window chrome, a `NavigationSplitView` sidebar, a centered new-session prompt, structured transcript rows, a native composer, a new-session-only project picker backed by recent local folders, and an adaptive project dashboard for project-backed active sessions.

## Elevation & Depth

Use `L5Elevation` and SwiftUI materials for depth. Shadows should create quiet hierarchy, not a floating-card collage.

Elevation scale:

- E0: none
- E1: card or standard panel
- E2: glass or floating panel
- E3: modal

Rules:

- Never stack heavy shadows.
- Prefer material contrast and spacing before adding extra depth.
- Avoid excessive borders; use boundaries only when needed for readability or interaction.

## Shapes

Use `L5Radius` for corner treatment:

- Window: `28`
- Panel: `24`
- Card: `20`
- Input: `18`
- Button: `16`
- Medium: `12`
- Small: `8`
- Chip: `999`

Use `L5Size` for repeated fixed control and icon dimensions:

- Icon: `16`
- Action: `24`
- Control: `32`
- Hit target: `32`

Do not hardcode repeated dimensions in app views. Icon-only buttons should use tokenized hit targets for predictable toolbar rhythm. Text-bearing buttons and menus should normally fit their content instead of using arbitrary max-width frames.

## Components

### Sidebar

Width is user-resizable from `260px` to `420px`; collapsed width is `0px`.

Contains workspace switcher, navigation, project groups, recent conversations, settings, and account status.

Rules:

- Never collapse into icon-only mode automatically.
- Manual collapse hides the sidebar completely. Keep the collapse/expand affordance outside the sidebar so it remains reachable when the sidebar is hidden.
- Selected rows use a subtle surface tint plus the accent color.
- Session rows in the current chat UI live under an `All chats` header. The empty state should sit close to the header, not centered deep in the sidebar.
- The active session row may show a compact right-aligned state indicator: spinner while running, quiet completion glyph when done, and no indicator while idle.
- State precedence is awaiting permission, running, successful completion, then idle.
- Delete is available only through the row context menu as `Delete Chat...` and must use native destructive confirmation before calling the backend.
- Group hierarchy should be readable without heavy separators.
- Bottom account/settings areas may use a quiet divider.
- The floating app capsule sits just outside the sidebar edge. Only the collapse/expand icon inside the capsule is clickable; app logo/name text are display-only.

### Workspace

The workspace is the primary content area.

Rules:

- Padding uses `L5Spacing.x6` (`24`).
- Keep maximum readability for chat, plans, file lists, and diffs.
- Do not place decorative cards behind content.
- Preserve open space when the conversation is empty.
- Let the bottom composer anchor the interaction model.
- The transcript scroll layer spans from the sidebar edge to the right edge of the window and sits behind the foreground composer/top chrome. Keep transcript content centered for readability, but do not constrain the scroll container itself to the message column.
- Native transcript scrollbars should stay hidden; scrolling must still work.

### Top Bar

Height is content-driven. The current workspace toolbar row uses circular `44px` icon buttons plus vertical padding, for an effective height of about `60px`.

Rules:

- The workspace top bar is a translucent overlay, not a second opaque app header.
- Use native/material glass behavior with a top-to-bottom fade so transcript content can begin under it while remaining readable through scroll content inset.
- Do not hide the macOS traffic-light controls to achieve this treatment.
- Controls align right and stay sparse.
- The floating capsule stays just outside the sidebar edge and always contains the sidebar collapse/expand button.
- When no project-backed chat is active, the capsule shows the app icon and `Level5`.
- When a project-backed chat is active, the capsule may replace the app identity with a compact session title and muted project subtitle.
- A project-backed active session may show a top-right dashboard trigger. When the dashboard is pinned open, the trigger should visibly highlight with the single accent color.
- Any selected project or project-backed session may show a top-right Review trigger when the default Review column can fit.
- Dashboard and Review triggers use the same circular glass treatment. Review keeps the same icon in open and closed states.
- Interactive controls inside draggable regions must opt out of drag behavior.

### Project Dashboard

The project dashboard is contextual, not a permanent inspector. It appears only for project-backed active sessions and should show operational state, not raw runtime payloads.

Behavior:

- Regular and wide layouts auto-open it, but users must still be able to close it.
- Compact layouts use a temporary popover/overlay from the dashboard button.
- Resize, session changes, or project-context changes should return the dashboard to the adaptive policy.
- Reserve workspace width only when the remaining conversation pane can stay readable.
- Fit content height when possible and scroll only when content would exceed available height.
- Layout thresholds should be defined with design tokens or component-derived values, not arbitrary pixel breakpoints.

Content order:

- Environment summary: changes, local project, branch, and commit/pull-request actions when relevant.
- Plan: always expanded in the dashboard; keep the composer `Plan N/M` chip.
- Sources: references used by the agent.

References should be quiet and curated. Show web URLs and external local files. Do not show project-local file reads by default. Dedupe references by kind and URI, not by title.

### Prompt Composer

The composer is docked near the bottom of the workspace.

Rules:

- Use `L5Color.elevatedSurface`, `L5Color.textPrimary`, `L5Font.body`, `L5Radius.card`, `L5Spacing.x4`, and `L5Size.hitTarget` for the composer primitive.
- Runtime-backed controls such as attachments, agent/model selection, approval modes, slash commands, plan progress, and context indicators should appear only when backed by real behavior.
- The text input starts at one line, grows with content, and caps at 12 text lines before internal scrolling.
- Placeholder text is muted and concise.
- Send is the primary action while idle. During an active agent turn, the same circular button becomes an enabled Stop action using `stop.fill` with native help text `Stop agent turn`.
- Stop immediately restores composer editing for that selected session, sends ACP `session/cancel`, cancels any pending permission request with ACP's cancelled outcome, clears queued prompts for that same session, preserves already-streamed transcript rows, suppresses stale late output from that cancelled turn, and records a compact cancelled status (never rendered as a transcript row).
- If the user sends again immediately after Stop, stale output must remain suppressed until the backend echoes the new prompt's user message so cancelled-turn output does not appear as part of the new turn.
- In the empty-chat state, the composer footer shows `Choose project` when no project is selected, or the selected folder name when project context exists.
- The footer's Git branch indicator shows the selected project's real current branch once fetched; hide it entirely (no placeholder label) while no project is selected or Git status is unavailable, per the runtime-backed-controls rule above.
- The project popover supports search, recent project folders, `New project`, and `Don't work in a project`.
- Recent project rows show the folder name and a muted, middle-truncated path. Missing folders are disabled, visibly marked, and removable rather than silently deleted.
- Once a chat has visible transcript content, hide the project footer and lock project context until New Chat.
- The `+` icon button opens the composer's "Add to prompt" menu: Add file first, then backend-provided slash commands.
- Folder attachments, placeholders, and separate Skills groups should not appear unless real backed behavior is added. Devin currently exposes skill-like actions as slash commands.
- Slash-command and skill tokens typed or inserted into the composer are highlighted using the single accent color.
- The approval-mode control uses intrinsic width and the native SwiftUI `Menu` pattern for `Ask for approval`, `Approve for me`, and `Full access`.
- When a session has active or recently completed plan state, show a centered composer-adjacent `Plan N/M` chip above queued prompt previews. Clicking it opens a compact checklist popover with human-readable plan entries. Do not render plan updates as transcript rows.
- Once runtime usage data exists, show a small context-usage ring immediately to the left of the Model selector. It uses accent below 70%, warning from 70%, and danger from 90%; Reduce Motion disables any pulse.
- When a permission request is pending for the active session in `Ask for approval`, the approval prompt takes over the composer's input/toolbar area inside the same rounded container. It does not appear as a separate transcript card.
- The approval prompt has no separate cancel/dismiss control. If responding fails, the composer must clear the pending prompt and show a composer status error rather than leaving the takeover stuck. The active turn Stop action also clears the takeover by answering the pending ACP permission request with a cancelled outcome.

### Chat

Assistant messages use surface background when contained and should prefer readable text blocks over speech bubbles. User messages may use subtle tint only; do not use speech bubbles.

Rules:

- Spacing between messages is `20`.
- Timestamps and metadata use caption styling.
- Tool calls and errors appear as compact operational transcript rows. Statuses (runtime diagnostics, raw stderr, permission audit notes, notable stop reasons like `cancelled`/`refusal`/`max_tokens`) are never shown as transcript rows, regardless of source — they exist only as internal/persisted bookkeeping.
- Tool rows auto-expand while `in_progress`, auto-collapse when `completed` unless manually expanded, and remain expanded when `failed`.
- Expanded tool rows show normalized status, kind, and readable detail text. Collapsed rows keep the title and a one-line detail preview.
- Chat message bodies (user and agent) render Markdown — bold/italic, inline code, links, lists, headings, blockquotes, and code blocks — via the `L5MarkdownTheme` (`MarkdownUI` theme built from `L5Font`/`L5Color`/`L5Spacing` tokens), not raw text, so authored formatting displays instead of literal `**`/backtick/`-` syntax.
- Never show raw JSON, schema payloads, or ACP identifiers.
- Avoid decorative message chrome.
- When the composer visually overlays the tail of the scroll layer, reserve matching space with real layout measurement rather than a static padding guess.
- Follow-tail must match messenger behavior: stay pinned only while the user is already at the bottom, stop immediately when the user scrolls away, preserve that state per session, and resume only after the user scrolls back to the bottom.

### Review Panel

The native Review experience is an inspect-only third column for Git working-tree changes. It is available for New Chat with a selected project and for project-backed sessions.

Width defaults to `600px` and is user-resizable from `420px` to `820px` for the current open interaction only. Do not persist width or open state.

Contains:

- Header summary, branch/root hint, running-agent stale hint, filter, refresh, and close.
- Compact path/status filter.
- Continuous file sections with path, rename subtitle, staged/unstaged/mixed badges, additions/deletions, and binary/image/large markers.
- Unified diff sections with old/new gutters and horizontal scrolling.
- Current working-tree image previews for changed images when AppKit can load them.
- Friendly Git errors with raw details in disclosure.

Rules:

- Opening Review may collapse the sidebar on narrow windows to preserve workspace width.
- Review is non-mutating: no commit, revert, staging, discard, approval, or permission-answering actions.
- Use Git as the source of truth; do not show ignored files or recursive submodule contents.
- Resolve previews from the repository root even when the selected project is a subdirectory, and expand untracked directories into file rows.
- Large per-file diffs over `200 KB` show a deterministic too-large state, not truncation.
- Keep the continuous diff dense but readable; avoid card stacks inside the column.
- Use adaptive `Level5Design` colors and materials for Review chrome. Diff semantics are derived from `L5Color.success`, `L5Color.danger`, `L5Color.accent`, and muted text tokens, not from a fixed dark editor palette.
- Do not show icon-only Review controls unless they have real backed behavior. Backed controls today are refresh, close, filter, running/stale hint, and project/root context.

### Diff Viewer

Rules:

- Use monospace.
- Use split view when possible.
- Use syntax highlighting when available.
- Use restrained addition/deletion colors.
- Avoid excessive background color and noisy borders.
- File rows should show changed counts clearly.

### Buttons

Primitive variants are `primary`, `secondary`, and `subtle` in `L5ButtonStyle`. Use danger styling only where the local component has destructive semantics and explicit confirmation behavior.

Primary buttons use `L5Color.accent` for the background and `L5Color.accentForeground` for adaptive contrast. Secondary buttons use material surfaces with `L5Color.textPrimary`; subtle buttons use `L5Color.selectedSurface` with `L5Color.textSecondary`.

Rules:

- Only one primary button per visual group.
- Loading states keep width fixed.
- Disabled opacity is `40%` unless native control semantics make a different disabled treatment clearer.
- Prefer `L5IconView` for semantic product icons and native SF Symbols for mechanical control glyphs.
- Use text or icon+text buttons only for clear commands.
- Icon-only buttons should use tokenized dimensions and native help text for unfamiliar actions.

### Inputs

Rules:

- Use `l5InputSurface()` for primitive text inputs unless a native control already provides a better platform treatment.
- Current primitive input minimum height is `36`.
- Repeated compact controls and icon-only hit targets use `L5Size.hitTarget` (`32`).
- Rounded inputs use `L5Radius.input`.
- Focus uses the accent ring or native accessible focus treatment.
- Do not remove native focus outlines unless replacing them with accessible equivalents.

### Cards

Rules:

- Padding uses `20`.
- Radius uses `20`.
- Use soft elevation only.
- Do not nest cards; split content into separate groups instead.
- Use cards for real grouped content: plans, file summaries, metrics, and modals.
- Do not use decorative cards as section backgrounds.

### Motion

Allowed durations:

- `120ms`
- `180ms`
- `240ms`

Rules:

- Use ease-out.
- Avoid bounce.
- Animations should be subtle and functional.
- Motion should clarify state changes, not entertain.
- Respect Reduce Motion. Disable pulsing, decorative movement, and nonessential transitions when requested.

### Empty States

Every empty state must explain what happened, why it happened, and the next action.

Never leave blank screens unless the blank space is an intentional ready state with a clear composer or primary action.

### Loading

Rules:

- Prefer skeletons when the layout is known.
- Avoid spinners longer than 2 seconds.
- Preserve layout dimensions during loading.

### Keyboard

Rules:

- Every major action should have a shortcut.
- The app should support keyboard-first workflow.
- Visible focus states are required.
- Do not remove native focus outlines unless replacing them with accessible equivalents.
- Permission prompts support arrow-key highlight movement and Enter/click to choose.

### Accessibility

Rules:

- Minimum contrast is WCAG AA.
- Tokenized hit target for repeated compact controls is `32`; larger native controls should be used where the platform pattern calls for them.
- Never rely solely on color.
- Tooltips or native help must name unfamiliar icon-only actions.
- Text must not overflow, overlap, or become unreadable on supported window sizes.
- Interactive controls inside draggable regions must remain reachable by pointer and keyboard.

## Do's and Don'ts

Do:

- Read this document before changing UI.
- Reuse `Level5Design` tokens, components, spacing, colors, radii, shadows, and layout patterns.
- Use native SwiftUI/AppKit controls and materials where they fit.
- Keep the shell calm, precise, and fast.
- Keep runtime and domain state out of `Level5Design`.
- Keep in-app icons vector, monochrome, template/tintable, and readable at `16px`.
- Keep app icon artwork in the app target, not in `Level5Design`.

Don't:

- Add new visual styles without a product reason.
- Mix multiple design languages.
- Introduce gradients without approval.
- Create floating windows unless specified.
- Push layout when opening overlays.
- Use arbitrary repeated pixel values where `L5` tokens exist.
- Duplicate components.
- Add decorative icons.
- Add unnecessary borders.
- Create landing-page hero layouts inside the app shell.
- Use card backgrounds behind page sections.
- Treat retired Electrobun, Tailwind, shadcn, CSS aliases, or old frameless-window rules as guidance for new native UI.

Implementation is accepted only if spacing follows the scale, typography follows the scale, colors come from the token set, radius follows the token set, shadows follow the elevation set, overlay panels do not shift layout, there is one primary CTA per visual group, keyboard navigation works, loading and empty states exist, and no arbitrary styles are introduced.

Run `pnpm dlx @google/design.md lint docs/DESIGN.md` before accepting design-document changes. The command must exit `0` with `errors: 0` and `warnings: 0`.
