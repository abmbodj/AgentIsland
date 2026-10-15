# Chat model, effort and mode controls

## Problem

Chats started from the island's composer run `claude -p` or `codex exec` with no model, effort or mode flags (`core/island-core/src/chat.rs`, `command()`). Codex is also pinned to `sandbox_mode="workspace-write"`. The user can pick the agent but nothing about how it runs.

## Goal

From the composer, and on every follow-up turn, the user picks:

- **Model**: the live list each installed CLI reports, so new models appear without an app update.
- **Effort / reasoning**: only the levels the chosen model supports.
- **Mode**: Claude permission mode, or Codex sandbox.
- **Fast** (Claude only): on models that support it.

Every picker except Codex mode has a **Default** entry that passes no flag, so the user's CLI config applies.

## Decisions

| # | Decision |
|---|---|
| D1 | "Default" passes no flag; the CLI config decides. |
| D2 | Model and effort lists come live from the CLIs (see Discovery). Nothing is hardcoded. |
| D3 | Lists refresh in the background at app launch, and again when the composer opens if the cache is over an hour old. The cached list shows meanwhile. |
| D4 | Claude modes: Default, Plan, Accept edits, Auto, Bypass. `manual` and `dontAsk` are excluded: a headless `-p` turn can't answer prompts, so they would quietly block tools. Plan writes a plan and ends the turn; the user switches mode and sends a follow-up to build. |
| D5 | Codex mode is its sandbox: Read-only, Workspace write, Full access. Workspace write is preselected (today's behavior); the hardcoded `-c sandbox_mode` goes away. Codex has no Default entry for mode. |
| D6 | Settings are per turn: the chips also sit under the follow-up composer, and each chat remembers its last settings. |
| D7 | Last choices are remembered per agent across launches (UserDefaults). A remembered model no longer in the list falls back to Default. |
| D8 | When the model changes: effort snaps down to the highest level the model supports; an unsupported mode (Auto without `supportsAutoMode`) or Fast (without `supportsFastMode`) returns to Default/off. Pickers list only supported values. |
| D9 | Claude fast mode toggle, shown only for models with `supportsFastMode`. |
| D10 | Layout: a **Mode** chip and a **Model·Effort** chip (its menu holds Model, Effort and Fast). In a conversation the agent toggle and folder are absent. |
| D11 | The user's transcript message gets a faint caption ("Plan · Opus 5.5 · High") on the first turn and whenever settings changed since the previous turn; a change back to all-Default is captioned "Default". |
| D12 | Terminal handoffs (`terminal`, `iterm`, `ghostty`) resume with the chat's last flags. Desktop handoffs are unchanged (the apps take no flags). |
| D13 | Bypass and Full access are selectable and remembered with no confirmation; the chip shows a neutral `exclamationmark.triangle` while active (never amber, which means "needs you"). |

## Architecture

The Rust core owns discovery and flag-building; Swift renders. `command()` is the single choke point every turn passes through, and the core already resolves CLI paths (`Tools.find`, `pr::search_path`).

### Discovery (`core/island-core/src/options.rs`, new)

- **Claude:** spawn `claude -p --input-format stream-json --output-format stream-json --verbose`, write `{"type":"control_request","request_id":"1","request":{"subtype":"initialize"}}`, read stdout lines until the `control_response`, then kill the process group. Keep `response.response.models[]` minus the `value == "default"` entry. Per model keep `value`, `displayName`, `supportedEffortLevels` (absent = effort unsupported), `supportsAutoMode`, `supportsFastMode`. A 20s timeout fails the fetch.
- **Codex:** `codex debug models`, parse JSON, keep models with `visibility == "list"`: `slug`, `display_name` (fall back to slug), `supported_reasoning_levels[].effort`.
- Results are normalised to one shape per agent:
  `{models: [{id, name, efforts: [String], auto: bool, fast: bool}], error, loading}`.
- An in-memory cache per agent on `Core`. Bridge op `chatOptions {refresh: bool}` returns the cache immediately; when `refresh` is set and the cache is missing or older than an hour, it starts one background fetch per agent (never two at once). Swift calls it with `refresh` at launch and on composer open, and re-polls while a fetch is in flight.
- A missing CLI or failed fetch keeps the previous list and records `error`; with no list, the pickers show only Default.

### Turn settings (`chat.rs`)

- `Settings {model, effort, mode, fast}`, all `Option`. `chatStart` and `chatSend` take an optional `settings` object; absent = all Default.
- Validation at the boundary: `mode` must be one of the fixed values for the agent (D4/D5) or the call fails; `model` and `effort` must be non-empty, contain no whitespace or control characters, and not start with `-`. Values are passed as separate argv elements, never through a shell.
- Flags:
  - Claude: `--model M`, `--effort E`, `--permission-mode P`, `--settings {"fastMode":true}` when fast.
  - Codex: `-m M`, `-c model_reasoning_effort="E"`, `-s S` (`S` defaults to `workspace-write` when unset).
  - Flags precede `resume`/`--resume` handling exactly as today, and the prompt stays after `--`.
- The chat stores `last: Option<Settings>`. `Transcript::user` takes an optional caption; `turn` sets it when this is the first turn or the settings differ from `last`. Caption text: the non-default values among mode, model display name, effort, "Fast", joined by " · "; empty (no caption) if all Default.
- `chatList` / `transcript` expose `settings` so the follow-up composer starts from the chat's last choices.

### Composer UI (Swift: `ChatView.swift`, `Chat.swift`)

- `PanelModel` holds `options: [agent: AgentOptions]` and the composer's current `Settings`, loaded from UserDefaults per agent (key `composerSettings.<agent>`), validated against the list per D7/D8.
- Two native `Menu` chips beside the agent toggle, styled like the folder chip (11pt, secondary ink, 22pt high, `IslandButtonStyle`):
  - **Mode chip:** label is the mode name; Bypass/Full access prefix `exclamationmark.triangle`.
  - **Model chip:** label "Model · Effort" (only the non-default parts; "Default" if both default), plus `bolt.fill` when Fast is on. Menu sections: Model (Default + list), Effort (Default + the model's levels), Fast toggle (when supported).
- Changing a value applies D8 and persists. Sending passes `settings` with `chatStart` / `chatSend`.
- In a conversation the same two chips render under the composer, seeded from the chat's `settings`; changes there apply to that chat's next turn and also persist as the agent's remembered choices.
- The user message's `caption` renders under the message block at caption size, tertiary ink.
- VoiceOver: chips are labelled "Mode: Plan", "Model: Opus 5.5, effort High"; menu items carry checkmarks for selection.

### Handoff (`ChatHandoff.swift`)

`claim_handoffs` includes the chat's last settings; `resumeCommand` appends the same flags (built by the core and passed as an `args` array in the claim, so Swift does not duplicate the mapping) for terminal targets only.

## Error handling

- Discovery failure: previous list kept, error recorded; pickers fall back to Default only. No user-visible alert (the chips simply have fewer choices).
- Invalid settings over the bridge: `chatStart`/`chatSend` return an error that the composer shows as it does today.
- A CLI rejecting a flag (e.g. an old CLI without `--effort`): the turn fails with its stderr, as any failed turn does today.

## Testing

- Rust unit tests: flag-building for each agent across Default / set / fast / each mode; validation rejects bad mode and dash-prefixed values; caption-on-change rule.
- Parser tests for both discovery outputs against fixtures captured from the real CLIs (`fixtures/`).
- A fake-agent test via `AGENT_ISLAND_TOOLS` that records argv and asserts the flags the CLI receives on start and resume.
- `xcodebuild` on `macos/`, then a manual check: lists populate, snapping works, Plan then switch-to-build in one chat, terminal handoff carries flags.

## Out of scope

- Model lists for sessions the island only observes (they run in the user's own CLI or app).
- Codex plan mode (`codex exec` has none).
- Claude `manual` / `dontAsk` modes.
