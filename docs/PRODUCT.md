# Product

This app is a desktop-native AI coding agent environment. It is intended to feel like a focused local workbench for asking an agent to understand, change, review, and verify a codebase.

## Current state

`app/` is the active native macOS app shell. It currently provides a native `NavigationSplitView` window with a sidebar, a centered new-session workspace, a tokenized prompt composer, local project selection in the new-session footer, approval-mode controls, structured native transcript rows with per-session follow-tail scrolling, per-session queued prompts, an inspect-only Review column for Git working-tree changes, and menu commands for New Chat, Toggle Sidebar, Focus Composer, and Clear Transcript.

The native shell now selects a real agent backend automatically: if a `devin` CLI is found on `$PATH` or in a known install directory, the app spawns and drives it over ACP, with one concurrent `devin acp` process per open project so multiple projects can run turns at the same time. If no CLI is found (and, in DEBUG builds only, `LEVEL5_USE_ACP_MOCK=1` isn't set), agent actions are disabled and the composer shows an actionable "Devin CLI not found" message; it does not pretend a message was sent. DEBUG builds can still opt into the repo-local ACP mock server via `LEVEL5_USE_ACP_MOCK=1` for the same native session lifecycle path: startup model and slash-command discovery, first-send `session/new`, prompt turns, per-session in-memory queues, optimistic session model switching, and `session/delete` (best-effort against the backend; real Devin does not yet support `session/delete` server-side, but the app deletes the session locally regardless and remembers not to show it again — see `docs/ARCHITECTURE.md`). There is no ACP `session/list` call anywhere: the sidebar is sourced entirely from the local durable cache, and `session/load` only ever runs silently to prime a session's server-side context the first time it's sent to in a given app run — never to repaint the transcript. Selecting a session does not change sidebar recency; only live sent or received message activity does.

Native transcripts now keep app-private structured state for messages, plans, tool calls, usage, statuses, errors, and stop reasons. The UI renders messages as chat rows — with Markdown formatting (bold/italic, inline code, links, lists, headings, blockquotes, code blocks) rendered rather than shown as raw syntax — and tool/error events as compact inline cards; `.status` items (runtime diagnostics, raw stderr, permission audit notes, notable stop reasons) are recorded and persisted but are never rendered as transcript rows. The composer supports backend slash commands, file attachment chips serialized as `resource_link` blocks, a pre-session model selector, per-session drafts, queued prompt previews, approval-mode selection (backed by real Devin `--permission-mode` process restarts, not just the mock), and permission-request takeovers for ACP requests. Rich plan/tool/usage dashboards, terminal panes, and mutating Review actions are still future native work.

Recent project folders are persisted locally so the project picker can offer repeat selections. The active selected project itself is window-local state and is not restored on launch — but that selection only decides where the *next* new chat is created; it has no bearing on which sessions the sidebar shows (see below).

Sessions and their transcripts now survive a relaunch: the sidebar and the active transcript are cached to a local SQLite database (`~/.level5build/level5.sqlite`) and repaint instantly on next launch — that cache is the sidebar's only source (there is no backend session list to reconcile against), and it only advances further once the user actually sends into a session again. The sidebar is a single global list spanning every project's sessions at once: it loads in full on launch and is never filtered down to just the currently selected "new chat" project, so a session from any project you've ever used stays visible without needing to reselect that project first. Deleting a session from the sidebar always removes it locally and keeps it gone, even for backends (like real Devin today) that don't actually support deleting a session server-side. See `docs/ARCHITECTURE.md` ("Durable session/transcript persistence") for details.

The retired Electrobun app in `legacy/electrobun-app/` remains reference material for UI polish from the previous Devin-backed ACP workflow. Native Review now exists as an inspect-only Git diff column, but mutating review flows from the old proof of concept remain future work.

See `docs/ARCHITECTURE.md` for the app structure and runtime model. See `docs/DESIGN.md` for the visual system and layout rules.

## Native 1.0 Direction

The accepted 1.0 direction is a native macOS client, recorded in [ADR 0001](adr/0001-native-macos-client.md). The native app owns `app/`; the Electrobun proof of concept has moved to `legacy/electrobun-app/` and remains reference-only.

The product target stays the same: a calm desktop AI coding agent centered on chat, transparent agent progress, permissions, review diffs, commit, and revert. `acp-mock-server/` remains active shared test infrastructure for native development and CI.

## Product Direction

The target product is a calm desktop AI coding agent with these core surfaces:

- A fixed project/sidebar area for workspaces, project groups, recent conversations, settings, and account context.
- A primary workspace for chat, agent plans, progress, code-change summaries, and empty or ready states.
- A bottom prompt composer for text, attachments, agent selection, and sending.
- A review surface for changed files and diffs; approval, revert, and commit actions are future extensions beyond the current inspect-only pane.
- Optional tool tabs for review, terminal, and browser contexts when a task needs persistent inspection.

## Primary Workflows

The initial workflow should support:

1. Choose or continue a project conversation.
2. Ask the agent to inspect or change the codebase.
3. Watch the agent report plans, progress, and changed files.
4. Review diffs without losing the chat context.
5. Approve, revert, or commit changes when ready. These remain future mutating flows beyond the current inspect-only Review pane.

The app should make code review and agent state easy to scan without turning the workspace into a dense IDE clone.

## Product Principles

- Desktop first: design for native window behavior, keyboard flow, and long-running work.
- Agent transparent: expose plans, status, changed files, and verification outcomes clearly.
- Review centered: code changes should always be inspectable before approval.
- Calm by default: use empty space, restrained color, and stable layout to reduce cognitive load.
- Fast paths: common actions should be reachable by keyboard and compact controls.

## Non-Goals For Now

- A marketing landing page inside the app shell.
- A full IDE replacement with editor ownership as the primary interaction.
- Decorative dashboards that do not help task execution or review.
- Multiple competing visual languages or per-feature style systems.
- Production-grade session history (retention/eviction limits, cross-device sync), production-grade attachment handling, mic input, and production approval policy. Basic durable session/transcript caching for a single machine now exists; see `docs/ARCHITECTURE.md`.
