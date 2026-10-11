//! Wire format between `island-hook` and the core: one JSON line each way over a local socket.
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcInfo {
    pub pid: i32,
    pub comm: String,
}

/// Hook → core. `agent` is "claude" | "codex" | "statusline" | "query".
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HookMessage {
    pub v: u32,
    pub agent: String,
    /// Raw stdin from the agent, untouched (the core does all parsing).
    #[serde(default)]
    pub payload: String,
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    #[serde(default)]
    pub tty: Option<String>,
    /// Hook's own process first, then ancestors.
    #[serde(default)]
    pub pids: Vec<ProcInfo>,
}

/// Core → hook: exactly what the hook prints to stdout (empty = no decision).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct HookReply {
    pub stdout: String,
}
