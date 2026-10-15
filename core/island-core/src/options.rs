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
