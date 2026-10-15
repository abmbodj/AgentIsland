//! Model menus for the composer: what each installed CLI says it can run.
use crate::pr::Tools;
use serde::Serialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::process::CommandExt;
use std::process::{ChildStdout, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

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

/// A model's label with its version: some CLI builds report a bare family ("Opus") as `displayName`
/// and lead the description with the versioned name ("Opus 5.5 · Best for…").
fn claude_name(m: &Value, id: &str) -> String {
    let name = m["displayName"].as_str().unwrap_or(id);
    let lead = m["description"].as_str().and_then(|d| d.split(" · ").next()).unwrap_or_default();
    if lead.len() > name.len() && lead.starts_with(name) { lead.into() } else { name.into() }
}

/// Models from Claude Code's `initialize` control response, minus its own default entry
/// (the composer has its own Default, which passes no flag).
pub fn parse_claude(response: &Value) -> Vec<ModelOption> {
    response["models"].as_array().into_iter().flatten()
        .filter_map(|m| {
            let id = m["value"].as_str().filter(|v| !v.is_empty() && !v.eq_ignore_ascii_case("default"))?;
            Some(ModelOption {
                id: id.into(),
                name: claude_name(m, id),
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
