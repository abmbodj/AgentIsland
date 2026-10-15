//! Chats started from the panel's composer: one headless agent process per turn (Claude Code or Codex),
//! its JSON event stream folded into an in-memory transcript the UI pulls by revision.
//! A follow-up turn resumes the agent's own session; Stop kills the turn's process group.
use crate::pr::Tools;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read};
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex, MutexGuard};

const OUTPUT_LIMIT: usize = 4_000;
const STDERR_LIMIT: usize = 600;
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
        let mut flag = |f: &str, v: String| {
            a.push(f.into());
            a.push(v);
        };
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
}

#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    /// "user", "assistant", "tool", "error" or "notice".
    pub kind: &'static str,
    pub text: String,
    /// Tool rows: the tool's name, a one-line input summary, its output and "running" | "done" | "error".
    pub name: String,
    pub input: String,
    pub output: String,
    pub status: &'static str,
    /// User rows: the settings this turn ran with, when they changed (empty otherwise).
    pub caption: String,
    pub rev: u64,
    #[serde(skip)]
    key: String,
}

impl Entry {
    fn new(kind: &'static str, text: &str) -> Self {
        Entry { kind, text: text.into(), name: String::new(), input: String::new(), output: String::new(), status: "done", caption: String::new(), rev: 0, key: String::new() }
    }
}

#[derive(Debug, Default)]
pub struct Transcript {
    entries: Vec<Entry>,
    rev: u64,
    pub session_id: Option<String>,
    /// The Claude message currently streaming, to key its text blocks.
    msg: String,
    /// Codex item IDs restart in each exec subprocess, even when resuming a session.
    turn: u64,
}

fn truncate(s: &str, n: usize) -> String {
    if s.chars().count() <= n { s.to_string() } else { s.chars().take(n).collect::<String>() + "…" }
}

/// One line for a collapsed tool row: the field a human would recognise.
fn summarize(input: &Value) -> String {
    for k in ["command", "file_path", "path", "pattern", "url", "query", "description"] {
        if let Some(s) = input[k].as_str() {
            return truncate(s, 200);
        }
    }
    if input.is_null() { String::new() } else { truncate(&input.to_string(), 200) }
}

fn result_text(content: &Value) -> String {
    match content {
        Value::String(s) => s.clone(),
        Value::Array(a) => a.iter().filter_map(|b| b["text"].as_str()).collect::<Vec<_>>().join("\n"),
        _ => String::new(),
    }
}

impl Transcript {
    fn touch(&mut self, i: usize) -> &mut Entry {
        self.rev += 1;
        self.entries[i].rev = self.rev;
        &mut self.entries[i]
    }

    fn push(&mut self, mut e: Entry) -> usize {
        self.rev += 1;
        e.rev = self.rev;
        self.entries.push(e);
        self.entries.len() - 1
    }

    fn find(&self, key: &str) -> Option<usize> {
        self.entries.iter().position(|e| e.key == key)
    }

    pub fn user(&mut self, text: &str, caption: String) {
        let mut e = Entry::new("user", text);
        e.caption = caption;
        self.push(e);
    }

    pub fn error(&mut self, text: &str) {
        if self.entries.last().is_some_and(|e| e.kind == "error" && e.text == text) {
            return; // codex reports a failure as both `error` and `turn.failed`
        }
        self.push(Entry::new("error", text));
    }

    pub fn notice(&mut self, text: &str) {
        self.push(Entry::new("notice", text));
    }

    fn set_text(&mut self, key: String, text: &str, append: bool) {
        let i = self.find(&key).unwrap_or_else(|| {
            let mut e = Entry::new("assistant", "");
            e.key = key;
            self.push(e)
        });
        let e = self.touch(i);
        if append { e.text.push_str(text) } else { e.text = text.into() }
    }

    fn tool(&mut self, id: &str, name: &str, input: &Value) {
        let i = self.find(id).unwrap_or_else(|| {
            let mut e = Entry::new("tool", "");
            e.key = id.into();
            e.status = "running";
            self.push(e)
        });
        let e = self.touch(i);
        e.name = name.into();
        e.input = summarize(input);
    }

    fn tool_result(&mut self, id: &str, output: &str, failed: bool) {
        if let Some(i) = self.find(id) {
            let e = self.touch(i);
            e.output = truncate(output, OUTPUT_LIMIT);
            e.status = if failed { "error" } else { "done" };
        }
    }

    /// Fold one line of `claude -p --output-format stream-json --include-partial-messages`.
    /// Returns true when the turn's final `result` arrived.
    pub fn apply_claude(&mut self, v: &Value) -> bool {
        match v["type"].as_str() {
            Some("system") if v["subtype"] == "init" => self.session_id = v["session_id"].as_str().map(str::to_string),
            Some("stream_event") => {
                let e = &v["event"];
                match e["type"].as_str() {
                    Some("message_start") => self.msg = e["message"]["id"].as_str().unwrap_or_default().to_string(),
                    Some("content_block_start") if e["content_block"]["type"] == "text" => {
                        self.set_text(format!("{}:{}", self.msg, e["index"]), "", false)
                    }
                    Some("content_block_delta") if e["delta"]["type"] == "text_delta" => {
                        self.set_text(format!("{}:{}", self.msg, e["index"]), e["delta"]["text"].as_str().unwrap_or_default(), true)
                    }
                    Some("content_block_start") if e["content_block"]["type"] == "tool_use" => {
                        let b = &e["content_block"];
                        self.tool(b["id"].as_str().unwrap_or_default(), b["name"].as_str().unwrap_or_default(), &Value::Null)
                    }
                    _ => {}
                }
            }
            Some("assistant") => {
                let m = &v["message"];
                let id = m["id"].as_str().unwrap_or_default().to_string();
                // Streamed text is keyed by the stream's block index, which this event's array position
                // doesn't match (thinking blocks); so when the stream already built the message, skip its text.
                let streamed = self.entries.iter().any(|e| e.key.starts_with(&format!("{id}:")));
                for b in m["content"].as_array().into_iter().flatten() {
                    match b["type"].as_str() {
                        Some("text") if !streamed => {
                            let n = self.entries.iter().filter(|e| e.key.starts_with(&format!("{id}:"))).count();
                            self.set_text(format!("{id}:{n}"), b["text"].as_str().unwrap_or_default(), false)
                        }
                        Some("tool_use") => self.tool(b["id"].as_str().unwrap_or_default(), b["name"].as_str().unwrap_or_default(), &b["input"]),
                        _ => {}
                    }
                }
            }
            Some("user") => {
                for b in v["message"]["content"].as_array().into_iter().flatten() {
                    if b["type"] == "tool_result" {
                        self.tool_result(b["tool_use_id"].as_str().unwrap_or_default(), &result_text(&b["content"]), b["is_error"] == true);
                    }
                }
            }
            Some("result") => {
                if let Some(s) = v["session_id"].as_str() {
                    self.session_id = Some(s.into());
                }
                if v["is_error"] == true {
                    let why = v["result"].as_str().or(v["subtype"].as_str()).unwrap_or("The agent stopped with an error.");
                    self.error(why);
                }
                return true;
            }
            _ => {}
        }
        false
    }

    /// Fold one line of `codex exec --json`. Codex reports whole items, not token deltas.
    pub fn apply_codex(&mut self, v: &Value) -> bool {
        let item = &v["item"];
        let key = format!("codex:{}:{}", self.turn, item["id"].as_str().unwrap_or_default());
        let id = key.as_str();
        match (v["type"].as_str(), item["type"].as_str()) {
            (Some("thread.started"), _) => self.session_id = v["thread_id"].as_str().map(str::to_string),
            (Some("item.completed"), Some("agent_message")) => self.set_text(id.into(), item["text"].as_str().unwrap_or_default(), false),
            (Some("item.started"), Some("command_execution")) => self.tool(id, "shell", &json!({"command": item["command"]})),
            (Some("item.completed"), Some("command_execution")) => {
                self.tool(id, "shell", &json!({"command": item["command"]}));
                let failed = item["exit_code"].as_i64().is_some_and(|c| c != 0);
                self.tool_result(id, item["aggregated_output"].as_str().unwrap_or_default(), failed);
            }
            (Some("item.completed"), Some("file_change")) => {
                let paths: Vec<&str> = item["changes"].as_array().into_iter().flatten().filter_map(|c| c["path"].as_str()).collect();
                self.tool(id, "edit", &json!({"path": paths.join(", ")}));
                self.tool_result(id, "", item["status"] == "failed");
            }
            (Some("turn.failed"), _) => self.error(v["error"]["message"].as_str().unwrap_or("The turn failed.")),
            (Some("error"), _) => self.error(v["message"].as_str().unwrap_or("The agent reported an error.")),
            _ => {}
        }
        matches!(v["type"].as_str(), Some("turn.completed" | "turn.failed"))
    }

    fn since(&self, rev: u64) -> Vec<Value> {
        let mut out = Vec::new();
        for (i, e) in self.entries.iter().enumerate().filter(|(_, e)| e.rev > rev) {
            let mut v = serde_json::to_value(e).unwrap_or(Value::Null);
            v["index"] = json!(i);
            out.push(v);
        }
        out
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Status {
    Running,
    Idle,
    Failed,
}

impl Status {
    fn name(self) -> &'static str {
        match self {
            Status::Running => "running",
            Status::Idle => "idle",
            Status::Failed => "failed",
        }
    }
}

#[derive(Clone, Serialize)]
struct Handoff {
    token: u64,
    target: String,
    status: &'static str,
    #[serde(skip)]
    reopened: bool,
}

struct State {
    transcript: Transcript,
    status: Status,
    error: Option<String>,
    pid: Option<i32>,
    stopping: bool,
    handoff: Option<Handoff>,
    handoff_error: Option<String>,
    handoff_token: u64,
    last: Option<Settings>,
}

pub struct Chat {
    pub id: u64,
    pub agent: String,
    pub cwd: String,
    title: String,
    state: Mutex<State>,
}

impl Chat {
    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn summary(&self) -> Value {
        let g = self.lock();
        json!({
            "id": self.id, "agent": self.agent, "cwd": self.cwd, "title": self.title,
            "status": g.status.name(), "sessionId": g.transcript.session_id, "error": g.error,
            "handoff": g.handoff, "handoffError": g.handoff_error, "settings": g.last,
        })
    }
}

#[derive(Default)]
pub struct Chats {
    list: Mutex<HashMap<u64, Arc<Chat>>>,
    next: Mutex<u64>,
}

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
    c.current_dir(cwd).env("PATH", crate::pr::search_path(&bin)).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).process_group(0);
    Ok(c)
}

impl Chats {
    pub fn start(&self, tools: &Tools, agent: &str, cwd: &str, text: &str, settings: Settings) -> Result<u64, String> {
        if text.trim().is_empty() {
            return Err("Write a message first.".into());
        }
        settings.validate(agent)?;
        if !std::path::Path::new(cwd).is_dir() {
            return Err(format!("{cwd} is not a folder."));
        }
        let id = {
            let mut n = self.next.lock().unwrap_or_else(|e| e.into_inner());
            *n += 1;
            *n
        };
        let title = truncate(text.trim().lines().next().unwrap_or_default(), 60);
        let chat = Arc::new(Chat {
            id,
            agent: agent.into(),
            cwd: cwd.into(),
            title,
            state: Mutex::new(State { transcript: Transcript::default(), status: Status::Idle, error: None, pid: None, stopping: false, handoff: None, handoff_error: None, handoff_token: 0, last: None }),
        });
        self.list.lock().unwrap_or_else(|e| e.into_inner()).insert(id, chat.clone());
        Self::turn(tools, &chat, text, settings)?;
        Ok(id)
    }

    fn get(&self, id: u64) -> Result<Arc<Chat>, String> {
        self.list.lock().unwrap_or_else(|e| e.into_inner()).get(&id).cloned().ok_or_else(|| "That chat no longer exists.".into())
    }

    pub fn send(&self, tools: &Tools, id: u64, text: &str, settings: Settings) -> Result<(), String> {
        let chat = self.get(id)?;
        if text.trim().is_empty() {
            return Err("Write a message first.".into());
        }
        settings.validate(&chat.agent)?;
        Self::turn(tools, &chat, text, settings)
    }

    pub fn request_handoff(&self, id: u64, target: &str) -> Result<(), String> {
        let chat = self.get(id)?;
        match target {
            "terminal" | "iterm" | "ghostty" => {},
            "claudeDesktop" if chat.agent == "claude" => {},
            "codexDesktop" if chat.agent == "codex" => {},
            _ => return Err("That destination is not supported for this agent.".into()),
        }
        let mut g = chat.lock();
        let reopened = if let Some(h) = &g.handoff {
            if h.status != "opened" || h.target != target {
                return Err("A handoff is already active for this chat.".into());
            }
            true
        } else { false };
        g.handoff_token = g.handoff_token.checked_add(1).ok_or("Too many handoff attempts for this chat.")?;
        g.handoff = Some(Handoff { token: g.handoff_token, target: target.into(), status: "queued", reopened });
        g.handoff_error = None;
        Ok(())
    }

    pub fn cancel_handoff(&self, id: u64) -> Result<(), String> {
        let chat = self.get(id)?;
        let mut g = chat.lock();
        let h = g.handoff.as_ref().ok_or("No handoff is queued.")?;
        if h.status != "queued" { return Err("Only a queued handoff can be cancelled.".into()); }
        Self::restore_handoff(&mut g);
        Ok(())
    }

    // A failed or cancelled reopen must never make the original notch transcript writable.
    fn restore_handoff(g: &mut State) {
        if g.handoff.as_ref().is_some_and(|h| h.reopened) {
            g.handoff.as_mut().unwrap().status = "opened";
        } else {
            g.handoff = None;
        }
    }

    pub fn claim_handoffs(&self, tools: &Tools) -> Value {
        let list = self.list.lock().unwrap_or_else(|e| e.into_inner());
        let mut claims = Vec::new();
        for chat in list.values() {
            let mut g = chat.lock();
            if g.status == Status::Running || !g.handoff.as_ref().is_some_and(|h| h.status == "queued") {
                continue;
            }
            let resolved = (|| {
                let session = g.transcript.session_id.as_deref().filter(|s| !s.trim().is_empty())
                    .ok_or_else(|| "The agent did not provide a native session to resume.".to_string())?;
                if !std::path::Path::new(&chat.cwd).is_dir() {
                    return Err(format!("{} is no longer a folder.", chat.cwd));
                }
                let bin = tools.find(&chat.agent).ok_or_else(|| format!("Could not find {} on this Mac.", chat.agent))?;
                let path = crate::pr::search_path(&bin);
                let bin = std::fs::canonicalize(bin).map_err(|e| format!("Could not resolve the agent executable: {e}"))?;
                use std::os::unix::fs::PermissionsExt;
                if std::fs::metadata(&bin).map_err(|e| e.to_string())?.permissions().mode() & 0o111 == 0 {
                    return Err(format!("{} is not executable.", bin.display()));
                }
                Ok(json!({"id": chat.id, "agent": chat.agent, "cwd": chat.cwd,
                    "sessionId": session, "target": g.handoff.as_ref().unwrap().target,
                    "args": g.last.clone().unwrap_or_default().args(&chat.agent),
                    "token": g.handoff.as_ref().unwrap().token,
                    "bin": bin, "path": path.to_string_lossy()}))
            })();
            match resolved {
                Ok(claim) => {
                    g.handoff.as_mut().unwrap().status = "launching";
                    claims.push(claim);
                }
                Err(error) => {
                    Self::restore_handoff(&mut g);
                    g.handoff_error = Some(error);
                }
            }
        }
        Value::Array(claims)
    }

    pub fn finish_handoff(&self, id: u64, token: u64, error: Option<&str>) -> Result<(), String> {
        let chat = self.get(id)?;
        let mut g = chat.lock();
        if !g.handoff.as_ref().is_some_and(|h| h.token == token && matches!(h.status, "launching" | "opened")) {
            return Err("That handoff attempt is no longer active.".into());
        }
        if error.is_none() && g.handoff.as_ref().is_some_and(|h| h.status == "opened") {
            return Ok(()); // duplicate success must not clear a later failure receipt
        }
        if let Some(error) = error {
            // Once opened, external turns may exist; a later exit cannot return ownership.
            if g.handoff.as_ref().is_some_and(|h| h.status == "launching") {
                Self::restore_handoff(&mut g);
            }
            g.handoff_error = Some(error.into());
        } else {
            g.handoff.as_mut().unwrap().status = "opened";
            g.handoff_error = None;
        }
        Ok(())
    }

    /// Kill the running turn's process group; the turn's reader thread settles the chat to idle.
    pub fn stop(&self, id: u64) {
        if let Ok(chat) = self.get(id) {
            let mut g = chat.lock();
            if g.status == Status::Running {
                g.stopping = true; // also covers a Stop that lands before the process is spawned
                if let Some(pid) = g.pid {
                    unsafe { libc::kill(-pid, libc::SIGTERM) };
                }
            }
        }
    }

    /// Forget the chat: stop its turn if one is running, then drop it and its transcript.
    pub fn delete(&self, id: u64) {
        self.stop(id);
        self.list.lock().unwrap_or_else(|e| e.into_inner()).remove(&id);
    }

    pub fn transcript(&self, id: u64, since: u64) -> Result<Value, String> {
        let chat = self.get(id)?;
        let g = chat.lock();
        Ok(json!({
            "status": g.status.name(), "error": g.error, "sessionId": g.transcript.session_id,
            "handoff": g.handoff, "handoffError": g.handoff_error, "settings": g.last,
            "rev": g.transcript.rev, "entries": g.transcript.since(since),
        }))
    }

    pub fn list(&self) -> Value {
        let mut chats: Vec<_> = self.list.lock().unwrap_or_else(|e| e.into_inner()).values().cloned().collect();
        chats.sort_by_key(|c| c.id);
        Value::Array(chats.iter().map(|c| c.summary()).collect())
    }

    pub fn kill_all(&self) {
        let ids: Vec<u64> = self.list.lock().unwrap_or_else(|e| e.into_inner()).keys().copied().collect();
        ids.into_iter().for_each(|id| self.stop(id));
    }

    fn turn(tools: &Tools, chat: &Arc<Chat>, text: &str, settings: Settings) -> Result<(), String> {
        let session = {
            let mut g = chat.lock();
            if g.handoff.is_some() {
                return Err("Continue this chat in its handoff destination, or cancel the queued handoff.".into());
            }
            if g.status == Status::Running {
                return Err("The agent is still working.".into());
            }
            g.transcript.turn += 1;
            // A change back to all-Default still shows, so the user sees that a choice was turned off.
            let caption = match (&g.last, settings.caption()) {
                (Some(prev), _) if prev == &settings => String::new(),
                (Some(_), c) if c.is_empty() => "Default".to_string(),
                (_, c) => c,
            };
            g.transcript.user(text, caption);
            g.last = Some(settings.clone());
            g.error = None;
            g.stopping = false;
            g.status = Status::Running;
            g.transcript.session_id.clone()
        };
        let spawned = command(tools, &chat.agent, &chat.cwd, text, session.as_deref(), &settings).and_then(|mut c| c.spawn().map_err(|e| e.to_string()));
        let mut child = match spawned {
            Ok(c) => c,
            Err(e) => { Self::fail(chat, &e); return Ok(()); },
        };
        {
            let mut g = chat.lock();
            g.pid = Some(child.id() as i32);
            if g.stopping {
                unsafe { libc::kill(-(child.id() as i32), libc::SIGTERM) };
            }
        }
        let (out, mut err) = (child.stdout.take().unwrap(), child.stderr.take().unwrap());
        let chat = chat.clone();
        std::thread::spawn(move || {
            let stderr = std::thread::spawn(move || {
                let mut s = String::new();
                let _ = err.by_ref().take(64_000).read_to_string(&mut s);
                let _ = std::io::copy(&mut err, &mut std::io::sink()); // keep draining so a chatty agent never blocks on a full pipe
                s
            });
            let mut finished = false;
            for line in BufReader::new(out).lines().map_while(Result::ok) {
                let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
                let mut g = chat.lock();
                finished |= if chat.agent == "claude" { g.transcript.apply_claude(&v) } else { g.transcript.apply_codex(&v) };
            }
            let code = child.wait().ok().and_then(|s| s.code());
            let stderr = stderr.join().unwrap_or_default();
            let mut g = chat.lock();
            g.pid = None;
            if g.stopping {
                g.transcript.notice("Stopped");
                g.status = Status::Idle;
            } else if !finished && code != Some(0) {
                let why = stderr.trim();
                let msg = if why.is_empty() { format!("The agent exited unexpectedly (code {}).", code.map_or("none".into(), |c| c.to_string())) } else { truncate(why, STDERR_LIMIT) };
                g.transcript.error(&msg);
                g.error = Some(msg);
                g.status = Status::Failed;
            } else {
                g.status = Status::Idle;
            }
        });
        Ok(())
    }

    fn fail(chat: &Chat, msg: &str) {
        let mut g = chat.lock();
        g.transcript.error(msg);
        g.error = Some(msg.into());
        g.status = Status::Failed;
    }
}
