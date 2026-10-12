//! Session store and state machine: the single source of truth for every session's state.
use crate::diff::{self, DiffPreview};
use crate::protocol::HookMessage;
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::BTreeMap;

pub type Millis = u64;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum State {
    Working,
    Idle,
    NeedsInput,
    Finished,
    Ended,
    Error,
    Stale,
}

/// Something the user must answer: a permission or a question.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Attention {
    pub id: u64,
    pub tool: String,
    /// Raw tool input (can be a whole file for Write); kept for the reply, never sent to the UI.
    #[serde(skip)]
    pub input: Value,
    pub since: Millis,
    /// "approval" | "question"
    pub kind: String,
    /// "Run command", "Edit auth.ts", "Question"
    pub title: String,
    /// The command, path or URL being approved.
    pub detail: String,
    pub diff: Option<DiffPreview>,
    pub questions: Vec<Question>,
    pub can_allow_session: bool,
    /// A hook is waiting on our answer (otherwise the card can only hand off to the agent).
    pub held: bool,
    /// Which subagent asked, if not the main agent.
    pub subagent: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Question {
    pub question: String,
    pub header: String,
    pub options: Vec<QuestionOption>,
    pub multi_select: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuestionOption {
    pub label: String,
    pub description: String,
}

/// The user's response to an attention item.
#[derive(Debug, Clone, PartialEq)]
pub enum Answer {
    Allow,
    Deny,
    AllowSession,
    /// question text → chosen label(s) or free text
    Answers(BTreeMap<String, String>),
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Session {
    pub id: String,
    pub agent: String,
    pub cwd: String,
    pub project: String,
    pub state: State,
    pub activity: String,
    /// When the current state began (turn start while Working).
    pub since: Millis,
    pub pending: Vec<Attention>,
    pub subagents: Vec<Subagent>,
    /// The agent process, watched for exit.
    pub pid: Option<i32>,
    pub terminal: Terminal,
    pub last_event: Millis,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Subagent {
    pub id: String,
    pub kind: String,
    pub activity: String,
    pub done: bool,
    pub since: Millis,
}

/// Everything needed to find the session's terminal tab/pane later.
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Terminal {
    pub program: Option<String>,
    pub bundle_id: Option<String>,
    pub tty: Option<String>,
    pub tmux: Option<String>,
    pub tmux_pane: Option<String>,
    pub iterm_session: Option<String>,
    pub term_session: Option<String>,
    /// Hook's ancestors, nearest first.
    pub pids: Vec<i32>,
}

impl Terminal {
    fn from(msg: &HookMessage) -> Self {
        let e = |k: &str| msg.env.get(k).filter(|v| !v.is_empty()).cloned();
        Terminal {
            program: e("TERM_PROGRAM"),
            bundle_id: e("__CFBundleIdentifier"),
            tty: msg.tty.clone(),
            tmux: e("TMUX"),
            tmux_pane: e("TMUX_PANE"),
            iterm_session: e("ITERM_SESSION_ID"),
            term_session: e("TERM_SESSION_ID"),
            pids: msg.pids.iter().map(|p| p.pid).collect(),
        }
    }
}

pub const ENDED_GRACE: Millis = 10_000;
pub const STALE_AFTER: Millis = 30 * 60_000;
pub const STALE_DROP: Millis = 2 * 60 * 60_000;
pub const SUBAGENT_FADE: Millis = 1_500;

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub sessions: Vec<Session>,
    /// Total items waiting for the user, across sessions.
    pub attention: usize,
    pub usage: Usage,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Usage {
    pub claude: Option<AgentUsage>,
    pub codex: Option<AgentUsage>,
}

/// Rate-limit windows exactly as last reported by the agent. Never extrapolated.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentUsage {
    pub observed_at: Millis,
    pub windows: Vec<LimitWindow>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LimitWindow {
    pub label: String,
    pub used_percent: f64,
    pub resets_at: Millis,
}

#[derive(Default)]
pub struct Store {
    sessions: Vec<Session>,
    usage: Usage,
    next_id: u64,
    /// Replies owed to waiting hooks: (attention id, exact stdout). Drained by the server.
    replies: Vec<(u64, String)>,
}

/// Withdraw every pending item, releasing waiting hooks with an empty (no-decision) reply.
fn clear_pending(s: &mut Session, replies: &mut Vec<(u64, String)>) {
    for a in s.pending.drain(..) {
        if a.held {
            replies.push((a.id, String::new()));
        }
    }
}

impl Session {
    fn set(&mut self, state: State, now: Millis) {
        if self.state != state {
            self.state = state;
            self.since = now;
        }
    }
}

impl Store {
    /// Apply one hook event. Returns an attention id when the hook must wait for the user's answer.
    pub fn handle(&mut self, msg: &HookMessage, now: Millis) -> Option<u64> {
        let Ok(p) = serde_json::from_str::<Value>(&msg.payload) else { return None };
        if msg.agent == "statusline" {
            let windows: Vec<LimitWindow> = [("five_hour", "5h"), ("seven_day", "7d")]
                .iter()
                .filter_map(|(key, label)| {
                    let w = &p["rate_limits"][key];
                    Some(LimitWindow {
                        label: label.to_string(),
                        used_percent: w["used_percentage"].as_f64()?,
                        resets_at: w["resets_at"].as_u64()? * 1000,
                    })
                })
                .filter(|w| w.resets_at > now)
                .collect();
            if !windows.is_empty() {
                self.usage.claude = Some(AgentUsage { observed_at: now, windows });
            }
            return None;
        }
        let Some(id) = p["session_id"].as_str() else { return None };
        let idx = match self.sessions.iter().position(|s| s.id == id && s.agent == msg.agent) {
            Some(i) => i,
            None => {
                let cwd = p["cwd"].as_str().unwrap_or_default().to_string();
                let project = cwd.rsplit('/').find(|s| !s.is_empty()).unwrap_or("").to_string();
                self.sessions.push(Session {
                    id: id.to_string(),
                    agent: msg.agent.clone(),
                    cwd,
                    project,
                    state: State::Idle,
                    activity: String::new(),
                    since: now,
                    pending: vec![],
                    subagents: vec![],
                    pid: None,
                    terminal: Terminal::default(),
                    last_event: now,
                });
                self.sessions.len() - 1
            }
        };
        self.next_id += 1;
        let attention_id = self.next_id;
        let replies = &mut self.replies;
        let s = &mut self.sessions[idx];
        let tool = p["tool_name"].as_str().unwrap_or_default();
        let agent_id = p["agent_id"].as_str();
        s.last_event = now;
        s.terminal = Terminal::from(msg);
        if let Some(pid) = msg.env.get("CLAUDE_PID").and_then(|v| v.parse().ok()) {
            s.pid = Some(pid);
        }

        match p["hook_event_name"].as_str().unwrap_or_default() {
            "SessionStart" => {
                if matches!(s.state, State::Ended | State::Error | State::Stale) {
                    s.set(State::Idle, now);
                }
            }
            "SessionEnd" => {
                clear_pending(s, replies);
                s.set(State::Ended, now);
            }
            "SubagentStart" => {
                if let Some(aid) = agent_id {
                    let kind = p["agent_type"].as_str().unwrap_or_default().to_string();
                    s.subagents.push(Subagent { id: aid.into(), kind, activity: "Starting".into(), done: false, since: now });
                }
            }
            "SubagentStop" => {
                if let Some(sub) = s.subagents.iter_mut().find(|a| Some(a.id.as_str()) == agent_id) {
                    sub.done = true;
                    sub.since = now;
                }
            }
            "UserPromptSubmit" => {
                clear_pending(s, replies);
                s.state = State::Working;
                s.since = now;
                s.activity = "Thinking".into();
            }
            "PreToolUse" => {
                if s.state != State::NeedsInput {
                    s.set(State::Working, now);
                }
                let label = activity_label(tool, &p["tool_input"]);
                match agent_id {
                    None => s.activity = label,
                    Some(aid) => {
                        if let Some(sub) = s.subagents.iter_mut().find(|a| a.id == aid) {
                            sub.activity = label;
                        }
                    }
                }
            }
            "PermissionRequest" => {
                let subagent = agent_id.map(|aid| {
                    s.subagents.iter().find(|a| a.id == aid).map(|a| a.kind.clone())
                        .unwrap_or_else(|| p["agent_type"].as_str().unwrap_or("Subagent").to_string())
                });
                s.pending.push(attention(attention_id, tool, &p["tool_input"], now, subagent));
                s.set(State::NeedsInput, now);
                return Some(attention_id);
            }
            "PostToolUse" | "PostToolUseFailure" => {
                // Answered in the terminal: free the hook that is still waiting on us.
                if let Some(i) = s.pending.iter().position(|a| a.tool == tool && a.input == p["tool_input"]) {
                    let a = s.pending.remove(i);
                    if a.held {
                        replies.push((a.id, String::new()));
                    }
                }
                if s.pending.is_empty() && s.state == State::NeedsInput {
                    s.set(State::Working, now);
                }
            }
            "Stop" => {
                clear_pending(s, replies);
                let running = p["background_tasks"]
                    .as_array()
                    .map_or(0, |t| t.iter().filter(|t| t["status"] == "running").count());
                if running > 0 {
                    s.set(State::Working, now);
                    s.activity = format!("Waiting for {running} agent{}", if running == 1 { "" } else { "s" });
                } else {
                    s.set(State::Finished, now);
                }
            }
            "StopFailure" => {
                clear_pending(s, replies);
                s.set(State::Error, now);
            }
            _ => {}
        }
        None
    }

    fn take(&mut self, id: u64) -> Option<(usize, Attention)> {
        for (si, s) in self.sessions.iter_mut().enumerate() {
            if let Some(i) = s.pending.iter().position(|a| a.id == id) {
                return Some((si, s.pending.remove(i)));
            }
        }
        None
    }

    fn after_resolve(&mut self, si: usize, now: Millis) {
        let s = &mut self.sessions[si];
        if s.pending.is_empty() && s.state == State::NeedsInput {
            s.set(State::Working, now);
        }
    }

    /// The user answered from the island. Unknown / already-resolved ids are ignored.
    pub fn answer(&mut self, id: u64, answer: Answer, now: Millis) {
        let Some((si, a)) = self.take(id) else { return };
        if a.held {
            let agent = self.sessions[si].agent.clone();
            self.replies.push((id, reply_for(&agent, &a, &answer)));
        }
        self.after_resolve(si, now);
    }

    /// The waiting hook disappeared (the agent cancelled it, e.g. Esc in the terminal).
    pub fn hook_gone(&mut self, id: u64, now: Millis) {
        if let Some((si, _)) = self.take(id) {
            self.after_resolve(si, now);
        }
    }

    /// Stop waiting on this item's hook (it was released empty); the card stays as a handoff.
    pub fn detach(&mut self, id: u64) {
        for s in &mut self.sessions {
            for a in s.pending.iter_mut().filter(|a| a.id == id) {
                a.held = false;
            }
        }
    }

    /// Replies owed to waiting hooks since the last call.
    pub fn take_replies(&mut self) -> Vec<(u64, String)> {
        std::mem::take(&mut self.replies)
    }

    fn find(&mut self, agent: &str, id: &str) -> Option<&mut Session> {
        self.sessions.iter_mut().find(|s| s.agent == agent && s.id == id)
    }

    /// The user looked at the session (jumped to it, or its row was visible in the panel).
    pub fn viewed(&mut self, agent: &str, id: &str, now: Millis) {
        if let Some(s) = self.find(agent, id) {
            if s.state == State::Finished {
                s.set(State::Idle, now);
            }
        }
    }

    pub fn process_exited(&mut self, pid: i32, now: Millis) {
        for s in self.sessions.iter_mut().filter(|s| s.pid == Some(pid)) {
            let mid_turn = matches!(s.state, State::Working | State::NeedsInput);
            if !matches!(s.state, State::Ended | State::Error) {
                clear_pending(s, &mut self.replies);
                s.set(if mid_turn { State::Error } else { State::Ended }, now);
            }
        }
    }

    /// Apply time-based transitions. Call at (or after) `next_deadline()`.
    pub fn tick(&mut self, now: Millis) {
        for s in &mut self.sessions {
            if s.state == State::Working && s.pid.is_none() && now >= s.last_event + STALE_AFTER {
                s.state = State::Stale;
                s.since = s.last_event + STALE_AFTER;
            }
            s.subagents.retain(|a| !(a.done && now >= a.since + SUBAGENT_FADE));
        }
        for u in [&mut self.usage.claude, &mut self.usage.codex] {
            if let Some(a) = u {
                a.windows.retain(|w| now < w.resets_at);
                if a.windows.is_empty() {
                    *u = None;
                }
            }
        }
        self.sessions.retain(|s| match s.state {
            State::Ended | State::Error => now < s.since + ENDED_GRACE,
            State::Stale => now < s.since + STALE_DROP,
            _ => true,
        });
    }

    /// The earliest moment `tick` could change something; `None` = nothing scheduled.
    pub fn next_deadline(&self) -> Option<Millis> {
        let mut d: Vec<Millis> = vec![];
        for s in &self.sessions {
            match s.state {
                State::Ended | State::Error => d.push(s.since + ENDED_GRACE),
                State::Stale => d.push(s.since + STALE_DROP),
                State::Working if s.pid.is_none() => d.push(s.last_event + STALE_AFTER),
                _ => {}
            }
            d.extend(s.subagents.iter().filter(|a| a.done).map(|a| a.since + SUBAGENT_FADE));
        }
        for u in [&self.usage.claude, &self.usage.codex].into_iter().flatten() {
            d.extend(u.windows.iter().map(|w| w.resets_at));
        }
        d.into_iter().min()
    }

    pub fn snapshot(&self) -> Snapshot {
        Snapshot {
            sessions: self.sessions.clone(),
            attention: self.sessions.iter().map(|s| s.pending.len()).sum(),
            usage: self.usage.clone(),
        }
    }
}

fn attention(id: u64, tool: &str, input: &Value, now: Millis, subagent: Option<String>) -> Attention {
    let file = |v: &Value| basename(v).to_string();
    let path = input["file_path"].as_str().or(input["notebook_path"].as_str()).unwrap_or_default().to_string();
    let compact = || {
        let t = input.to_string();
        if t.chars().count() > 300 { format!("{}…", t.chars().take(300).collect::<String>()) } else { t }
    };
    let (kind, title, detail) = match tool {
        "AskUserQuestion" => ("question", "Question".to_string(), String::new()),
        "Bash" => ("approval", "Run command".to_string(), input["command"].as_str().unwrap_or_default().to_string()),
        "Edit" | "MultiEdit" => ("approval", format!("Edit {}", file(&input["file_path"])), path),
        "Write" => {
            let verb = if std::path::Path::new(&path).exists() { "Write" } else { "Create" };
            ("approval", format!("{verb} {}", file(&input["file_path"])), path)
        }
        "NotebookEdit" => ("approval", format!("Edit notebook {}", file(&input["notebook_path"])), path),
        "WebFetch" => {
            let url = input["url"].as_str().unwrap_or_default();
            ("approval", format!("Fetch {}", url.split("://").nth(1).unwrap_or(url).split('/').next().unwrap_or_default()), url.to_string())
        }
        "ExitPlanMode" => ("approval", "Start on this plan".to_string(), input["plan"].as_str().unwrap_or_default().to_string()),
        t if t.starts_with("mcp__") => {
            let mut parts = t.splitn(3, "__").skip(1);
            let (server, name) = (parts.next().unwrap_or_default(), parts.next().unwrap_or_default());
            ("approval", format!("Use {name} ({server})"), compact())
        }
        t => ("approval", format!("Use {t}"), compact()),
    };
    let questions = input["questions"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|q| Question {
            question: q["question"].as_str().unwrap_or_default().into(),
            header: q["header"].as_str().unwrap_or_default().into(),
            options: q["options"]
                .as_array()
                .into_iter()
                .flatten()
                .map(|o| QuestionOption {
                    label: o["label"].as_str().unwrap_or_default().into(),
                    description: o["description"].as_str().unwrap_or_default().into(),
                })
                .collect(),
            multi_select: q["multiSelect"].as_bool().unwrap_or(false),
        })
        .collect();
    Attention {
        id,
        tool: tool.into(),
        input: input.clone(),
        since: now,
        kind: kind.into(),
        title,
        detail,
        diff: diff::preview(tool, input),
        questions,
        can_allow_session: kind == "approval" && tool != "ExitPlanMode",
        held: true,
        subagent,
    }
}

/// Exact stdout for the agent's waiting hook.
fn reply_for(agent: &str, a: &Attention, answer: &Answer) -> String {
    let _ = agent; // Codex uses the same PermissionRequest shape (allow/deny only).
    let decision = match answer {
        Answer::Allow => json!({"behavior": "allow"}),
        Answer::Deny => json!({"behavior": "deny", "message": "Denied from Agent Island"}),
        Answer::AllowSession => {
            let mut rule = json!({"toolName": a.tool});
            if a.tool == "Bash" {
                rule["ruleContent"] = a.input["command"].clone();
            }
            json!({"behavior": "allow", "updatedPermissions": [
                {"type": "addRules", "rules": [rule], "behavior": "allow", "destination": "session"}]})
        }
        Answer::Answers(map) => {
            let mut input = a.input.clone();
            input["answers"] = json!(map);
            json!({"behavior": "allow", "updatedInput": input})
        }
    };
    json!({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": decision}}).to_string()
}

fn basename(path: &Value) -> &str {
    path.as_str().unwrap_or_default().rsplit('/').next().unwrap_or_default()
}

/// "Editing auth.ts", "Running `npm test`", ...
pub fn activity_label(tool: &str, input: &Value) -> String {
    match tool {
        "Bash" => {
            let cmd = input["command"].as_str().unwrap_or_default().lines().next().unwrap_or_default();
            const MAX: usize = 32;
            if cmd.chars().count() > MAX {
                format!("Running `{}…`", cmd.chars().take(MAX).collect::<String>().trim_end())
            } else {
                format!("Running `{cmd}`")
            }
        }
        "Edit" | "MultiEdit" | "Write" | "NotebookEdit" => {
            format!("Editing {}", basename(input.get("file_path").or(input.get("notebook_path")).unwrap_or(&Value::Null)))
        }
        "Read" => format!("Reading {}", basename(&input["file_path"])),
        "Grep" | "Glob" | "LS" => "Searching".into(),
        "WebSearch" => "Searching the web".into(),
        "WebFetch" => {
            let url = input["url"].as_str().unwrap_or_default();
            let host = url.split("://").nth(1).unwrap_or(url).split('/').next().unwrap_or_default();
            format!("Fetching {host}")
        }
        "Agent" | "Task" => format!("Delegating to {}", input["subagent_type"].as_str().unwrap_or("an agent")),
        "AskUserQuestion" => "Asking a question".into(),
        "TodoWrite" => "Planning".into(),
        t if t.starts_with("mcp__") => format!("Using {}", t.split("__").nth(1).unwrap_or(t)),
        t => t.to_string(),
    }
}
