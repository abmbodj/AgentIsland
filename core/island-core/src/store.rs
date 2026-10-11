//! Session store and state machine: the single source of truth for every session's state.
use crate::protocol::HookMessage;
use serde::Serialize;
use serde_json::Value;

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
    pub input: Value,
    pub since: Millis,
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
    pub fn handle(&mut self, msg: &HookMessage, now: Millis) {
        let Ok(p) = serde_json::from_str::<Value>(&msg.payload) else { return };
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
            return;
        }
        let Some(id) = p["session_id"].as_str() else { return };
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
                s.pending.clear();
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
                s.pending.clear();
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
                s.pending.push(Attention { id: attention_id, tool: tool.into(), input: p["tool_input"].clone(), since: now });
                s.set(State::NeedsInput, now);
            }
            "PostToolUse" | "PostToolUseFailure" => {
                if let Some(i) = s.pending.iter().position(|a| a.tool == tool && a.input == p["tool_input"]) {
                    s.pending.remove(i);
                }
                if s.pending.is_empty() && s.state == State::NeedsInput {
                    s.set(State::Working, now);
                }
            }
            "Stop" => {
                s.pending.clear();
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
                s.pending.clear();
                s.set(State::Error, now);
            }
            _ => {}
        }
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
                s.pending.clear();
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
