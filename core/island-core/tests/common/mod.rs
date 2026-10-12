#![allow(dead_code)]
use island_core::protocol::HookMessage;
use serde_json::Value;

pub fn fixture(name: &str) -> Value {
    fixture_in("claude", name)
}

pub fn fixture_in(agent: &str, name: &str) -> Value {
    let p = format!("{}/../../fixtures/{agent}/{name}.json", env!("CARGO_MANIFEST_DIR"));
    serde_json::from_str(&std::fs::read_to_string(&p).unwrap_or_else(|_| panic!("missing {p}"))).unwrap()
}

/// A Claude hook message built from a captured fixture, with optional payload overrides.
pub fn claude(name: &str, patch: Value) -> HookMessage {
    let f = fixture(name);
    let mut payload = f["payload"].clone();
    if let (Some(p), Some(o)) = (payload.as_object_mut(), patch.as_object()) {
        for (k, v) in o {
            p.insert(k.clone(), v.clone());
        }
    }
    let env = f["env"].as_object().unwrap().iter().map(|(k, v)| (k.clone(), v.as_str().unwrap().to_string())).collect();
    HookMessage { v: 1, agent: "claude".into(), payload: payload.to_string(), env, tty: Some("ttys001".into()), pids: vec![] }
}

/// A Codex hook message from a captured fixture.
pub fn codex(name: &str, patch: Value) -> HookMessage {
    let f = fixture_in("codex", name);
    let mut payload = f["payload"].clone();
    if let (Some(p), Some(o)) = (payload.as_object_mut(), patch.as_object()) {
        for (k, v) in o {
            p.insert(k.clone(), v.clone());
        }
    }
    let env = f["env"].as_object().unwrap().iter().map(|(k, v)| (k.clone(), v.as_str().unwrap().to_string())).collect();
    HookMessage { v: 1, agent: "codex".into(), payload: payload.to_string(), env, tty: None, pids: vec![] }
}
