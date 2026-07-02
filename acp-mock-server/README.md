# ACP Mock Server

A standalone ACP v1 mock agent for testing clients. It speaks newline-delimited JSON-RPC over stdio and keeps stdout protocol-clean.

## Run

```bash
cd acp-mock-server
./start.sh
```

The server reads ACP messages from stdin and writes ACP responses/notifications to stdout. Logs go to stderr.

Use `./start.sh` when connecting an ACP client. It is intentionally a direct executable wrapper so stdout stays JSON-RPC-only; avoid `bun run` wrappers for protocol clients because some Bun versions echo script banners before process output.

Useful environment variables:

- `ACP_MOCK_DELAY_MS`: stream delay in milliseconds, default `120`
- `ACP_MOCK_STATE_PATH`: persisted session state path, default `.mock-acp-state.json`
- `ACP_MOCK_FIXED_IDS=1`: deterministic IDs for snapshots
- `ACP_MOCK_AUTH_REQUIRED=1`: require `authenticate` before session methods
- `ACP_MOCK_LOG=debug|info|silent`: logging level
- `ACP_MOCK_KEEPALIVE=1`: keep the process alive after stdin closes, useful for manual side-by-side launching

## Manual App + Mock Run

From the repository root:

```bash
./scripts/start-app-with-acp-mock.sh
```

This starts `app` with `bun run dev:hmr` and starts the ACP mock server in parallel. Press `Ctrl-C` to stop both.

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

## Prompt Scenarios

Send text prompts containing these words or slash commands:

- `/plan`: streams plan updates
- `/fix` or `edit`: emits read/edit tool calls and a diff
- `/test` or `build`: emits execute-style tool output
- `/web`: emits fetch-style tool output
- `/skills`: lists mock skills
- `/mode code`: switches mode and updates config
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
bun test
bunx tsc --noEmit -p tsconfig.json
```

From the repo root, also check the helper scripts:

```bash
bash -n scripts/start-app-with-acp-mock.sh
bash -n acp-mock-server/start.sh
```
