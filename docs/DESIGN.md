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

## 3. Color Tokens

Use the existing Tailwind v4 CSS token system in `app/src/mainview/index.css`. Do not introduce one-off colors in components.

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

## 4. Typography

Primary font: Barlow.

Monospace font: Departure Mono.

The webview bundles these fonts from `app/src/mainview/assets/fonts/`; do not rely on system-installed fonts for the shipped app.

Type scale:

- Display: `32px / 700`
- H1: `28px / 700`
- H2: `22px / 650`
- H3: `18px / 600`
- Body: `14px / 400`
- Caption: `12px / 500`

Never introduce arbitrary font sizes. Match display text to its container: use compact text inside sidebars, panels, cards, buttons, and toolbars.

## 5. Spacing Scale

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

## 6. Radius

Use only these radius values:

- Window: `28`
- Panel: `24`
- Card: `20`
- Input: `18`
- Button: `16`
- Chip: `999`

Do not invent new radius values.

## 7. Shadow

Use only four elevations:

- E0: none
- E1: card
- E2: floating panel
- E3: modal

Never stack heavy shadows. Shadows should create quiet depth, not a floating-card collage.

## 8. App Layout

The primary layout is:

`Sidebar | Workspace | Optional Review Overlay`

Rules:

- Sidebar is user-resizable from `260px` to `420px`.
- Collapsing the sidebar hides it completely (`0px`) rather than leaving an icon rail.
- Workspace grows to fill remaining space.
- Review panel overlays the workspace from the right.
- Opening the review panel must never push or resize the workspace.
- Top bar always spans the full workspace width.
- Top bar actions remain right aligned.
- Window controls remain native.

The first screen should feel like a real app workspace, not a landing page.

## 9. Sidebar

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

## 10. Workspace

The workspace is the primary content area.

Rules:

- Padding: `24`.
- Keep maximum readability for chat, plans, file lists, and diffs.
- Do not place decorative cards behind content.
- Preserve open space when the conversation is empty.
- Let the bottom composer anchor the interaction model.

## 11. Top Bar

Height: `56`.

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
- The dashboard trigger and the floating app/session capsule share the same top offset so their outer capsule edges align.
- The pinned session dashboard is a compact floating panel aligned below the trigger. It should show operational state only: current changes, branch, active plan, and sources. Avoid environment/local/session rows unless they become actionable.
- The dashboard should reserve workspace width only when the remaining conversation pane can stay readable. On narrower windows it remains an overlay popover instead of forcing the chat column below its useful width.
- Dashboard layout thresholds should be defined in design units such as rem or component/token sizes, not arbitrary pixel breakpoints.

## 12. Prompt Composer

The composer is docked near the bottom of the workspace.

Rules:

- Large rounded container.
- Supports text, attachments, agent selection, and send.
- Grows with content.
- Maximum height is 8 text lines before internal scrolling.
- Placeholder text is muted and concise.
- Send is the only primary action in the composer group while idle. During an active agent turn, the send button becomes a stop button with a small circular loading indicator and sends ACP cancellation; do not add a second competing stop control.
- In the empty-chat state, the composer footer may show a `Choose project` control. Its popover should support search, recent project folders, `New project`, and `Don't work in a project`.
- Once a chat has visible transcript content, hide the project footer; project context moves to the top capsule when applicable.
- The `+` icon button opens the composer's "Add to prompt" menu, a single popover with an unheaded utility group (upload file, upload folder, plan mode placeholder), then a `Slash commands` group sourced live from the connected agent. Only show a `Skills` group if a real agent surface advertises skills separately; Devin currently exposes skill-like actions as slash commands. Reuse this menu (and its row styling) for any future "insert into prompt" affordance rather than adding a second popover pattern.
- Slash-command and skill tokens typed or inserted into the composer (e.g. `/plan`, `/workspace-search`) are highlighted using the single accent color, keeping the rest of the typed text at its normal style — do not introduce a second highlight color for this.
- The approval-mode control (icon + label + chevron, next to the `+` menu) opens a popover with a short header question, then one row per mode: an icon, a bold label, and a muted one-line description, with a trailing checkmark on the selected row. Use this row layout for any future single-select "mode" control instead of a native `<select>`.
- Once a chat has visible transcript content, a small context-usage ring appears immediately to the left of the Model selector: a compact circular progress indicator (accent color, escalating to warning/danger color as usage approaches the limit) showing the fraction of the model's context window used so far. Hovering or focusing it reveals a small rounded info card ("Context window:" label plus a bold "N% used (M% left)" line) anchored above the ring with a caret pointing back at it. This hover-card is a distinct pattern from the click-toggle popovers above (no open/close state, no click target) — reuse it for any future passive, read-only hover indicator rather than adding a third tooltip mechanism alongside native `title` attributes and click-toggle popovers.
- When a permission request is pending (approval mode `ask`, or any request the client couldn't auto-resolve), the approval prompt takes over the composer's input/toolbar area entirely, inside the same rounded container — it does not appear as a separate transcript card, and the prompt textarea/toolbar are inaccessible until it's answered. It shows a question, an optional muted code/detail block (collapsible past ~220 characters via an `Expand`/`Collapse` toggle), a numbered list of the request's options (arrow keys to move the highlight, Enter or click to choose), and a closing "tell the agent what to do differently" row that expands into a text field with `Skip`/`Submit`; submitting text there answers with a reject-kind option and hands the typed text to the composer as the next draft.
- The approval prompt has no separate cancel/dismiss control — the only way out is answering it (or its own "tell the agent what to do differently" path). Because of that, if responding fails for any reason (a stale request, a dropped RPC call), the composer must still give control back: it clears the pending prompt and shows an error card rather than leaving the takeover stuck with no way to type or send again.

## 13. Chat

Assistant messages:

- Use surface background when contained.
- Prefer readable text blocks over speech bubbles.

User messages:

- Use subtle tint only.
- Do not use speech bubbles.

Rules:

- Spacing between messages: `20`.
- Timestamps and metadata use caption styling.
- Plans, changed files, and summaries can appear as compact cards.
- Avoid decorative message chrome.
- In the current chat workspace, the transcript scroll layer spans from the sidebar edge to the right edge of the window and sits behind the foreground composer/top chrome. Keep transcript content centered for readability, but do not constrain the scroll container itself to the message column.
- Native transcript scrollbars should stay hidden; scrolling must still work.
- Because the composer visually overlays the tail of the scroll layer, the transcript reserves matching space via a real spacer element sized to the composer's live height (tracked with `ResizeObserver`), not a static padding guess, and uses `use-stick-to-bottom` to stay pinned to the true bottom as content streams in or the composer resizes (e.g. an approval prompt collapsing back to the normal composer). Do not swap this for `scrollIntoView()`/`Element.scrollIntoView` on an end-of-list sentinel — it aligns to the viewport edge, not past the reserved spacer, and silently leaves the latest content tucked behind the composer.

## 14. Review Panel

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

## 15. Diff Viewer

Rules:

- Use monospace.
- Use split view when possible.
- Use syntax highlighting.
- Use restrained addition/deletion colors.
- Avoid excessive background color and noisy borders.
- File rows should show changed counts clearly.

## 16. Buttons

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

## 17. Inputs

Rules:

- Height: `44`.
- Rounded.
- No visible border until focused unless the surrounding surface needs a boundary.
- Focus uses the accent ring.
- Hit target minimum is `40x40`.

## 18. Cards

Rules:

- Padding: `20`.
- Radius: `20`.
- Soft elevation.
- Do not nest cards; split content into separate groups instead.
- Use cards for real grouped content: plans, file summaries, metrics, and modals.
- Do not use decorative cards as section backgrounds.

## 19. Motion

Allowed durations:

- `120ms`
- `180ms`
- `240ms`

Rules:

- Use ease-out.
- Avoid bounce.
- Animations should be subtle and functional.
- Motion should clarify state changes, not entertain.

## 20. Empty States

Every empty state must explain:

- What happened
- Why it happened
- The next action

Never leave blank screens unless the blank space is an intentional ready state with a clear composer or primary action.

## 21. Loading

Rules:

- Prefer skeletons.
- Avoid spinners longer than 2 seconds.
- Preserve layout dimensions during loading.

## 22. Keyboard

Rules:

- Every major action should have a shortcut.
- The app should support keyboard-first workflow.
- Visible focus states are required.
- Do not remove native focus outlines unless replacing them with accessible equivalents.

## 23. Accessibility

Rules:

- Minimum contrast: WCAG AA.
- Hit target minimum: `40x40`.
- Never rely solely on color.
- Tooltips must name unfamiliar icon-only actions.
- Text must not overflow, overlap, or become unreadable on supported window sizes.

## 24. Implementation Rules

Before changing UI:

1. Read this document.
2. Reuse existing components.
3. Reuse existing tokens.
4. Reuse existing spacing.
5. Reuse existing colors.
6. Reuse existing shadows.
7. Reuse existing layout patterns.

If unsure, reuse the closest existing pattern.

## 25. Forbidden Patterns

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

## 26. Acceptance Checklist

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

## 27. Current App Foundation

The app currently renders a code-native full-bleed white gradient background (`.app-gradient-background`) with soft blue, violet, and pink light fields. Future screens should build from this design system rather than continuing as a blank canvas.

## 28. shadcn/ui Foundation

A shadcn/ui foundation is set up for future component work, configured manually because Electrobun's Bun + Vite setup is not one of `shadcn init`'s recognized presets.

- Config: `app/components.json`
- Style: `new-york`
- Base color: `neutral`
- CSS variables: enabled
- Icon library: `lucide`
- Component output: `app/src/mainview/components/ui/`
- Utility: `cn()` in `app/src/mainview/lib/utils.ts`

Add components from within `app/`:

```bash
bunx shadcn@latest add <component>
```

Double check generated imports resolve correctly against this project's aliases. Auto-detection may guess wrong because the bundler setup is non-standard.

## 29. Path Aliases

Aliases are configured identically in `app/vite.config.ts` and `app/tsconfig.json`. Update both together when adding new aliases.

- `@/*` -> `app/src/mainview/*`
- `@shared/*` -> `app/src/shared/*`

## 30. Styling Implementation

Tailwind CSS v4 is CSS-first in this project. There is no `tailwind.config.js`.

Theme tokens and the dark-mode variant live in `app/src/mainview/index.css` as CSS custom properties plus an `@theme inline` block, following shadcn's standard v4 token set. Keep the design tokens in this document aligned with those CSS variables.

## 31. Window Chrome

The window is frameless with `titleBarStyle: "hiddenInset"`:

- Native traffic lights are used.
- There is no visible native title bar.
- Electrobun is not Electron, so Electron APIs and title-bar patterns do not apply.

If a custom top bar or draggable region is added:

- Mark draggable background strips with `electrobun-webkit-app-region-drag`.
- Mark interactive controls inside a draggable region with `electrobun-webkit-app-region-no-drag`.
- Keep draggable strips clear of macOS traffic lights. The current strip starts to the right of the native controls instead of covering the full window.
- Double-clicking the current draggable background toggles maximize/fill-screen. See `docs/ARCHITECTURE.md` for why this exists in place of native drag-to-tile.
