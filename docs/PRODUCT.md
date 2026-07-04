# Product

This app is a desktop-native AI coding agent environment. It is intended to feel like a focused local workbench for asking an agent to understand, change, review, and verify a codebase.

## Current state

`app/` is the active native macOS app shell. It currently provides a native `NavigationSplitView` window with a sidebar, a centered new-session workspace, a prompt composer, local project selection in the new-session footer, simple transcript rows with per-session follow-tail scrolling, per-session queued prompts, and menu commands for New Chat, Toggle Sidebar, Focus Composer, and Clear Transcript.

The current native shell has no production agent backend by default. When no backend is available, agent actions are disabled and the composer shows “Agent runtime unavailable”; it does not pretend a message was sent. For mock development, DEBUG builds launched with `LEVEL5_USE_ACP_MOCK=1` use the repo-local ACP mock server for the real native session lifecycle path: startup `session/list`, first-send `session/new`, prompt turns, `session/load` replay, per-session in-memory queues, and `session/delete`. Selecting a session does not change sidebar recency; only live sent or received message activity does.

Recent project folders are persisted locally so the project picker can offer repeat selections. The active selected project itself is window-local state and is not restored on launch.

The retired Electrobun app in `legacy/electrobun-app/` remains the reference for the previous Devin-backed ACP workflow, including attachment menus, slash commands, permission prompts, rich streamed agent updates, stop/cancel behavior, and review surfaces. That behavior should be ported deliberately into the native app rather than treated as present in `app/`.

See `docs/ARCHITECTURE.md` for the app structure and runtime model. See `docs/DESIGN.md` for the visual system and layout rules.

## Native 1.0 Direction

The accepted 1.0 direction is a native macOS client, recorded in [ADR 0001](adr/0001-native-macos-client.md). The native app owns `app/`; the Electrobun proof of concept has moved to `legacy/electrobun-app/` and remains reference-only.

The product target stays the same: a calm desktop AI coding agent centered on chat, transparent agent progress, permissions, review diffs, commit, and revert. `acp-mock-server/` remains active shared test infrastructure for native development and CI.

## Product Direction

The target product is a calm desktop AI coding agent with these core surfaces:

- A fixed project/sidebar area for workspaces, project groups, recent conversations, settings, and account context.
- A primary workspace for chat, agent plans, progress, code-change summaries, and empty or ready states.
- A bottom prompt composer for text, attachments, agent selection, and sending.
- A review surface for changed files, summaries, diffs, approvals, and commit actions.
- Optional tool tabs for review, terminal, and browser contexts when a task needs persistent inspection.

## Primary Workflows

The initial workflow should support:

1. Choose or continue a project conversation.
2. Ask the agent to inspect or change the codebase.
3. Watch the agent report plans, progress, and changed files.
4. Review diffs without losing the chat context.
5. Approve, revert, or commit changes when ready.

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
- Durable production-grade session history, production-grade attachment handling, mic input, and production approval policy.
