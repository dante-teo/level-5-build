# ACP Mock Server

A standalone ACP v1 mock agent for testing clients. It speaks newline-delimited JSON-RPC over stdio and keeps stdout protocol-clean.

## Native 1.0 role

This package is active shared test infrastructure, not Electrobun POC code. The native macOS 1.0 plan keeps `acp-mock-server/` at the repository root so native runtime and UI tests can run without Devin authentication. See `../docs/adr/0001-native-macos-client.md`.

Do not move this package into `legacy/` when the Electrobun app moves to `legacy/electrobun-app/`.

## Run

```bash
cd acp-mock-server
./start.sh
```

The server reads ACP messages from stdin and writes ACP responses/notifications to stdout. Logs go to stderr.

Use `./start.sh` when connecting an ACP client. It builds stale or missing TypeScript output with build logs redirected to stderr, then execs Node so stdout stays JSON-RPC-only. Avoid package-manager script wrappers for protocol clients because their banners can pollute ACP stdout.

For native macOS app development, use the TCP entrypoint:

```bash
./start-tcp.sh
```

`start-tcp.sh` listens on `127.0.0.1:58945` by default and uses the same mock ACP lifecycle as the stdio server. Override it with `ACP_MOCK_TCP_HOST` and `ACP_MOCK_TCP_PORT`.

Useful environment variables:

- `ACP_MOCK_DELAY_MS`: stream delay in milliseconds, default `120`
- `ACP_MOCK_STATE_PATH`: persisted session state path, default `.mock-acp-state.json`
- `ACP_MOCK_FIXED_IDS=1`: deterministic IDs for snapshots
- `ACP_MOCK_AUTH_REQUIRED=1`: require `authenticate` before session methods
- `ACP_MOCK_LOG=debug|info|silent`: logging level
- `ACP_MOCK_KEEPALIVE=1`: keep the process alive after stdin closes, useful for manual side-by-side launching

## App Mock Backend

The native desktop app is local-only by default. To run the current native shell against this mock backend for manual testing:

```bash
./script/run_mock_app.sh
```

In mock mode, DEBUG builds of the native app connect to an independently running TCP mock server. `script/run_mock_app.sh` starts `acp-mock-server/start-tcp.sh`, waits for the port, and launches the app with `LEVEL5_USE_ACP_MOCK=1`. The app initializes ACP, calls `session/list` so existing mock sessions appear in the native sidebar, creates a mock session only on first send from New Chat, sends `session/prompt`, replays existing sessions with `session/load`, and deletes rows with `session/delete`. Mock state is stored at `~/.level5-build/acp-mock-state.json` unless `ACP_MOCK_STATE_PATH` is set.

The retired Electrobun reference app still has its own manual mock command:

```bash
cd legacy/electrobun-app
bun run dev:mock
```

## ACP Surface Covered

- `initialize`
- `authenticate`
- `logout`
- `session/new`
- `session/load`
- `session/resume`
- `session/close`
- `session/list`
- `session/delete`
- `session/set_mode`
- `session/set_config_option`
- `session/prompt`
- `session/cancel`
- `_mock/list_models`
- `_mock/set_model`
- `_mock/list_skills`
- `_mock/list_slash_commands`
- `_mock/reset`

The mock streams:

- `session/update` message chunks
- `plan`
- `tool_call`
- `tool_call_update`
- `usage_update`
- `available_commands_update`
- `current_mode_update`
- `config_option_update`
- `session_info_update`
- client-bound `session/request_permission`

## Models

Clients can discover and set models in two ways:

1. ACP-native config options:

```json
{"jsonrpc":"2.0","id":4,"method":"session/set_config_option","params":{"sessionId":"sess_...","configId":"model","value":"mock-deep"}}
```

2. Mock extension methods:

```json
{"jsonrpc":"2.0","id":5,"method":"_mock/list_models","params":{"sessionId":"sess_..."}}
{"jsonrpc":"2.0","id":6,"method":"_mock/set_model","params":{"sessionId":"sess_...","model":"mock-fast"}}
```

Available models are `mock-fast`, `mock-pro`, and `mock-deep`.

By default, these are the only visible ACP config options. Older hidden config options remain accepted internally for compatibility, but they are not advertised to the app.

## Slash Commands

The default visible slash-command surface is intentionally small and app-relevant:

- `help`
- `plan`
- `review`
- `fix`
- `test`

Mock-only extension methods and hidden QA paths remain callable, but they are not advertised in initialization metadata or app-facing slash-command updates. Protocol clients that call `_mock/list_slash_commands` receive both the visible commands and the hidden QA commands for manual probing.

## Prompt Scenarios

Send text prompts containing these words or slash commands:

- `/plan`: streams plan updates
- `/review` or `review`: emits a review-style tool call and summary
- `/fix` or `edit`: emits read/edit tool calls and a diff
- `/test` or `build`: emits execute-style tool output
- `web` or `fetch`: hidden QA trigger for fetch-style tool output
- `skills`: hidden QA trigger for mock skill text
- `/mode code`: hidden compatibility path for mode updates
- `permission`: sends `session/request_permission`
- `fail`: emits a failed tool call
- `refuse`: returns `stopReason: "refusal"`
- `max tokens`: returns `stopReason: "max_tokens"`

## Smoke Test

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":true,"writeTextFile":true},"terminal":true}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"session/new","params":{"cwd":"'"$PWD"'","mcpServers":[]}}}' \
  | ./start.sh
```

For prompt testing, use the `sessionId` returned by `session/new`.

## Verification

```bash
CI=true pnpm install --frozen-lockfile
CI=true pnpm run build
CI=true pnpm run typecheck
CI=true pnpm test
```

From the repo root, also check the helper scripts:

```bash
bash -n acp-mock-server/start.sh
bash -n acp-mock-server/start-tcp.sh
bash -n script/build_and_run.sh
bash -n script/run_mock_app.sh
```

The native SwiftPM suite normally skips the subprocess integration. Run `LEVEL5_RUN_ACP_PROCESS_INTEGRATION=1 swift test` from `app/` when you need to verify `AcpProcessTransport` against the real stdio mock server.
