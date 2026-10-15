# Chat Model, Effort and Mode Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let island chats pick model, effort/reasoning, mode and (Claude) fast mode per turn, from live lists each installed CLI reports.

**Architecture:** A new `options.rs` in the Rust core asks each CLI for its models (Claude: `initialize` control request; Codex: `codex debug models`), caches them, and serves them over a `chatOptions` bridge op. `chat.rs` gains a `Settings` value that is validated at the bridge and turned into CLI flags in `command()`, the single place every turn passes through. Swift shows two native menu chips under the composer, remembers choices per agent, and fits them to what the chosen model supports.

**Tech Stack:** Rust (`island-core`, serde_json, libc), Swift/SwiftUI (macOS 14), Claude Code CLI 2.1.299, Codex CLI 0.162.1.

**Spec:** `docs/superpowers/specs/2026-10-15-chat-model-controls-design.md`

## Global Constraints

- Rust commands run with the rustup toolchain on PATH: `export PATH="/opt/homebrew/opt/rustup/bin:$PATH"` then `cd core && cargo test`.
- macOS build check: `cd macos && xcodebuild -project AgentIsland.xcodeproj -scheme AgentIsland -configuration Debug -derivedDataPath ../build/dd build -quiet`. Don't install a branch build (AGENTS.md).
- Commit on the current branch `ab/model-reasoning-controls-17d163`, never on `main`. End commit messages with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- "Default" passes no flag; the CLI config decides (D1). Codex mode has no Default: unset means `workspace-write` (D5).
- Claude modes offered: `plan`, `acceptEdits`, `auto`, `bypassPermissions`. Never `manual` or `dontAsk` (D4). Codex modes: `read-only`, `workspace-write`, `danger-full-access`.
- Values reach CLIs only as separate argv elements, never through a shell string the core builds. Model/effort values: non-empty, no whitespace or control characters, not starting with `-`.
- The Claude discovery probe runs with `--settings {"disableAllHooks":true}` so it never fires the user's hooks (including Agent Island's own, which would otherwise register a phantom session).
- Fast mode is `--settings {"fastMode":true}` (verified: headless init reports `fast_mode_state: on`).
- UI copy: no em dashes. Amber and green are never used for these controls; the danger glyph is neutral (D13).
- Lists refresh at app launch and on composer/chat open when older than one hour (D3).

## Review Focus

1. **The remembered model vanished from the CLI's list** (renamed or retired): the chip falls back to Default rather than sending a model the CLI rejects. Pinned in Task 5's self-check.
2. **The panel opens before the first fetch finishes**: remembered choices stay as they are (not wiped to Default) while the list is empty and loading. Pinned in Task 5's self-check.
3. **The Claude probe hangs** (not logged in, waiting on something): it is killed after the timeout, the error is recorded, and the next open retries instead of waiting an hour. Pinned in Task 2's hang test.
4. **A settings value that looks like a flag** (`--dangerously-skip-permissions` as a model): refused at the bridge and no chat or user entry is created. Pinned in Task 3's validation test.
5. **Switching agents in the new-chat composer**: Claude and Codex each keep their own remembered choices, and a Claude-only setting (fast, Claude modes) never reaches Codex. Pinned in Task 3 (core refuses `fast` and `plan` for Codex) and Task 5 (per-agent keys).

---

### Task 1: Discovery parsers

**Files:**
- Create: `core/island-core/src/options.rs`
- Modify: `core/island-core/src/lib.rs` (add `pub mod options;` after `pub mod chat;`)
- Fixtures (already captured from the real CLIs and committed with this plan): `fixtures/options/claude-initialize.jsonl`, `fixtures/options/codex-models.json`
- Test: `core/island-core/tests/options.rs`

**Interfaces:**
- Produces: `pub struct ModelOption { pub id: String, pub name: String, pub efforts: Vec<String>, pub auto: bool, pub fast: bool }` (derives `Debug, Clone, Serialize, PartialEq`); `pub fn parse_claude(response: &Value) -> Vec<ModelOption>` taking the inner `response.response` object; `pub fn parse_codex(v: &Value) -> Vec<ModelOption>`.

- [ ] **Step 1: Write the failing tests**

`core/island-core/tests/options.rs`:

```rust
//! Model menus: parsing what each CLI reports, and fetching it in the background.
use island_core::options::{parse_claude, parse_codex};
use serde_json::Value;

fn fx(name: &str) -> String {
    format!("{}/../../fixtures/options/{name}", env!("CARGO_MANIFEST_DIR"))
}

fn read(name: &str) -> Value {
    serde_json::from_str(std::fs::read_to_string(fx(name)).unwrap().trim()).unwrap()
}

#[test]
fn claude_initialize_lists_models_with_their_effort_levels() {
    let v = read("claude-initialize.jsonl");
    let m = parse_claude(&v["response"]["response"]);
    let ids: Vec<&str> = m.iter().map(|m| m.id.as_str()).collect();
    assert_eq!(ids, ["opus", "fable", "claude-haiku-4-5-20251001", "claude-opus-4-6"], "Claude's own \"default\" entry is dropped");
    assert_eq!(m[0].name, "Opus 5.5");
    assert!(m[0].fast && m[0].auto);
    assert!(!m[1].fast);
    assert!(m[2].efforts.is_empty(), "a model without effort support lists no levels");
    assert_eq!(m[3].efforts, ["low", "medium", "high", "max"]);
}

#[test]
fn codex_models_keep_only_listed_ones_with_their_reasoning_levels() {
    let m = parse_codex(&read("codex-models.json"));
    let ids: Vec<&str> = m.iter().map(|m| m.id.as_str()).collect();
    assert_eq!(ids, ["gpt-6-sol", "gpt-6-luna"], "hidden models are left out");
    assert_eq!(m[0].name, "GPT-6-Sol");
    assert_eq!(m[0].efforts.last().map(String::as_str), Some("ultra"));
    assert_eq!(m[1].efforts.last().map(String::as_str), Some("max"));
    assert!(!m[0].fast && !m[0].auto);
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd core && cargo test --test options`
Expected: compile error `unresolved import island_core::options`.

- [ ] **Step 3: Implement the parsers**

`core/island-core/src/options.rs`:

```rust
//! Model menus for the composer: what each installed CLI says it can run.
use serde::Serialize;
use serde_json::Value;

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct ModelOption {
    /// The value passed to `--model` / `-m`.
    pub id: String,
    pub name: String,
    /// Effort or reasoning levels this model accepts, lowest first; empty when it takes none.
    pub efforts: Vec<String>,
    /// Claude: the model supports `--permission-mode auto`.
    pub auto: bool,
    /// Claude: the model supports fast mode.
    pub fast: bool,
}

fn strings(v: &Value) -> Vec<String> {
    v.as_array().into_iter().flatten().filter_map(|s| s.as_str().map(str::to_string)).collect()
}

/// Models from Claude Code's `initialize` control response, minus its own "default" entry
/// (the composer has its own Default, which passes no flag).
pub fn parse_claude(response: &Value) -> Vec<ModelOption> {
    response["models"].as_array().into_iter().flatten()
        .filter_map(|m| {
            let id = m["value"].as_str().filter(|v| !v.is_empty() && *v != "default")?;
            Some(ModelOption {
                id: id.into(),
                name: m["displayName"].as_str().unwrap_or(id).into(),
                efforts: strings(&m["supportedEffortLevels"]),
                auto: m["supportsAutoMode"] == true,
                fast: m["supportsFastMode"] == true,
            })
        })
        .collect()
}

/// Models from `codex debug models` that Codex itself shows in its picker.
pub fn parse_codex(v: &Value) -> Vec<ModelOption> {
    v["models"].as_array().into_iter().flatten()
        .filter(|m| m["visibility"] == "list")
        .filter_map(|m| {
            let id = m["slug"].as_str().filter(|s| !s.is_empty())?;
            Some(ModelOption {
                id: id.into(),
                name: m["display_name"].as_str().unwrap_or(id).into(),
                efforts: m["supported_reasoning_levels"].as_array().into_iter().flatten()
                    .filter_map(|l| l["effort"].as_str().map(str::to_string)).collect(),
                auto: false,
                fast: false,
            })
        })
        .collect()
}
```

Add `pub mod options;` to `core/island-core/src/lib.rs` after `pub mod chat;`.

- [ ] **Step 4: Run to verify they pass**

Run: `cd core && cargo test --test options`
Expected: 2 passed.

- [ ] **Step 5: Commit**

```bash
git add core/island-core/src/options.rs core/island-core/src/lib.rs core/island-core/tests/options.rs
git commit -m "Parse model lists from Claude Code and Codex"
```

---

### Task 2: Background fetch, cache and `chatOptions` op

**Files:**
- Modify: `core/island-core/src/options.rs` (append fetch + cache)
- Modify: `core/island-core/src/pr.rs:13` (add `#[derive(Clone)]` to `Tools`)
- Modify: `core/island-core/src/server.rs:74-77` (field), `:429` (init), op table near `:484`
- Test: `core/island-core/tests/options.rs` (append)

**Interfaces:**
- Consumes: `parse_claude`, `parse_codex`, `ModelOption` (Task 1); `crate::pr::Tools::find`, `crate::pr::search_path`.
- Produces: `pub fn fetch(tools: &Tools, agent: &str, timeout: Duration) -> Result<Vec<ModelOption>, String>`; `#[derive(Clone, Default)] pub struct Options` with `pub fn get(&self, tools: &Tools, refresh: bool) -> Value` returning `{"claude": {"models": [ModelOption], "error": String|null, "loading": bool}, "codex": {...}}`. Bridge op `{"op": "chatOptions", "refresh": bool}` returns that value.

- [ ] **Step 1: Write the failing tests**

Append to `core/island-core/tests/options.rs`:

```rust
use island_core::options::{fetch, Options};
use island_core::pr::Tools;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::time::{Duration, Instant};

fn bin(name: &str, scripts: &[(&str, String)]) -> (Tools, PathBuf) {
    let root = std::env::temp_dir().join(format!("island-options-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("bin")).unwrap();
    for (n, body) in scripts {
        let p = root.join("bin").join(n);
        std::fs::write(&p, format!("#!/bin/sh\n{body}\n")).unwrap();
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    (Tools { dirs: vec![root.join("bin")] }, root)
}

fn settled(opts: &Options, tools: &Tools) -> Value {
    let end = Instant::now() + Duration::from_secs(10);
    loop {
        let v = opts.get(tools, false);
        if v["claude"]["loading"] == false && v["codex"]["loading"] == false {
            return v;
        }
        assert!(Instant::now() < end, "never settled: {v}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn options_fetch_both_agents_in_the_background_and_cache_them() {
    // The fake claude answers initialize, then keeps running like the real one: the fetch must kill it.
    let claude = format!("echo \"$@\" > \"$0.args\"\nread l\necho \"$l\" > \"$0.in\"\necho 'not json'\ncat '{}'\nsleep 30", fx("claude-initialize.jsonl"));
    let codex = format!("cat '{}'", fx("codex-models.json"));
    let (tools, root) = bin("ok", &[("claude", claude), ("codex", codex)]);
    let opts = Options::default();
    assert_eq!(opts.get(&tools, true)["claude"]["loading"], true);
    let v = settled(&opts, &tools);
    assert_eq!(v["claude"]["models"][0]["id"], "opus");
    assert_eq!(v["codex"]["models"].as_array().unwrap().len(), 2);
    assert!(v["claude"]["error"].is_null());
    let args = std::fs::read_to_string(root.join("bin/claude.args")).unwrap();
    assert!(args.contains("disableAllHooks"), "the probe must not fire the user's hooks: {args}");
    assert!(std::fs::read_to_string(root.join("bin/claude.in")).unwrap().contains("\"initialize\""));
    assert_eq!(opts.get(&tools, true)["claude"]["loading"], false, "a fresh cache starts no new fetch");
}

#[test]
fn a_missing_cli_reports_an_error_and_is_retried_on_the_next_refresh() {
    let (tools, _) = bin("missing", &[]);
    let opts = Options::default();
    opts.get(&tools, true);
    let v = settled(&opts, &tools);
    assert!(v["codex"]["models"].as_array().unwrap().is_empty());
    assert!(v["codex"]["error"].as_str().unwrap().contains("codex"));
    assert_eq!(opts.get(&tools, true)["codex"]["loading"], true, "a failed fetch is not cached for an hour");
}

#[test]
fn a_probe_that_never_answers_is_killed_at_the_timeout() {
    let (tools, _) = bin("hang", &[("claude", "sleep 30".to_string())]);
    let start = Instant::now();
    let err = fetch(&tools, "claude", Duration::from_millis(300)).unwrap_err();
    assert!(start.elapsed() < Duration::from_secs(5), "took {:?}", start.elapsed());
    assert!(err.contains("too long"), "{err}");
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd core && cargo test --test options`
Expected: compile error, `fetch` and `Options` not found in `island_core::options`.

- [ ] **Step 3: Make `Tools` cloneable**

In `core/island-core/src/pr.rs`, change line 13-14 from `pub struct Tools {` to:

```rust
#[derive(Clone)]
pub struct Tools {
```

- [ ] **Step 4: Implement fetch and cache**

Append to `core/island-core/src/options.rs`, and extend its imports to:

```rust
use crate::pr::Tools;
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::process::CommandExt;
use std::process::{ChildStdout, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
```

```rust
const AGENTS: [&str; 2] = ["claude", "codex"];
const STALE: Duration = Duration::from_secs(3600);
const TIMEOUT: Duration = Duration::from_secs(20);
const INITIALIZE: &str = "{\"type\":\"control_request\",\"request_id\":\"island-options\",\"request\":{\"subtype\":\"initialize\"}}\n";

/// Run `agent args`, write `input`, and hand stdout to `read`; the process group is killed afterwards
/// (Claude keeps waiting for more input) or at `timeout`.
fn run(tools: &Tools, agent: &str, args: &[&str], input: &str, timeout: Duration,
       read: fn(BufReader<ChildStdout>) -> Result<Vec<ModelOption>, String>) -> Result<Vec<ModelOption>, String> {
    let bin = tools.find(agent).ok_or_else(|| format!("Could not find {agent} on this Mac."))?;
    let mut child = Command::new(&bin).args(args).current_dir(std::env::temp_dir())
        .env("PATH", crate::pr::search_path(&bin))
        .stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::null()).process_group(0)
        .spawn().map_err(|e| e.to_string())?;
    let pid = child.id() as i32;
    let _ = child.stdin.as_mut().map(|s| s.write_all(input.as_bytes()));
    let out = BufReader::new(child.stdout.take().unwrap());
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || { let _ = tx.send(read(out)); });
    let r = rx.recv_timeout(timeout).unwrap_or_else(|_| Err(format!("{agent} took too long to list its models.")));
    // Not reaped yet, so the pid can't have been reused.
    unsafe { libc::kill(-pid, libc::SIGKILL) };
    let _ = child.wait();
    r
}

fn read_claude(out: BufReader<ChildStdout>) -> Result<Vec<ModelOption>, String> {
    for line in out.lines().map_while(Result::ok) {
        let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
        if v["type"] == "control_response" {
            if v["response"]["subtype"] != "success" {
                return Err(v["response"]["error"].as_str().unwrap_or("Claude Code refused to list its models.").into());
            }
            return Ok(parse_claude(&v["response"]["response"]));
        }
    }
    Err("Claude Code exited without listing its models.".into())
}

fn read_codex(mut out: BufReader<ChildStdout>) -> Result<Vec<ModelOption>, String> {
    let mut s = String::new();
    out.read_to_string(&mut s).map_err(|e| e.to_string())?;
    let v: Value = serde_json::from_str(&s).map_err(|_| "Codex printed an unexpected model list.".to_string())?;
    Ok(parse_codex(&v))
}

/// Ask an installed CLI which models it can run.
pub fn fetch(tools: &Tools, agent: &str, timeout: Duration) -> Result<Vec<ModelOption>, String> {
    match agent {
        "claude" => run(tools, "claude", &["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--settings", "{\"disableAllHooks\":true}"], INITIALIZE, timeout, read_claude),
        "codex" => run(tools, "codex", &["debug", "models"], "", timeout, read_codex),
        other => Err(format!("Unknown agent {other}")),
    }
}

#[derive(Default)]
struct Cached {
    models: Vec<ModelOption>,
    error: Option<String>,
    /// Set only by a successful fetch, so a failure is retried on the next refresh.
    fetched: Option<Instant>,
    loading: bool,
}

/// Each agent's last model list, refreshed in the background.
#[derive(Clone, Default)]
pub struct Options(Arc<Mutex<HashMap<&'static str, Cached>>>);

impl Options {
    /// The cached menus; with `refresh`, a missing or hour-old list starts one background fetch.
    pub fn get(&self, tools: &Tools, refresh: bool) -> Value {
        let mut g = self.0.lock().unwrap_or_else(|e| e.into_inner());
        let mut out = json!({});
        for agent in AGENTS {
            let c = g.entry(agent).or_default();
            if refresh && !c.loading && c.fetched.map_or(true, |t| t.elapsed() > STALE) {
                c.loading = true;
                let (cache, tools) = (self.0.clone(), tools.clone());
                std::thread::spawn(move || {
                    let r = fetch(&tools, agent, TIMEOUT);
                    let mut g = cache.lock().unwrap_or_else(|e| e.into_inner());
                    let c = g.entry(agent).or_default();
                    c.loading = false;
                    match r {
                        Ok(m) => { c.models = m; c.error = None; c.fetched = Some(Instant::now()); }
                        Err(e) => c.error = Some(e),
                    }
                });
            }
            out[agent] = json!({"models": c.models, "error": c.error, "loading": c.loading});
        }
        out
    }
}
```

- [ ] **Step 5: Wire the bridge op**

In `core/island-core/src/server.rs`:

```rust
pub struct Core {
    inner: Arc<Inner>,
    chats: crate::chat::Chats,
    options: crate::options::Options,
}
```

At line ~429: `Ok(Core { inner, chats: Default::default(), options: Default::default() })`

In the op match, right before `"chatStart" => {`:

```rust
            "chatOptions" => Ok(self.options.get(&self.tools(), req["refresh"] == true)),
```

- [ ] **Step 6: Run to verify they pass**

Run: `cd core && cargo test --test options`
Expected: 5 passed.

- [ ] **Step 7: Commit**

```bash
git add core/island-core/src/options.rs core/island-core/src/pr.rs core/island-core/src/server.rs core/island-core/tests/options.rs
git commit -m "Fetch and cache each CLI's model list behind a chatOptions op"
```

---

### Task 3: Turn settings become CLI flags

**Files:**
- Modify: `core/island-core/src/chat.rs` (new `Settings`; `command()` at `:299`; `start`, `send`, `turn`; `State`)
- Modify: `core/island-core/src/server.rs` (`chatStart`, `chatSend` ops)
- Modify: `core/island-core/tests/chat.rs` (existing 32 `chats.start(` / `chats.send(` calls gain a trailing `Settings::default()` argument)
- Test: `core/island-core/tests/chat.rs` (append)

**Interfaces:**
- Produces: `#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)] pub struct Settings { pub model: Option<String>, pub effort: Option<String>, pub mode: Option<String>, #[serde(default)] pub fast: bool, pub name: Option<String> }` with `pub fn validate(&self, agent: &str) -> Result<(), String>`, `pub fn args(&self, agent: &str) -> Vec<String>`. `name` is the model's display name, used only for captions (Task 4), never for flags.
- Changed signatures: `Chats::start(&self, tools: &Tools, agent: &str, cwd: &str, text: &str, settings: Settings) -> Result<u64, String>`, `Chats::send(&self, tools: &Tools, id: u64, text: &str, settings: Settings) -> Result<(), String>`. Bridge `chatStart` / `chatSend` accept an optional `"settings"` object with those fields.

- [ ] **Step 1: Update existing call sites**

```bash
perl -0pi -e 's/(chats\.(?:start|send)\((?:[^()]|\((?:[^()]|\([^()]*\))*\))*)\)/$1, Settings::default())/g' core/island-core/tests/chat.rs
grep -c "Settings::default())" core/island-core/tests/chat.rs
```

Expected: `32` (verified against the current file: the balanced-paren match closes each call's own argument list, e.g. `chats.start(&tools, "claude", root.to_str().unwrap(), "say hello", Settings::default()).unwrap()`). Then add `use island_core::chat::Settings;` under `use island_core::chat::Chats;`.

- [ ] **Step 2: Write the failing tests**

Append to `core/island-core/tests/chat.rs`:

```rust
fn s(model: Option<&str>, effort: Option<&str>, mode: Option<&str>, fast: bool) -> Settings {
    Settings { model: model.map(Into::into), effort: effort.map(Into::into), mode: mode.map(Into::into), fast, name: None }
}

#[test]
fn claude_settings_become_flags_on_start_and_on_resume() {
    let (tools, root) = fixture("claude-flags", &[("claude", CLAUDE)]);
    let chats = Chats::default();
    let id = chats.start(&tools, "claude", root.to_str().unwrap(), "plan it", s(Some("opus"), Some("high"), Some("plan"), true)).unwrap();
    wait_for(&chats, id, "idle");
    chats.send(&tools, id, "go", s(None, None, Some("acceptEdits"), false)).unwrap();
    wait_for(&chats, id, "idle");
    let args = std::fs::read_to_string(root.join("bin/claude.args")).unwrap();
    let lines: Vec<&str> = args.lines().collect();
    assert!(lines[0].contains("--model opus --effort high --permission-mode plan --settings {\"fastMode\":true} -- plan it"), "{args}");
    assert!(lines[1].contains("--permission-mode acceptEdits --resume sess-1 -- go"), "{args}");
    assert!(!lines[1].contains("--model"), "Default passes no flag: {args}");
}

#[test]
fn codex_defaults_to_workspace_write_and_maps_model_and_reasoning() {
    let script = r#"echo "$@" >> "$0.args"
echo '{"type":"thread.started","thread_id":"th-1"}'
echo '{"type":"turn.completed"}'"#;
    let (tools, root) = fixture("codex-flags", &[("codex", script)]);
    let chats = Chats::default();
    let id = chats.start(&tools, "codex", root.to_str().unwrap(), "hi", Settings::default()).unwrap();
    wait_for(&chats, id, "idle");
    chats.send(&tools, id, "more", s(Some("gpt-6-sol"), Some("xhigh"), Some("danger-full-access"), false)).unwrap();
    wait_for(&chats, id, "idle");
    let args = std::fs::read_to_string(root.join("bin/codex.args")).unwrap();
    let lines: Vec<&str> = args.lines().collect();
    assert_eq!(lines[0], "exec --json --skip-git-repo-check -s workspace-write -- hi");
    assert_eq!(lines[1], "exec --json --skip-git-repo-check -m gpt-6-sol -c model_reasoning_effort=\"xhigh\" -s danger-full-access resume th-1 -- more");
}

#[test]
fn settings_that_could_smuggle_flags_or_unknown_modes_are_refused() {
    let (tools, root) = fixture("bad-settings", &[("claude", CLAUDE), ("codex", "exit 0")]);
    let dir = root.to_str().unwrap();
    let chats = Chats::default();
    for bad in [
        s(Some("--dangerously-skip-permissions"), None, None, false),
        s(None, Some("high max"), None, false),
        s(Some(""), None, None, false),
        s(None, None, Some("manual"), false),
        s(None, None, Some("dontAsk"), false),
    ] {
        assert!(chats.start(&tools, "claude", dir, "x", bad.clone()).is_err(), "{bad:?}");
    }
    assert!(chats.start(&tools, "codex", dir, "x", s(None, None, Some("plan"), false)).is_err());
    assert!(chats.start(&tools, "codex", dir, "x", s(None, None, None, true)).is_err(), "fast is Claude only");
    assert!(chats.list().as_array().unwrap().is_empty(), "a refused start leaves no chat behind");

    let id = chats.start(&tools, "claude", dir, "ok", Settings::default()).unwrap();
    wait_for(&chats, id, "idle");
    assert!(chats.send(&tools, id, "x", s(None, None, Some("manual"), false)).is_err());
    assert_eq!(kinds(&chats.transcript(id, 0).unwrap()).iter().filter(|k| *k == "user").count(), 1, "a refused send adds no message");
}
```

- [ ] **Step 3: Run to verify they fail**

Run: `cd core && cargo test --test chat`
Expected: compile error, `Settings` not found in `island_core::chat`.

- [ ] **Step 4: Implement `Settings`**

In `core/island-core/src/chat.rs`, change `use serde::Serialize;` to `use serde::{Deserialize, Serialize};` and add after the `STDERR_LIMIT` const:

```rust
const CLAUDE_MODES: &[&str] = &["plan", "acceptEdits", "auto", "bypassPermissions"];
const CODEX_MODES: &[&str] = &["read-only", "workspace-write", "danger-full-access"];

/// One turn's choices. None means Default: no flag, so the CLI's own config decides.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Settings {
    pub model: Option<String>,
    pub effort: Option<String>,
    /// Claude permission mode or Codex sandbox; Codex treats None as workspace-write.
    pub mode: Option<String>,
    #[serde(default)]
    pub fast: bool,
    /// The model's display name, for transcript captions only.
    pub name: Option<String>,
}

impl Settings {
    /// Refuse anything a CLI could read as another flag; modes come from a fixed list.
    pub fn validate(&self, agent: &str) -> Result<(), String> {
        for v in [&self.model, &self.effort].into_iter().flatten() {
            if v.is_empty() || v.starts_with('-') || v.chars().any(|c| c.is_whitespace() || c.is_control()) {
                return Err(format!("\"{v}\" is not a valid model or effort."));
            }
        }
        let modes = if agent == "codex" { CODEX_MODES } else { CLAUDE_MODES };
        if let Some(m) = self.mode.as_deref().filter(|m| !modes.contains(m)) {
            return Err(format!("\"{m}\" is not a mode the island can run {agent} in."));
        }
        if self.fast && agent != "claude" {
            return Err("Fast mode is only available for Claude.".into());
        }
        Ok(())
    }

    /// The CLI flags for these choices, placed before any resume arguments and the prompt.
    pub fn args(&self, agent: &str) -> Vec<String> {
        let mut a: Vec<String> = Vec::new();
        let mut flag = |f: &str, v: String| { a.push(f.into()); a.push(v); };
        if agent == "claude" {
            if let Some(m) = &self.model { flag("--model", m.clone()) }
            if let Some(e) = &self.effort { flag("--effort", e.clone()) }
            if let Some(p) = &self.mode { flag("--permission-mode", p.clone()) }
            if self.fast { flag("--settings", "{\"fastMode\":true}".into()) }
        } else {
            if let Some(m) = &self.model { flag("-m", m.clone()) }
            if let Some(e) = &self.effort { flag("-c", format!("model_reasoning_effort=\"{e}\"")) }
            // ponytail: codex exec can't ask for approval, so it defaults to the working-directory sandbox.
            flag("-s", self.mode.clone().unwrap_or_else(|| "workspace-write".into()));
        }
        a
    }
}
```

- [ ] **Step 5: Use it in `command()`**

Replace `command()`'s signature and agent arms:

```rust
fn command(tools: &Tools, agent: &str, cwd: &str, prompt: &str, session: Option<&str>, settings: &Settings) -> Result<Command, String> {
    let bin: PathBuf = tools.find(agent).ok_or_else(|| format!("Could not find {agent} on this Mac."))?;
    let mut c = Command::new(&bin);
    match agent {
        "claude" => {
            c.args(["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages"]);
            c.args(settings.args(agent));
            if let Some(s) = session {
                c.args(["--resume", s]);
            }
            c.args(["--", prompt]);
        }
        "codex" => {
            c.args(["exec", "--json", "--skip-git-repo-check"]);
            c.args(settings.args(agent));
            if let Some(s) = session {
                c.args(["resume", s]);
            }
            c.args(["--", prompt]);
        }
        other => return Err(format!("Unknown agent {other}")),
    }
```

(The old `-c sandbox_mode="workspace-write"` line and its ponytail comment are removed; the comment now lives in `Settings::args`.)

- [ ] **Step 6: Thread settings through `start`, `send`, `turn`**

Add `last: Option<Settings>,` to `struct State` and `last: None` to its initializer in `start`.

```rust
    pub fn start(&self, tools: &Tools, agent: &str, cwd: &str, text: &str, settings: Settings) -> Result<u64, String> {
        if text.trim().is_empty() {
            return Err("Write a message first.".into());
        }
        settings.validate(agent)?;
        // ...unchanged...
        Self::turn(tools, &chat, text, settings)?;
        Ok(id)
    }

    pub fn send(&self, tools: &Tools, id: u64, text: &str, settings: Settings) -> Result<(), String> {
        let chat = self.get(id)?;
        if text.trim().is_empty() {
            return Err("Write a message first.".into());
        }
        settings.validate(&chat.agent)?;
        Self::turn(tools, &chat, text, settings)
    }
```

In `turn`, change the signature to `fn turn(tools: &Tools, chat: &Arc<Chat>, text: &str, settings: Settings) -> Result<(), String>`, store the settings inside the first lock block after `g.transcript.user(text);`:

```rust
            g.last = Some(settings.clone());
```

and pass them to `command`:

```rust
        let spawned = command(tools, &chat.agent, &chat.cwd, text, session.as_deref(), &settings).and_then(|mut c| c.spawn().map_err(|e| e.to_string()));
```

- [ ] **Step 7: Accept settings over the bridge**

In `core/island-core/src/server.rs`, replace the `chatStart` and `chatSend` arms:

```rust
            "chatStart" => {
                let s = |k: &str| req[k].as_str().unwrap_or_default();
                turn_settings(&req).and_then(|t| self.chats.start(&self.tools(), s("agent"), s("cwd"), s("text"), t)).map(|id| json!({"id": id}))
            }
            "chatSend" => turn_settings(&req)
                .and_then(|t| self.chats.send(&self.tools(), req["id"].as_u64().unwrap_or_default(), req["text"].as_str().unwrap_or_default(), t))
                .map(|_| Value::Null),
```

and add as a free function near `install_hook_binary`:

```rust
/// A turn's optional `settings` object; absent means Default for everything.
fn turn_settings(req: &Value) -> Result<crate::chat::Settings, String> {
    if req["settings"].is_null() {
        return Ok(Default::default());
    }
    serde_json::from_value(req["settings"].clone()).map_err(|e| format!("Unreadable settings: {e}"))
}
```

- [ ] **Step 8: Run to verify they pass**

Run: `cd core && cargo test`
Expected: all tests pass, including the 3 new ones.

- [ ] **Step 9: Commit**

```bash
git add core/island-core/src/chat.rs core/island-core/src/server.rs core/island-core/tests/chat.rs
git commit -m "Pass model, effort, mode and fast settings to each chat turn"
```

---

### Task 4: Captions, settings in chat JSON, handoff flags

**Files:**
- Modify: `core/island-core/src/chat.rs` (`Entry`, `Transcript::user`, `turn`, `Chat::summary`, `transcript`, `claim_handoffs`)
- Test: `core/island-core/tests/chat.rs` (append)

**Interfaces:**
- Consumes: `Settings`, `Settings::args`, `State.last` (Task 3).
- Produces: every transcript entry JSON has `"caption": String` (empty when none); `chatList` items and `transcript` have `"settings": Settings | null`; each `chatHandoffClaim` item has `"args": [String]` (the flags to put before the resume arguments). `pub fn Settings::caption(&self) -> String`.

- [ ] **Step 1: Write the failing tests**

Append to `core/island-core/tests/chat.rs`:

```rust
#[test]
fn a_caption_marks_the_first_turn_and_every_change_of_settings() {
    let (tools, root) = fixture("caption", &[("claude", CLAUDE)]);
    let chats = Chats::default();
    let plan = Settings { name: Some("Opus 5.5".into()), ..s(Some("opus"), Some("xhigh"), Some("plan"), true) };
    let id = chats.start(&tools, "claude", root.to_str().unwrap(), "one", plan.clone()).unwrap();
    wait_for(&chats, id, "idle");
    chats.send(&tools, id, "two", plan).unwrap();
    wait_for(&chats, id, "idle");
    chats.send(&tools, id, "three", Settings::default()).unwrap();
    let t = wait_for(&chats, id, "idle");
    let captions: Vec<&str> = t["entries"].as_array().unwrap().iter()
        .filter(|e| e["kind"] == "user").map(|e| e["caption"].as_str().unwrap()).collect();
    assert_eq!(captions, ["Plan · Opus 5.5 · Extra high · Fast", "", ""], "same settings: no caption; back to all-Default: nothing to say");
    assert_eq!(t["settings"]["mode"], Value::Null);
    assert_eq!(chats.list()[0]["settings"]["fast"], false);
}

#[test]
fn a_terminal_handoff_carries_the_chats_last_flags() {
    let (tools, root) = fixture("handoff-flags", &[("claude", CLAUDE)]);
    let chats = Chats::default();
    let id = chats.start(&tools, "claude", root.to_str().unwrap(), "one", s(Some("opus"), None, Some("plan"), false)).unwrap();
    wait_for(&chats, id, "idle");
    chats.request_handoff(id, "terminal").unwrap();
    let claim = chats.claim_handoffs(&tools);
    assert_eq!(claim[0]["args"], serde_json::json!(["--model", "opus", "--permission-mode", "plan"]));
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd core && cargo test --test chat caption handoff_carries`
Expected: FAIL (`caption` is null / `args` is null).

- [ ] **Step 3: Implement**

`Entry` gains a field after `status`:

```rust
    /// User rows: the settings this turn ran with, when they changed (empty otherwise).
    pub caption: String,
```

and `Entry::new` sets `caption: String::new()`.

`Transcript::user` becomes:

```rust
    pub fn user(&mut self, text: &str, caption: String) {
        let mut e = Entry::new("user", text);
        e.caption = caption;
        self.push(e);
    }
```

Add to `impl Settings`:

```rust
    /// "Plan · Opus 5.5 · High · Fast": the non-default choices, for the transcript.
    pub fn caption(&self) -> String {
        let mode = self.mode.as_deref().map(|m| match m {
            "plan" => "Plan",
            "acceptEdits" => "Accept edits",
            "auto" => "Auto",
            "bypassPermissions" => "Bypass",
            "read-only" => "Read-only",
            "workspace-write" => "Workspace write",
            "danger-full-access" => "Full access",
            other => other,
        }.to_string());
        let model = self.name.clone().or_else(|| self.model.clone());
        // ponytail: effort labels are duplicated in Swift's TurnLabels.effort; keep both in step.
        let effort = self.effort.as_deref().map(|e| if e == "xhigh" { "Extra high".to_string() } else {
            let mut c = e.chars();
            c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
        });
        let fast = self.fast.then(|| "Fast".to_string());
        [mode, model, effort, fast].into_iter().flatten().collect::<Vec<_>>().join(" · ")
    }
```

In `turn`, replace the `g.transcript.user(text);` / `g.last = Some(settings.clone());` lines with:

```rust
            let caption = if g.last.as_ref() == Some(&settings) { String::new() } else { settings.caption() };
            g.transcript.user(text, caption);
            g.last = Some(settings.clone());
```

In `Chat::summary`, add `"settings": g.last,` to the `json!` object. In `Chats::transcript`, add `"settings": g.last,` likewise.

In `claim_handoffs`, inside the `Ok(json!({...}))`, add:

```rust
                    "args": g.last.clone().unwrap_or_default().args(&chat.agent),
```

- [ ] **Step 4: Run to verify they pass**

Run: `cd core && cargo test`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add core/island-core/src/chat.rs core/island-core/tests/chat.rs
git commit -m "Caption turns whose settings changed; hand off with the chat's flags"
```

---

### Task 5: Swift settings model, fitting, persistence and bridge wiring

**Files:**
- Modify: `macos/AgentIsland/Chat.swift` (types, `PanelModel` extension methods, `startChat`, `sendChat`, `retryChat`, `openCompose`, `openChat`, `closeChat`)
- Modify: `macos/AgentIsland/PanelView.swift` (two `@Published` stored properties)
- Modify: `macos/AgentIsland/ChatHandoff.swift:9-18, 63-66` (`args` on `HandoffLaunch`, used in `resumeCommand`)
- Modify: `macos/AgentIsland/AppDelegate.swift` (~line 79, after `CoreBridge.shared.start()` succeeds)

**Interfaces:**
- Consumes: bridge ops `chatOptions`, `chatStart`/`chatSend` `settings`, JSON fields `caption`, `settings`, `args` (Tasks 2 to 4).
- Produces (for Task 6): `struct TurnSettings: Codable, Equatable { var model: String?; var effort: String?; var mode: String?; var fast: Bool; var name: String? }`, `struct ModelOption`, `struct AgentOptions { var models: [ModelOption]; var error: String?; var loading: Bool }`, `enum TurnLabels { static func modes(_ agent: String) -> [(id: String, name: String)]; static func effort(_ e: String) -> String; static func dangerous(_ mode: String?) -> Bool }`, `TurnSettings.fitted(to: AgentOptions?, agent: String) -> TurnSettings`, `TurnSettings.effortLevels(in: AgentOptions?) -> [String]`, and on `PanelModel`: `var options: [String: AgentOptions]`, `func settings(reply: Bool) -> TurnSettings`, `func setSettings(_ s: TurnSettings, reply: Bool)`, `func loadOptions(refresh: Bool)`. `ChatEntry.caption: String`.

- [ ] **Step 1: Types and labels**

In `Chat.swift`, add `var settings: TurnSettings?` to `ChatInfo` and `var caption: String` to `ChatEntry`. Then add below `ChatTranscript`:

```swift
/// One turn's choices; nil is Default (no flag, the CLI's own config). Mirrors chat.rs `Settings`.
struct TurnSettings: Codable, Equatable {
    var model: String?
    var effort: String?
    /// Claude permission mode or Codex sandbox; Codex treats nil as workspace-write.
    var mode: String?
    var fast = false
    /// The model's display name, for chips and captions.
    var name: String?

    var dict: [String: Any] {
        (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self))) as? [String: Any] ?? [:]
    }
}

struct ModelOption: Decodable, Equatable, Identifiable {
    var id: String
    var name: String
    var efforts: [String]
    var auto: Bool
    var fast: Bool
}

struct AgentOptions: Decodable, Equatable {
    var models: [ModelOption]
    var error: String?
    var loading: Bool
}

enum TurnLabels {
    /// The modes the island offers; Claude's list starts with Default (empty id).
    static func modes(_ agent: String) -> [(id: String, name: String)] {
        agent == "codex"
            ? [("read-only", "Read-only"), ("workspace-write", "Workspace write"), ("danger-full-access", "Full access")]
            : [("", "Default"), ("plan", "Plan"), ("acceptEdits", "Accept edits"), ("auto", "Auto"), ("bypassPermissions", "Bypass")]
    }

    // ponytail: mirrors Settings::caption in chat.rs; keep both in step.
    static func effort(_ e: String) -> String { e == "xhigh" ? "Extra high" : e.prefix(1).uppercased() + e.dropFirst() }

    static func dangerous(_ mode: String?) -> Bool { mode == "bypassPermissions" || mode == "danger-full-access" }

    /// Effort levels, lowest first, so snapping can step down.
    static let order = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]
    static func rank(_ e: String) -> Int { order.firstIndex(of: e) ?? order.count }
}

extension TurnSettings {
    /// Levels the chosen model accepts. With Default model the island can't know which model the
    /// config picks, so it offers every level the CLI's models know.
    // ponytail: a Default model with a level its configured model lacks fails that turn with the CLI's own error.
    func effortLevels(in options: AgentOptions?) -> [String] {
        let models = options?.models ?? []
        if let id = model, let m = models.first(where: { $0.id == id }) { return m.efforts }
        return Array(Set(models.flatMap(\.efforts))).sorted { TurnLabels.rank($0) < TurnLabels.rank($1) }
    }

    /// Fit these choices to what the CLI lists: an unlisted model goes back to Default, effort snaps
    /// down to the highest supported level, and Auto or Fast drop when the model lacks them.
    /// An empty list (still loading, or the CLI failed) keeps the choices as they are.
    func fitted(to options: AgentOptions?, agent: String) -> TurnSettings {
        guard let options, !options.models.isEmpty else { return self }
        var s = self
        let m = s.model.flatMap { id in options.models.first { $0.id == id } }
        if m == nil { s.model = nil }
        s.name = m?.name
        let levels = s.effortLevels(in: options)
        if let e = s.effort, !levels.contains(e) {
            s.effort = levels.last { TurnLabels.rank($0) < TurnLabels.rank(e) }
        }
        if agent == "claude" {
            if s.mode == "auto", let m, !m.auto { s.mode = nil }
            if s.fast, !(m?.fast ?? false) { s.fast = false }
        } else {
            s.fast = false
        }
        return s
    }

    #if DEBUG
    /// Assert-based check of the fitting rules; runs once at launch in Debug builds.
    static func selfCheck() {
        let opts = AgentOptions(models: [
            ModelOption(id: "opus", name: "Opus 5.5", efforts: ["low", "medium", "high", "xhigh", "max"], auto: true, fast: true),
            ModelOption(id: "old", name: "Opus 4.6", efforts: ["low", "medium", "high", "max"], auto: false, fast: false),
        ], error: nil, loading: false)
        var s = TurnSettings(model: "old", effort: "xhigh", mode: "auto", fast: true)
        s = s.fitted(to: opts, agent: "claude")
        assert(s.effort == "high" && s.mode == nil && !s.fast && s.name == "Opus 4.6", "snap down, drop auto and fast")
        assert(TurnSettings(model: "gone").fitted(to: opts, agent: "claude").model == nil, "unlisted model goes to Default")
        let loading = AgentOptions(models: [], error: nil, loading: true)
        assert(TurnSettings(model: "gone").fitted(to: loading, agent: "claude").model == "gone", "an empty list keeps choices")
        assert(TurnSettings(fast: true).fitted(to: opts, agent: "codex").fast == false, "fast never reaches Codex")
    }
    #endif
}
```

- [ ] **Step 2: Stored state on `PanelModel`**

In `PanelView.swift`, after `@Published var composeError: String?` add:

```swift
    /// Each agent's model menu from the core (`chatOptions`).
    @Published var options: [String: AgentOptions] = [:]
    /// The open conversation's choices once changed there; nil means the chat's last settings.
    @Published var replySettings: TurnSettings?
```

- [ ] **Step 3: Model methods**

In the `extension PanelModel` in `Chat.swift`, add after `composerDirName`:

```swift
    private func remembered(_ agent: String) -> TurnSettings {
        guard let d = UserDefaults.standard.data(forKey: "composerSettings.\(agent)"),
              let s = try? JSONDecoder().decode(TurnSettings.self, from: d) else { return TurnSettings() }
        return s
    }

    /// The choices for the new-chat composer, or for the open chat's next turn.
    func settings(reply: Bool) -> TurnSettings {
        let agent = reply ? (chat?.agent ?? composerAgent) : composerAgent
        let s = reply ? (replySettings ?? chat?.settings ?? remembered(agent)) : remembered(agent)
        return s.fitted(to: options[agent], agent: agent)
    }

    /// A change in either composer is also remembered as that agent's choice for new chats.
    func setSettings(_ s: TurnSettings, reply: Bool) {
        let agent = reply ? (chat?.agent ?? composerAgent) : composerAgent
        let f = s.fitted(to: options[agent], agent: agent)
        if let d = try? JSONEncoder().encode(f) { UserDefaults.standard.set(d, forKey: "composerSettings.\(agent)") }
        if reply { replySettings = f }
        objectWillChange.send()
    }

    /// Pull the model menus; the core refetches in the background when asked and an hour has passed.
    func loadOptions(refresh: Bool) {
        guard let o = try? CoreBridge.shared.call(["op": "chatOptions", "refresh": refresh], as: [String: AgentOptions].self) else { return }
        if o != options { options = o }
        if o.values.contains(where: \.loading) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.loadOptions(refresh: false) }
        }
    }
```

- [ ] **Step 4: Wire sends and navigation**

- `openCompose`: add `loadOptions(refresh: true)` as the first line of the closure.
- `openChat`: add `replySettings = nil` and `loadOptions(refresh: true)` inside the closure, before `chat = c`.
- `closeChat`: add `replySettings = nil` inside `change`.
- `startChat`: request becomes `["op": "chatStart", "agent": composerAgent, "cwd": composerDir, "text": text, "settings": settings(reply: false).dict]`.
- `sendChat` and `retryChat`: request becomes `["op": "chatSend", "id": c.id, "text": <text>, "settings": settings(reply: true).dict]` (`text` / `last.text` as today).

- [ ] **Step 5: Handoff flags**

In `ChatHandoff.swift`, add `var args: [String]` to `HandoffLaunch` after `path`, and change `resumeCommand`:

```swift
    static func resumeCommand(_ launch: HandoffLaunch) -> String {
        let resume = launch.agent == "claude" ? ["--resume", launch.sessionId] : ["resume", launch.sessionId]
        return "cd -- \(shellQuote(launch.cwd)) && exec /usr/bin/env \(shellQuote("PATH=" + launch.path)) " + ([launch.bin] + launch.args + resume).map(shellQuote).joined(separator: " ")
    }
```

- [ ] **Step 6: Launch kick and self-check**

In `AppDelegate.swift`, after `_ = Updater.shared` add:

```swift
        _ = try? CoreBridge.shared.call(["op": "chatOptions", "refresh": true]) // warm the model menus
        #if DEBUG
        TurnSettings.selfCheck()
        #endif
```

- [ ] **Step 7: Build**

Run: `cd macos && xcodebuild -project AgentIsland.xcodeproj -scheme AgentIsland -configuration Debug -derivedDataPath ../build/dd build -quiet`
Expected: build succeeds with no new warnings. (If `project.yml` lists sources explicitly, no change is needed: all edits are to existing files.)

- [ ] **Step 8: Commit**

```bash
git add macos/AgentIsland/Chat.swift macos/AgentIsland/PanelView.swift macos/AgentIsland/ChatHandoff.swift macos/AgentIsland/AppDelegate.swift
git commit -m "Remember and fit per-agent turn settings; send them with each turn"
```

---

### Task 6: Composer chips and transcript caption

**Files:**
- Modify: `macos/AgentIsland/ChatView.swift` (`Composer.body` line ~167, `options` view at `:172`, new `TurnChips` view, `EntryView` `"user"` case at `:480`)

**Interfaces:**
- Consumes: everything Task 5 produces.

- [ ] **Step 1: Show chips in both composers**

In `Composer.body`, replace `if mode == .new { options }` with `options`. Rewrite `options` so the agent toggle and folder only appear for `.new`, with the chips between them:

```swift
    private var options: some View {
        HStack(spacing: 6) {
            if mode == .new {
                // ...the existing agent toggle HStack, unchanged...
            }
            Spacer(minLength: 6)
            TurnChips(
                agent: mode == .new ? model.composerAgent : (model.chat?.agent ?? model.composerAgent),
                options: model.options[mode == .new ? model.composerAgent : (model.chat?.agent ?? model.composerAgent)],
                settings: model.settings(reply: mode == .reply),
                set: { model.setSettings($0, reply: mode == .reply) }
            )
            if mode == .new {
                // ...the existing folder Button, unchanged...
            }
        }
        .padding(.horizontal, 2)
    }
```

- [ ] **Step 2: Add `TurnChips`**

Below `Composer`, add:

```swift
/// Mode chip and Model·Effort chip: native menus, styled like the folder chip.
private struct TurnChips: View {
    let agent: String
    let options: AgentOptions?
    let settings: TurnSettings
    let set: (TurnSettings) -> Void

    private var models: [ModelOption] { options?.models ?? [] }
    private var current: ModelOption? { settings.model.flatMap { id in models.first { $0.id == id } } }
    private var modeID: String { settings.mode ?? (agent == "codex" ? "workspace-write" : "") }
    private var modeName: String { TurnLabels.modes(agent).first { $0.id == modeID }?.name ?? "Default" }
    private var modelText: String {
        let parts = [settings.name ?? settings.model, settings.effort.map(TurnLabels.effort)].compactMap { $0 }
        return parts.isEmpty ? "Default" : parts.joined(separator: " · ")
    }

    private func update(_ change: (inout TurnSettings) -> Void) {
        var s = settings
        change(&s)
        set(s)
    }

    var body: some View {
        HStack(spacing: 2) {
            Menu {
                Picker("Mode", selection: Binding(get: { modeID }, set: { id in update { $0.mode = id.isEmpty ? nil : id } })) {
                    ForEach(TurnLabels.modes(agent).filter { $0.id != "auto" || current?.auto != false }, id: \.id) {
                        Text($0.name).tag($0.id)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                chip(icon: TurnLabels.dangerous(settings.mode) ? "exclamationmark.triangle" : nil, text: modeName)
            }
            .accessibilityLabel("Mode: \(modeName)")

            Menu {
                Picker("Model", selection: Binding(get: { settings.model ?? "" }, set: { id in update { $0.model = id.isEmpty ? nil : id } })) {
                    Text("Default").tag("")
                    ForEach(models) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.inline)
                let levels = settings.effortLevels(in: options)
                if !levels.isEmpty {
                    Picker("Effort", selection: Binding(get: { settings.effort ?? "" }, set: { e in update { $0.effort = e.isEmpty ? nil : e } })) {
                        Text("Default").tag("")
                        ForEach(levels, id: \.self) { Text(TurnLabels.effort($0)).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
                if agent == "claude", current?.fast == true {
                    Toggle("Fast", isOn: Binding(get: { settings.fast }, set: { on in update { $0.fast = on } }))
                }
                if models.isEmpty {
                    Text(options?.loading == true ? "Loading models…" : (options?.error ?? "Models unavailable")).disabled(true)
                }
            } label: {
                chip(icon: settings.fast ? "bolt.fill" : nil, text: modelText)
            }
            .accessibilityLabel("Model: \(settings.name ?? settings.model ?? "Default"), effort \(settings.effort.map(TurnLabels.effort) ?? "Default")\(settings.fast ? ", fast" : "")")
        }
    }

    private func chip(icon: String?, text: String) -> some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 10)) }
            Text(text).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(muted)
        }
        .foregroundStyle(secondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .contentShape(Rectangle())
    }
}
```

Apply `.menuStyle(.button).buttonStyle(IslandButtonStyle(radius: 6)).menuIndicator(.hidden).fixedSize()` to both `Menu`s so the custom label renders on macOS 14 (the chevron is drawn in the label). If the custom label still renders flattened, fall back to `.menuStyle(.borderlessButton)` and check visually.

- [ ] **Step 3: Caption under user messages**

In `EntryView`, wrap the `"user"` case's `Text` bubble:

```swift
        case "user":
            HStack {
                Spacer(minLength: 56)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(entry.text)
                        .font(.system(size: 13))
                        .foregroundStyle(ink)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
                    if !entry.caption.isEmpty {
                        Text(entry.caption).font(.system(size: 10)).foregroundStyle(muted).padding(.trailing, 4)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(entry.caption.isEmpty ? "You: \(entry.text)" : "You: \(entry.text). \(entry.caption)")
```

- [ ] **Step 4: Build**

Run: `cd macos && xcodebuild -project AgentIsland.xcodeproj -scheme AgentIsland -configuration Debug -derivedDataPath ../build/dd build -quiet`
Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add macos/AgentIsland/ChatView.swift
git commit -m "Mode and model chips under both composers; caption changed turns"
```

---

### Task 7: Verify end to end and finish

**Files:** none new.

- [ ] **Step 1: Full test suite**

Run: `cd core && cargo test`
Expected: all pass.

- [ ] **Step 2: Real-CLI smoke check of the flag shapes**

```bash
codex exec -m gpt-6-luna -c 'model_reasoning_effort="low"' -s read-only resume --help >/dev/null && echo codex-ok
claude --model opus --effort high --permission-mode plan --settings '{"fastMode":true}' --help >/dev/null && echo claude-ok
```

Expected: `codex-ok`, `claude-ok`.

- [ ] **Step 3: Manual check in the Debug build**

Run the Debug build from `build/dd` (not installed). Confirm:
1. The new-chat composer shows `Default ▾` and `Default ▾` chips for Claude; the model menu lists Opus 5.5, Fable 5.1, Sonnet 5.5, Haiku 5.5 and older models from the live list.
2. Pick Opus 4.6 with Extra high: effort snaps to High. Pick Haiku 4.5: the Effort section disappears.
3. Codex shows `Workspace write ▾`; choosing Full access shows the triangle.
4. Start a Claude chat in Plan; the first message has the "Plan" caption and the reply is a plan. Switch the chip to Accept edits, send "go": the caption shows "Accept edits" and the agent edits files.
5. Relaunch: choices are remembered per agent.
6. Hand off to Terminal: the command line shows the chat's flags.

- [ ] **Step 4: Finish per AGENTS.md**

Run a code review of the branch, fix what it finds, commit, and review again until a review finds zero issues. Then open a PR against `main`, squash merge it, and reinstall from the merged `main` with `scripts/install.sh`.
