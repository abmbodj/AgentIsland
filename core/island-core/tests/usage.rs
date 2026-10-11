use island_core::protocol::HookMessage;
use island_core::store::Store;
use serde_json::json;

fn statusline(payload: serde_json::Value) -> HookMessage {
    HookMessage { v: 1, agent: "statusline".into(), payload: payload.to_string(), env: Default::default(), tty: None, pids: vec![] }
}

const NOW_S: u64 = 1_791_750_000;

#[test]
fn claude_rate_limits_come_from_the_statusline_feed_and_never_create_sessions() {
    let mut s = Store::default();
    s.handle(
        &statusline(json!({"session_id":"abc","cwd":"/x","rate_limits":{
            "five_hour":{"used_percentage":42.4,"resets_at":NOW_S + 3600},
            "seven_day":{"used_percentage":18,"resets_at":NOW_S + 86400}}})),
        NOW_S * 1000,
    );
    let snap = s.snapshot();
    assert!(snap.sessions.is_empty());
    let c = snap.usage.claude.expect("claude usage");
    assert_eq!(c.observed_at, NOW_S * 1000);
    assert_eq!(c.windows.len(), 2);
    assert_eq!(c.windows[0].label, "5h");
    assert_eq!(c.windows[0].used_percent, 42.4);
    assert_eq!(c.windows[0].resets_at, (NOW_S + 3600) * 1000);
    assert_eq!(c.windows[1].label, "7d");
}

#[test]
fn a_window_disappears_once_its_reset_time_passes() {
    let mut s = Store::default();
    s.handle(
        &statusline(json!({"rate_limits":{
            "five_hour":{"used_percentage":90,"resets_at":NOW_S + 60},
            "seven_day":{"used_percentage":18,"resets_at":NOW_S + 86400}}})),
        NOW_S * 1000,
    );
    assert_eq!(s.next_deadline(), Some((NOW_S + 60) * 1000));
    s.tick((NOW_S + 60) * 1000);
    let c = s.snapshot().usage.claude.unwrap();
    assert_eq!(c.windows.iter().map(|w| w.label.as_str()).collect::<Vec<_>>(), ["7d"]);
}

#[test]
fn statusline_without_rate_limits_keeps_the_last_reliable_values() {
    let mut s = Store::default();
    s.handle(&statusline(json!({"rate_limits":{"five_hour":{"used_percentage":5,"resets_at":NOW_S + 60}}})), NOW_S * 1000);
    s.handle(&statusline(json!({"session_id":"x"})), NOW_S * 1000 + 5);
    assert_eq!(s.snapshot().usage.claude.unwrap().windows.len(), 1);
}
