//! Integration files on disk: consent plans with diffs, backups, hashes, drift-aware uninstall.
use crate::installer::{self, ClaudeParts};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanItem {
    pub id: String,
    pub title: String,
    pub path: String,
    pub diff: String,
    /// Caveat shown under the item (e.g. trust must be confirmed in Codex).
    pub note: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UninstallItem {
    pub path: String,
    /// The file changed since we wrote it; surgical removal keeps those changes.
    pub drifted: bool,
    pub diff: String,
    pub exact_diff: String,
    pub backup_date: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum UninstallMode {
    Surgical,
    ExactBackup,
}

#[derive(Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct FileRecord {
    existed: bool,
    backup: String,
    written_sha: String,
    installed_at: u64,
    /// "json-hooks" (Claude settings / Codex hooks.json) or "toml-block" (Codex trust).
    #[serde(default)]
    kind: String,
    /// For toml-block files: exactly what we appended.
    #[serde(default)]
    appended: Option<String>,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct Manifest {
    files: BTreeMap<String, FileRecord>,
}

pub struct Integrations {
    support: PathBuf,
    home: PathBuf,
}

fn sha(b: &[u8]) -> String {
    Sha256::digest(b).iter().map(|x| format!("{x:02x}")).collect()
}

fn now_secs() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs())
}

pub fn diff(path: &str, before: Option<&str>, after: Option<&str>) -> String {
    similar::TextDiff::from_lines(before.unwrap_or(""), after.unwrap_or(""))
        .unified_diff()
        .context_radius(2)
        .header(path, path)
        .to_string()
}

/// Write via temp file + rename so a crash never leaves a half-written config.
fn write_atomic(path: &Path, text: &str) -> Result<(), String> {
    let tmp = path.with_extension("agentisland-tmp");
    fs::write(&tmp, text).map_err(|e| e.to_string())?;
    if let Ok(meta) = fs::metadata(path) {
        let _ = fs::set_permissions(&tmp, meta.permissions());
    }
    fs::rename(&tmp, path).map_err(|e| e.to_string())
}

// MARK: Codex app-server helpers (Codex computes its own hook trust hashes)

/// The user's `codex` CLI, or the one bundled in the Codex desktop app.
pub fn find_codex() -> Option<PathBuf> {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    [
        home.join(".local/bin/codex"),
        PathBuf::from("/opt/homebrew/bin/codex"),
        PathBuf::from("/usr/local/bin/codex"),
        PathBuf::from("/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"),
        PathBuf::from("/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex"),
    ]
    .into_iter()
    .find(|p| p.is_file())
}

/// One request to a throwaway stdio `codex app-server` for `codex_home`.
fn app_server_call(codex: &Path, codex_home: &Path, method: &str, params: Value) -> Result<Value, String> {
    let mut child = Command::new(codex)
        .arg("app-server")
        .env("CODEX_HOME", codex_home)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("couldn't start codex: {e}"))?;
    let mut stdin = child.stdin.take().unwrap();
    let stdout = child.stdout.take().unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if let Ok(v) = serde_json::from_str::<Value>(&line) {
                if v["id"] == 1 || v["id"] == 2 {
                    let _ = tx.send(v);
                }
            }
        }
    });
    let init = json!({"id": 1, "method": "initialize", "params": {"clientInfo": {"name": "agent-island", "version": env!("CARGO_PKG_VERSION")}, "capabilities": {}}});
    writeln!(stdin, "{init}").map_err(|e| e.to_string())?;
    let result = (|| {
        rx.recv_timeout(Duration::from_secs(15)).map_err(|_| "codex app-server didn't start".to_string())?;
        writeln!(stdin, "{}", json!({"method": "initialized"})).map_err(|e| e.to_string())?;
        writeln!(stdin, "{}", json!({"id": 2, "method": method, "params": params})).map_err(|e| e.to_string())?;
        let r = rx.recv_timeout(Duration::from_secs(15)).map_err(|_| format!("{method} timed out"))?;
        r.get("result").cloned().ok_or_else(|| format!("{method}: {}", r["error"]))
    })();
    let _ = child.kill();
    let _ = child.wait();
    result
}

/// Codex's trust hash for each of our hook groups, keyed by event label ("pre_tool_use").
/// Computed by Codex itself from a scratch CODEX_HOME holding only our hooks (hashes are path-independent).
pub fn codex_hashes(codex: &Path, our_hooks_json: &str, scratch: &Path) -> Result<HashMap<String, String>, String> {
    let _ = fs::remove_dir_all(scratch);
    fs::create_dir_all(scratch).map_err(|e| e.to_string())?;
    fs::write(scratch.join("hooks.json"), our_hooks_json).map_err(|e| e.to_string())?;
    fs::write(scratch.join("config.toml"), "").map_err(|e| e.to_string())?;
    let r = app_server_call(codex, scratch, "hooks/list", json!({"cwds": [scratch]}));
    let _ = fs::remove_dir_all(scratch);
    let mut out = HashMap::new();
    for entry in r?["data"].as_array().into_iter().flatten() {
        for h in entry["hooks"].as_array().into_iter().flatten() {
            let key = h["key"].as_str().unwrap_or_default();
            let mut parts = key.rsplitn(4, ':');
            let (_, _, label) = (parts.next(), parts.next(), parts.next());
            if let (Some(label), Some(hash)) = (label, h["currentHash"].as_str()) {
                out.insert(label.to_string(), hash.to_string());
            }
        }
    }
    Ok(out)
}

/// Trust status ("trusted", "untrusted", "modified") of every hook in `<codex_home>/hooks.json`.
pub fn codex_hook_status(codex: &Path, codex_home: &Path) -> Result<Vec<String>, String> {
    let r = app_server_call(codex, codex_home, "hooks/list", json!({"cwds": [codex_home]}))?;
    let file = fs::canonicalize(codex_home.join("hooks.json")).map_err(|e| e.to_string())?;
    let prefix = format!("{}:", file.to_string_lossy());
    Ok(r["data"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|e| e["hooks"].as_array().cloned().unwrap_or_default())
        .filter(|h| h["key"].as_str().is_some_and(|k| k.starts_with(&prefix)))
        .map(|h| h["trustStatus"].as_str().unwrap_or_default().to_string())
        .collect())
}

// MARK: Integrations

/// What one consent item would write: (path, kind, new text, appended block).
struct Change {
    path: PathBuf,
    kind: &'static str,
    after: String,
    appended: Option<String>,
}

impl Integrations {
    pub fn new(support: PathBuf, home: PathBuf) -> Self {
        Integrations { support, home }
    }

    pub fn hook_path(&self) -> PathBuf {
        self.support.join("bin/island-hook")
    }

    fn claude_settings(&self) -> PathBuf {
        self.home.join(".claude/settings.json")
    }

    fn codex_home(&self) -> PathBuf {
        self.home.join(".codex")
    }

    fn manifest(&self) -> Manifest {
        fs::read_to_string(self.support.join("install-manifest.json"))
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default()
    }

    fn save_manifest(&self, m: &Manifest) -> Result<(), String> {
        fs::create_dir_all(&self.support).map_err(|e| e.to_string())?;
        write_atomic(&self.support.join("install-manifest.json"), &serde_json::to_string_pretty(m).unwrap())
    }

    fn hook(&self) -> String {
        self.hook_path().to_string_lossy().into_owned()
    }

    fn claude_changes(&self, parts: ClaudeParts) -> Result<Vec<Change>, String> {
        let path = self.claude_settings();
        let before = fs::read_to_string(&path).ok();
        let after = installer::install_claude(before.as_deref(), &self.hook(), parts)?;
        Ok(if before.as_deref() == Some(after.as_str()) { vec![] } else { vec![Change { path, kind: "json-hooks", after, appended: None }] })
    }

    /// hooks.json plus the trust block for config.toml. The trust part is skipped (with a note)
    /// if Codex can't compute hashes; Codex then asks the user to review the hooks in /hooks.
    fn codex_changes(&self) -> Result<(Vec<Change>, Option<String>), String> {
        let home = self.codex_home();
        let hooks_path = home.join("hooks.json");
        let before = fs::read_to_string(&hooks_path).ok();
        let after = installer::install_codex_hooks(before.as_deref(), &self.hook())?;
        if before.as_deref() == Some(after.as_str()) {
            return Ok((vec![], None));
        }
        let mut changes = vec![Change { path: hooks_path.clone(), kind: "json-hooks", after: after.clone(), appended: None }];
        let ours = installer::install_codex_hooks(None, &self.hook())?;
        let hashes = find_codex()
            .ok_or_else(|| "Codex CLI not found".to_string())
            .and_then(|c| codex_hashes(&c, &ours, &self.support.join("codex-trust-scratch")));
        let note = match hashes {
            Ok(hashes) => {
                // Keys use the canonical path, like Codex does.
                let canon = fs::canonicalize(&home).map(|h| h.join("hooks.json")).unwrap_or(hooks_path);
                let entries: Vec<(String, String)> = installer::codex_trust_keys(&after, &canon.to_string_lossy())
                    .into_iter()
                    .filter_map(|(label, key)| hashes.get(&label).map(|h| (key, h.clone())))
                    .collect();
                let block = installer::codex_config_block(&entries);
                let config = home.join("config.toml");
                let cbefore = fs::read_to_string(&config).ok();
                changes.push(Change { path: config, kind: "toml-block", after: installer::append_block(cbefore.as_deref(), &block), appended: Some(block) });
                None
            }
            Err(e) => Some(format!("Codex will ask you to trust these hooks (/hooks): {e}")),
        };
        Ok((changes, note))
    }

    fn item_changes(&self, id: &str) -> Result<(Vec<Change>, Option<String>), String> {
        match id {
            "claude-hooks" => Ok((self.claude_changes(ClaudeParts { hooks: true, statusline: false })?, None)),
            "claude-statusline" => Ok((self.claude_changes(ClaudeParts { hooks: false, statusline: true })?, None)),
            "codex-hooks" => self.codex_changes(),
            _ => Err(format!("unknown item {id}")),
        }
    }

    /// One item per consentable part, each with the diff it alone would cause. Empty = nothing to do.
    pub fn plan_install(&self) -> Vec<PlanItem> {
        let mut items = vec![
            ("claude-hooks", "Claude Code hooks"),
            ("claude-statusline", "Claude usage (status line pass-through)"),
        ];
        if self.codex_home().is_dir() {
            items.push(("codex-hooks", "Codex hooks"));
        }
        items
            .into_iter()
            .filter_map(|(id, title)| {
                let (changes, note) = self.item_changes(id).ok()?;
                let first = changes.first()?;
                let diff = changes
                    .iter()
                    .map(|c| {
                        let p = c.path.to_string_lossy();
                        diff(&p, fs::read_to_string(&c.path).ok().as_deref(), Some(&c.after))
                    })
                    .collect::<Vec<_>>()
                    .join("\n");
                Some(PlanItem { id: id.into(), title: title.into(), path: first.path.to_string_lossy().into(), diff, note })
            })
            .collect()
    }

    pub fn apply_install(&self, ids: &[&str]) -> Result<(), String> {
        // Claude's two parts edit one file: compute them together.
        let claude = ClaudeParts { hooks: ids.contains(&"claude-hooks"), statusline: ids.contains(&"claude-statusline") };
        let mut changes = vec![];
        if claude.hooks || claude.statusline {
            changes.extend(self.claude_changes(claude)?);
        }
        if ids.contains(&"codex-hooks") {
            changes.extend(self.codex_changes()?.0);
        }
        let mut m = self.manifest();
        for c in changes {
            let key = c.path.to_string_lossy().to_string();
            let before = fs::read_to_string(&c.path).ok();
            if !m.files.contains_key(&key) {
                // First install: keep the pristine original forever (until uninstall).
                fs::create_dir_all(self.support.join("backups")).map_err(|e| e.to_string())?;
                let name = c.path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                let backup = format!("backups/{}-{}-{}", c.kind, now_secs(), name);
                if let Some(b) = &before {
                    fs::write(self.support.join(&backup), b).map_err(|e| e.to_string())?;
                }
                m.files.insert(key.clone(), FileRecord { existed: before.is_some(), backup, installed_at: now_secs(), kind: c.kind.into(), ..Default::default() });
            }
            fs::create_dir_all(c.path.parent().unwrap()).map_err(|e| e.to_string())?;
            write_atomic(&c.path, &c.after)?;
            let r = m.files.get_mut(&key).unwrap();
            r.written_sha = sha(c.after.as_bytes());
            if let Some(a) = c.appended {
                r.appended = Some(r.appended.take().unwrap_or_default() + &a);
            }
        }
        self.save_manifest(&m)
    }

    fn original(&self, r: &FileRecord) -> Result<Option<String>, String> {
        if !r.existed {
            return Ok(None);
        }
        fs::read_to_string(self.support.join(&r.backup)).map(Some).map_err(|e| format!("backup missing: {e}"))
    }

    /// Our entries removed from a file that changed after we wrote it.
    fn surgical(r: &FileRecord, current: &str, original: Option<&str>) -> Result<Option<String>, String> {
        match r.kind.as_str() {
            "toml-block" => Ok(Some(
                r.appended.as_deref().and_then(|b| installer::remove_block(current, b)).unwrap_or_else(|| current.to_string()),
            )),
            _ => installer::uninstall_claude(current, original),
        }
    }

    pub fn plan_uninstall(&self) -> Vec<UninstallItem> {
        self.manifest()
            .files
            .iter()
            .filter_map(|(path, r)| {
                let current = fs::read_to_string(path).ok();
                let original = self.original(r).ok()?;
                let drifted = current.as_deref().map(|c| sha(c.as_bytes())) != Some(r.written_sha.clone());
                let surgical = match (&current, drifted) {
                    (_, false) | (None, _) => original.clone(),
                    (Some(c), true) => Self::surgical(r, c, original.as_deref()).ok()?,
                };
                Some(UninstallItem {
                    path: path.clone(),
                    drifted,
                    diff: diff(path, current.as_deref(), surgical.as_deref()),
                    exact_diff: diff(path, current.as_deref(), original.as_deref()),
                    backup_date: r.installed_at,
                })
            })
            .collect()
    }

    pub fn apply_uninstall(&self, mode: UninstallMode) -> Result<(), String> {
        let mut m = self.manifest();
        for (path, r) in &m.files {
            let p = Path::new(path);
            let current = fs::read_to_string(p).ok();
            let original = self.original(r)?;
            let undrifted = current.as_deref().map(|c| sha(c.as_bytes())) == Some(r.written_sha.clone());
            let target = match (mode, undrifted, &current) {
                (UninstallMode::ExactBackup, _, _) | (_, true, _) | (_, _, None) => original,
                (UninstallMode::Surgical, false, Some(c)) => Self::surgical(r, c, original.as_deref())?,
            };
            match target {
                Some(t) => write_atomic(p, &t)?,
                None => {
                    let _ = fs::remove_file(p);
                }
            }
        }
        m.files.clear();
        self.save_manifest(&m)
    }
}
