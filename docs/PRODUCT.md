# Product

This app is a desktop-native AI coding agent environment. It is intended to feel like a focused local workbench for asking an agent to understand, change, review, and verify a codebase.

## Current state

`app/` is an early Electrobun desktop app shell with a mock-agent chat workflow: a frameless window with a native-feeling React workspace, a light translucent sidebar, placeholder New chat and Settings controls, a floating app capsule, bundled product fonts, and typed Bun-side capabilities exposed through RPC.

The first shipped agent path is intentionally local and mock-only. On app open, the workspace shows a centered prompt composer and does not start or initialize ACP. The first valid Send lazily spawns `acp-mock-server/`, creates a mock ACP session, sends the prompt, and renders streamed mock messages, plans, tool calls, permission requests, errors, and stop reasons. Folder selection is optional; when unset, the mock ACP session uses the user's home directory as its cwd behind the scenes.

See `docs/ARCHITECTURE.md` for the app structure and runtime model. See `docs/DESIGN.md` for the visual system and layout rules.

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
- Real non-mock ACP/provider integration, persistent session history UI, attachments, mic input, and production approval policy.
