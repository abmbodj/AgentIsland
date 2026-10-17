//! Chats started from the panel's composer: one headless agent process per turn (Claude Code or Codex),
//! its JSON event stream folded into an in-memory transcript the UI pulls by revision.
//! A follow-up turn resumes the agent's own session; Stop kills the turn's process group.
use crate::pr::Tools;
use crate::plan::PlanBook;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{ChildStdin, Command, Stdio};
use std::sync::{Arc, Mutex, MutexGuard};

const OUTPUT_LIMIT: usize = 4_000;
const STDERR_LIMIT: usize = 600;
const SIGNED_OUT: &str = "Claude Code is signed out. Open Terminal, run `claude`, sign in with /login, then send your message again.";
const CLAUDE_MODES: &[&str] = &["plan", "acceptEdits", "auto", "bypassPermissions"];
const CODEX_MODES: &[&str] = &["read-only", "workspace-write", "danger-full-access"];

/// A pasted or uploaded image, base64 as the Messages API takes it.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Image {
    pub media_type: String,
    pub data: String,
}

const IMAGE_TYPES: &[&str] = &["image/png", "image/jpeg", "image/gif", "image/webp"];
const IMAGES_LIMIT: usize = 24_000_000;

fn check_images(agent: &str, images: &[Image]) -> Result<(), String> {
    if images.is_empty() { return Ok(()) }
    // ponytail: codex exec takes images as -i files; only Claude gets pasted images for now.
    if agent != "claude" { return Err("Images are only available for Claude.".into()) }
    if images.iter().any(|i| !IMAGE_TYPES.contains(&i.media_type.as_str())) { return Err("Use a PNG, JPEG, GIF or WebP image.".into()) }
    if images.iter().map(|i| i.data.len()).sum::<usize>() > IMAGES_LIMIT { return Err("Those images are too large.".into()) }
    Ok(())
}

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
    /// Claude: Ultracode (standing dynamic-workflow orchestration at any effort level).
    #[serde(default)]
    pub ultracode: bool,
}

impl Settings {
    /// Refuse anything a CLI could read as another flag; modes come from a fixed list.
    pub fn validate(&self, agent: &str) -> Result<(), String> {
        for v in [&self.model, &self.effort].into_iter().flatten() {
            if v.is_empty() || v.starts_with('-') || v.chars().any(|c| c.is_whitespace() || c.is_control() || c == '"' || c == '\\') {
                return Err(format!("\"{v}\" is not a valid model or effort."));
            }
        }
        let modes = if agent == "codex" { CODEX_MODES } else { CLAUDE_MODES };
        if let Some(m) = self.mode.as_deref().filter(|m| !modes.contains(m)) {
            return Err(format!("\"{m}\" is not a mode the island can run {agent} in."));
        }
        if (self.fast || self.ultracode) && agent != "claude" {
            return Err("Fast mode and Ultracode are only available for Claude.".into());
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
            // One --settings layer carries both, so neither replaces the other.
            let mut extra = serde_json::Map::new();
            if self.fast { extra.insert("fastMode".into(), true.into()); }
            if self.ultracode { extra.insert("ultracode".into(), true.into()); }
            if !extra.is_empty() { flag("--settings", Value::Object(extra).to_string()) }
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
        let ultracode = self.ultracode.then(|| "Ultracode".to_string());
        [mode, model, effort, fast, ultracode].into_iter().flatten().collect::<Vec<_>>().join(" · ")
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
    /// User rows: how many images went with the message.
    pub images: usize,
    pub rev: u64,
    #[serde(skip)]
    key: String,
}

impl Entry {
    fn new(kind: &'static str, text: &str) -> Self {
        Entry { kind, text: text.into(), name: String::new(), input: String::new(), output: String::new(), status: "done", caption: String::new(), images: 0, rev: 0, key: String::new() }
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

    pub fn user(&mut self, text: &str, caption: String, images: usize) {
        let mut e = Entry::new("user", text);
        e.caption = caption;
        e.images = images;
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
                    let raw = v["result"].as_str().or(v["subtype"].as_str()).unwrap_or("The agent stopped with an error.");
                    let why = if raw.contains("authenticate") || raw.contains("/login") { SIGNED_OUT } else { raw };
                    // The CLI also echoes the failure as an assistant message; turn that into the one error row.
                    match self.entries.iter().rposition(|e| e.kind == "assistant") {
                        Some(i) if self.entries[i].text.trim() == raw.trim() => {
                            let e = self.touch(i);
                            e.kind = "error";
                            e.text = why.into();
                        }
                        _ => self.error(why),
                    }
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
    plans: PlanBook,
    planning_start: Option<usize>,
    native_plan: Option<String>,
    previous_mode: Option<String>,
    status: Status,
    error: Option<String>,
    pid: Option<i32>,
    stopping: bool,
    handoff: Option<Handoff>,
    handoff_error: Option<String>,
    handoff_token: u64,
    last: Option<Settings>,
    /// Claude's open stdin, for answers to its permission requests; closed once the turn's result arrives.
    stdin: Option<ChildStdin>,
    /// An AskUserQuestion waiting for the user.
    question: Option<Question>,
    /// Native approvals during a reviewed plan's implementation, without widening its mode.
    approval: Option<Permission>,
    executing_plan: bool,
}

struct Permission {
    request_id: String,
    tool: String,
    input: Value,
}

struct Question {
    request_id: String,
    input: Value,
}

/// Answer one of Claude's `control_request`s; a no-op once the turn's stdin is closed.
fn reply(g: &mut State, request_id: &str, body: Value) {
    if let Some(w) = g.stdin.as_mut() {
        let line = json!({"type": "control_response", "response": {"subtype": "success", "request_id": request_id, "response": body}});
        let _ = writeln!(w, "{line}");
    }
}

/// Questions and reviewed-plan implementation permissions wait for the user.
/// Plan exits are saved without authorizing execution; other permissions retain existing behavior.
fn control(g: &mut State, v: &Value) {
    if g.stopping { return; }
    if v["type"] == "control_cancel_request" {
        if g.question.as_ref().is_some_and(|q| Some(q.request_id.as_str()) == v["request_id"].as_str()) { g.question = None }
        if g.approval.as_ref().is_some_and(|a| Some(a.request_id.as_str()) == v["request_id"].as_str()) { g.approval = None }
        return;
    }
    let r = &v["request"];
    if r["subtype"] != "can_use_tool" { return }
    let id = v["request_id"].as_str().unwrap_or_default();
    // One card at a time; a second concurrent question is declined rather than lost.
    if r["tool_name"] == "ExitPlanMode" {
        if g.planning_start.is_none() {
            // An authoritative proposal can follow Claude entering Plan mode itself.
            g.previous_mode = g.last.as_ref().and_then(|s| s.mode.clone()).filter(|m| m != "plan");
            g.plans.begin();
            g.planning_start = Some(g.transcript.entries.len());
            if let Some(settings) = g.last.as_mut() { settings.mode = Some("plan".into()); }
        }
        if let Some(plan) = r["input"]["plan"].as_str() { g.native_plan = Some(plan.into()); }
        // Settle native approval without granting execution. Review happens after this process exits.
        reply(g, id, json!({"behavior": "deny", "message": "The plan is saved for review in Island. Stop here; do not implement or request approval again."}));
    } else if r["tool_name"] == "AskUserQuestion" && g.question.is_none() && g.approval.is_none() {
        g.question = Some(Question { request_id: id.into(), input: r["input"].clone() });
    } else if g.executing_plan && g.approval.is_none() && g.question.is_none() {
        g.approval = Some(Permission { request_id: id.into(), tool: r["tool_name"].as_str().unwrap_or("Tool").into(), input: r["input"].clone() });
    } else {
        let why = if r["tool_name"] == "AskUserQuestion" { "Another question is already open; ask one at a time." } else { "This chat can't ask for tool permission. Ask the user to pick a more permissive mode." };
        reply(g, id, json!({"behavior": "deny", "message": why}));
    }
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
            // The prompt goes in on stdin (it can carry images); stdio permission prompts are what let AskUserQuestion reach us.
            c.args(["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--include-partial-messages", "--permission-prompt-tool", "stdio"]);
            c.args(settings.args(agent));
            if let Some(s) = session {
                c.args(["--resume", s]);
            }
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
    c.current_dir(cwd).env("PATH", crate::pr::search_path(&bin)).stdin(if agent == "claude" { Stdio::piped() } else { Stdio::null() }).stdout(Stdio::piped()).stderr(Stdio::piped()).process_group(0);
    Ok(c)
}

impl Chats {
    pub fn start(&self, tools: &Tools, agent: &str, cwd: &str, text: &str, images: Vec<Image>, settings: Settings) -> Result<u64, String> {
        if text.trim().is_empty() && images.is_empty() {
            return Err("Write a message first.".into());
        }
        settings.validate(agent)?;
        check_images(agent, &images)?;
        if !std::path::Path::new(cwd).is_dir() {
            return Err(format!("{cwd} is not a folder."));
        }
        let id = {
            let mut n = self.next.lock().unwrap_or_else(|e| e.into_inner());
            *n += 1;
            *n
        };
        let title = if text.trim().is_empty() { "Image".to_string() } else { truncate(text.trim().lines().next().unwrap_or_default(), 60) };
        let chat = Arc::new(Chat {
            id,
            agent: agent.into(),
            cwd: cwd.into(),
            title,
            state: Mutex::new(State { transcript: Transcript::default(), plans: PlanBook::default(), planning_start: None, native_plan: None, previous_mode: None, status: Status::Idle, error: None, pid: None, stopping: false, handoff: None, handoff_error: None, handoff_token: 0, last: None, stdin: None, question: None, approval: None, executing_plan: false }),
        });
        self.list.lock().unwrap_or_else(|e| e.into_inner()).insert(id, chat.clone());
        Self::turn(tools, &chat, text, images, settings)?;
        Ok(id)
    }

    fn get(&self, id: u64) -> Result<Arc<Chat>, String> {
        self.list.lock().unwrap_or_else(|e| e.into_inner()).get(&id).cloned().ok_or_else(|| "That chat no longer exists.".into())
    }

    pub fn send(&self, tools: &Tools, id: u64, text: &str, images: Vec<Image>, settings: Settings) -> Result<(), String> {
        let chat = self.get(id)?;
        if text.trim().is_empty() && images.is_empty() {
            return Err("Write a message first.".into());
        }
        settings.validate(&chat.agent)?;
        check_images(&chat.agent, &images)?;
        Self::turn(tools, &chat, text, images, settings)
    }

    /// Answer the open AskUserQuestion (`answers` maps each question to its chosen label), or decline with None.
    pub fn answer(&self, id: u64, answers: Option<Value>) -> Result<(), String> {
        let chat = self.get(id)?;
        let mut g = chat.lock();
        let q = g.question.take().ok_or("No question is waiting.")?;
        let body = match answers {
            Some(a) => {
                let mut input = q.input;
                input["answers"] = a;
                json!({"behavior": "allow", "updatedInput": input})
            }
            None => json!({"behavior": "deny", "message": "The user chose not to answer."}),
        };
        reply(&mut g, &q.request_id, body);
        Ok(())
    }

    pub fn permission(&self, id: u64, request_id: &str, allow: bool) -> Result<(), String> {
        let chat = self.get(id)?;
        let mut g = chat.lock();
        if g.stopping || g.status != Status::Running || !g.approval.as_ref().is_some_and(|a| a.request_id == request_id) {
            return Err("That permission request is no longer active.".into());
        }
        let approval = g.approval.take().unwrap();
        let body = if allow { json!({"behavior":"allow", "updatedInput":approval.input}) }
            else { json!({"behavior":"deny", "message":"The user denied this tool request."}) };
        let line = json!({"type":"control_response", "response":{"subtype":"success", "request_id":request_id, "response":body}});
        let stdin = g.stdin.as_mut().ok_or("The agent is no longer accepting responses.")?;
        writeln!(stdin, "{line}").and_then(|_| stdin.flush()).map_err(|e| format!("Could not deliver the permission response: {e}. Stop this turn before retrying."))
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
                g.approval = None;
                g.question = None;
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
            "question": g.question.as_ref().map(|q| &q.input),
            "approval": g.approval.as_ref().map(|a| json!({"requestId":a.request_id,"tool":a.tool,"detail":serde_json::to_string_pretty(&a.input).unwrap_or_default()})),
            "plans": g.plans.documents(),
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

    pub fn plan_action(&self, tools: &Tools, id: u64, version: u64, action: &str, feedback: Option<&str>) -> Result<(), String> {
        let chat = self.get(id)?;
        if chat.agent != "claude" { return Err("Continue this plan in its source session.".into()); }
        Self::turn_inner(tools, &chat, "", vec![], Settings::default(), Some((version, action, feedback.unwrap_or_default())))
    }

    fn turn(tools: &Tools, chat: &Arc<Chat>, text: &str, images: Vec<Image>, settings: Settings) -> Result<(), String> {
        Self::turn_inner(tools, chat, text, images, settings, None)
    }

    fn turn_inner(tools: &Tools, chat: &Arc<Chat>, text: &str, images: Vec<Image>, mut settings: Settings, decision: Option<(u64, &str, &str)>) -> Result<(), String> {
        let mut text = text.to_string();
        let session = {
            let mut g = chat.lock();
            if g.handoff.is_some() {
                return Err("Continue this chat in its handoff destination, or cancel the queued handoff.".into());
            }
            if g.status == Status::Running {
                return Err("The agent is still working.".into());
            }
            if let Some((version, action, feedback)) = decision {
                g.plans.decide(version, action, feedback)?;
                if action == "reject" { return Ok(()); }
                let markdown = g.plans.documents().iter().find(|p| p.version == version).unwrap().markdown.clone();
                settings = g.last.clone().unwrap_or_default();
                if action == "implement" {
                    settings.mode = g.previous_mode.clone();
                    text = format!("Implement plan version {version} exactly as reviewed:\n\n{markdown}");
                } else {
                    settings.mode = Some("plan".into());
                    text = format!("Revise plan version {version}. Stay in planning mode; do not implement.\n\nReviewed plan:\n{markdown}\n\nFeedback:\n{feedback}");
                }
            }
            if decision.is_none() { g.plans.supersede_ready(); }
            if settings.mode.as_deref() == Some("plan") && g.last.as_ref().is_some_and(|s| s.mode.as_deref() != Some("plan")) {
                g.previous_mode = g.last.as_ref().and_then(|s| s.mode.clone());
            }
            g.transcript.turn += 1;
            // A change back to all-Default still shows, so the user sees that a choice was turned off.
            let caption = match (&g.last, settings.caption()) {
                (Some(prev), _) if prev == &settings => String::new(),
                (Some(_), c) if c.is_empty() => "Default".to_string(),
                (_, c) => c,
            };
            g.transcript.user(if decision.is_some_and(|(_, a, _)| a == "implement") { "Implement the plan." } else { &text }, caption, images.len());
            g.planning_start = None;
            g.native_plan = None;
            if chat.agent == "claude" && settings.mode.as_deref() == Some("plan") {
                g.plans.begin();
                g.planning_start = Some(g.transcript.entries.len());
            }
            g.last = Some(settings.clone());
            g.executing_plan = decision.is_some_and(|(_, action, _)| action == "implement");
            g.error = None;
            g.stopping = false;
            g.status = Status::Running;
            g.transcript.session_id.clone()
        };
        let spawned = command(tools, &chat.agent, &chat.cwd, &text, session.as_deref(), &settings).and_then(|mut c| {
            // Resuming Claude otherwise restores the session's saved Plan mode even with no flag.
            if decision.is_some_and(|(_, a, _)| a == "implement") && settings.mode.is_none() {
                c.args(["--permission-mode", "default"]);
            }
            c.spawn().map_err(|e| e.to_string())
        });
        let mut child = match spawned {
            Ok(c) => c,
            Err(e) => {
                let mut g = chat.lock();
                g.transcript.error(&e);
                g.error = Some(e.clone());
                g.status = Status::Failed;
                g.planning_start = None;
                g.plans.finish(None);
                if let Some((version, _, _)) = decision { g.plans.launch_failed(version, &e); return Err(e); }
                return Ok(());
            },
        };
        {
            let mut g = chat.lock();
            g.pid = Some(child.id() as i32);
            if g.stopping {
                unsafe { libc::kill(-(child.id() as i32), libc::SIGTERM) };
            }
        }
        let (out, mut err) = (child.stdout.take().unwrap(), child.stderr.take().unwrap());
        let mut stdin = child.stdin.take();
        let (chat, text) = (chat.clone(), text.to_string());
        std::thread::spawn(move || {
            if let Some(w) = stdin.as_mut() {
                let mut content: Vec<Value> = images.iter().map(|i| json!({"type": "image", "source": {"type": "base64", "media_type": i.media_type, "data": i.data}})).collect();
                if !text.trim().is_empty() { content.push(json!({"type": "text", "text": text})) }
                let line = json!({"type": "user", "message": {"role": "user", "content": content}});
                let _ = writeln!(w, "{line}").and_then(|_| w.flush());
            }
            chat.lock().stdin = stdin;
            let stderr = std::thread::spawn(move || {
                let mut s = String::new();
                let _ = err.by_ref().take(64_000).read_to_string(&mut s);
                let _ = std::io::copy(&mut err, &mut std::io::sink()); // keep draining so a chatty agent never blocks on a full pipe
                s
            });
            let mut finished = false;
            let mut plan_success = false;
            for line in BufReader::new(out).lines().map_while(Result::ok) {
                let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
                let mut g = chat.lock();
                if matches!(v["type"].as_str(), Some("control_request" | "control_cancel_request")) {
                    control(&mut g, &v);
                    continue;
                }
                if v["type"] == "assistant" {
                    for b in v["message"]["content"].as_array().into_iter().flatten() {
                        if b["name"] == "ExitPlanMode" { if let Some(p) = b["input"]["plan"].as_str() { g.native_plan = Some(p.into()); } }
                    }
                }
                if v["type"] == "result" { plan_success = v["is_error"] == false && v["subtype"].as_str().is_none_or(|s| s == "success"); }
                finished |= if chat.agent == "claude" { g.transcript.apply_claude(&v) } else { g.transcript.apply_codex(&v) };
                if let Some(start) = g.planning_start {
                    let markdown = g.native_plan.clone().unwrap_or_else(|| g.transcript.entries[start..].iter().filter(|e| e.kind == "assistant").map(|e| e.text.as_str()).collect::<Vec<_>>().join("\n\n"));
                    g.plans.update(&markdown);
                }
                if finished { g.stdin = None } // closing stdin lets `claude -p` exit
            }
            let code = child.wait().ok().and_then(|s| s.code());
            let stderr = stderr.join().unwrap_or_default();
            let mut g = chat.lock();
            g.pid = None;
            g.stdin = None;
            g.question = None;
            g.approval = None;
            g.executing_plan = false;
            if g.planning_start.take().is_some() {
                // Like Claude Code, the plan appears once, after the turn; a failed turn's output is never a plan.
                let success = plan_success && finished && code == Some(0) && !g.stopping && g.plans.has_draft();
                let anchor = success.then(|| g.transcript.push(Entry::new("plan", "")));
                g.plans.finish(anchor);
            }
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

}
