# Product

This app is a desktop-native AI coding agent environment. It is intended to feel like a focused local workbench for asking an agent to understand, change, review, and verify a codebase.

## Current state

`app/` is an early Electrobun desktop app shell with a mock-agent chat workflow: a frameless window with a native-feeling React workspace, a light translucent sidebar with mock session management, New chat and Settings controls, a floating app capsule, bundled product fonts, and typed Bun-side capabilities exposed through RPC. The composer's `+` menu lets a user attach a file/folder path, and browse/insert slash commands and skills sourced from the mock agent, so this UI surface can be exercised before real attachment/skill handling exists.

The first shipped agent path is intentionally local and mock-only. On app open, the workspace shows a centered prompt composer and initializes the bundled `acp-mock-server/` only far enough to list persisted sessions; it does not create a new ACP session until the first valid Send. Sending a prompt creates or resumes a mock ACP session and renders streamed mock messages, plans, tool calls, permission requests, errors, and stop reasons.

Folder selection is optional. The empty composer footer exposes a searchable `Choose project` menu built from current mock sessions plus the selected folder, with actions to choose a folder or leave project context unset. When no project is selected, the mock ACP session still uses the user's home directory as its cwd behind the scenes so the local mock agent can operate globally, but that home-directory fallback is not presented as a recent project.

The sidebar shows an `All chats` section populated from ACP `session/list` on app open and updated as chats are created, loaded, or deleted. Selecting a chat restores the cached mock transcript when available, or reloads persisted messages from ACP after relaunch; right-clicking a chat exposes delete with confirmation. This is a local development affordance, not the final production session store.

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
- Real non-mock ACP/provider integration, durable production-grade session history, production-grade attachment handling (the composer can reference a local file/folder path as a mock ACP resource link today, but does not read, embed, or upload file contents), mic input, and production approval policy.
