//! Integration files on disk: consent plans with diffs, backups, hashes, drift-aware uninstall.
use crate::installer::{self, ClaudeParts};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanItem {
    pub id: String,
    pub title: String,
    pub path: String,
    pub diff: String,
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

    fn claude_after(&self, before: Option<&str>, parts: ClaudeParts) -> Result<String, String> {
        installer::install_claude(before, &self.hook_path().to_string_lossy(), parts)
    }

    /// One item per consentable part, each with the diff it alone would cause. Empty = nothing to do.
    pub fn plan_install(&self) -> Vec<PlanItem> {
        let path = self.claude_settings();
        let before = fs::read_to_string(&path).ok();
        let p = path.to_string_lossy().to_string();
        [
            ("claude-hooks", "Claude Code hooks", ClaudeParts { hooks: true, statusline: false }),
            ("claude-statusline", "Claude usage (status line pass-through)", ClaudeParts { hooks: false, statusline: true }),
        ]
        .into_iter()
        .filter_map(|(id, title, parts)| {
            let after = self.claude_after(before.as_deref(), parts).ok()?;
            (before.as_deref() != Some(after.as_str())).then(|| PlanItem {
                id: id.into(),
                title: title.into(),
                path: p.clone(),
                diff: diff(&p, before.as_deref(), Some(&after)),
            })
        })
        .collect()
    }

    pub fn apply_install(&self, ids: &[&str]) -> Result<(), String> {
        let parts = ClaudeParts { hooks: ids.contains(&"claude-hooks"), statusline: ids.contains(&"claude-statusline") };
        if !parts.hooks && !parts.statusline {
            return Ok(());
        }
        let path = self.claude_settings();
        let key = path.to_string_lossy().to_string();
        let before = fs::read_to_string(&path).ok();
        let after = self.claude_after(before.as_deref(), parts)?;
        let mut m = self.manifest();
        if !m.files.contains_key(&key) {
            // First install: keep the pristine original forever (until uninstall).
            let backups = self.support.join("backups");
            fs::create_dir_all(&backups).map_err(|e| e.to_string())?;
            let backup = format!("backups/claude-settings-{}.json", now_secs());
            if let Some(b) = &before {
                fs::write(self.support.join(&backup), b).map_err(|e| e.to_string())?;
            }
            m.files.insert(key.clone(), FileRecord { existed: before.is_some(), backup, written_sha: String::new(), installed_at: now_secs() });
        }
        fs::create_dir_all(path.parent().unwrap()).map_err(|e| e.to_string())?;
        write_atomic(&path, &after)?;
        m.files.get_mut(&key).unwrap().written_sha = sha(after.as_bytes());
        self.save_manifest(&m)
    }

    fn original(&self, r: &FileRecord) -> Result<Option<String>, String> {
        if !r.existed {
            return Ok(None);
        }
        fs::read_to_string(self.support.join(&r.backup)).map(Some).map_err(|e| format!("backup missing: {e}"))
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
                    (Some(c), true) => installer::uninstall_claude(c, original.as_deref()).ok()?,
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
                (UninstallMode::Surgical, false, Some(c)) => installer::uninstall_claude(c, original.as_deref())?,
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
