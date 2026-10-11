//! Stable C ABI shared by every native shell (Swift now, C# later). JSON strings in and out.
use crate::server::{Config, Core};
use serde_json::{json, Value};
use std::ffi::{c_char, c_void, CStr, CString};
use std::path::PathBuf;
use std::sync::OnceLock;

static CORE: OnceLock<Core> = OnceLock::new();

pub type SnapshotCallback = extern "C" fn(json: *const c_char, ctx: *mut c_void);

struct Ctx(*mut c_void);
// The shell guarantees ctx outlives the core and tolerates calls from any thread.
unsafe impl Send for Ctx {}
unsafe impl Sync for Ctx {}

fn read(s: *const c_char) -> Value {
    if s.is_null() {
        return Value::Null;
    }
    serde_json::from_str(&unsafe { CStr::from_ptr(s) }.to_string_lossy()).unwrap_or(Value::Null)
}

fn out(v: Value) -> *mut c_char {
    CString::new(v.to_string()).unwrap_or_default().into_raw()
}

/// Start the core. `config`: {"supportDir","home","hookSource"?,"socket"?}.
/// Returns null on success, or an error JSON string (free with `island_free`).
#[unsafe(no_mangle)]
pub extern "C" fn island_start(config: *const c_char, cb: SnapshotCallback, ctx: *mut c_void) -> *mut c_char {
    let c = read(config);
    let path = |k: &str| c[k].as_str().map(PathBuf::from);
    let cfg = Config {
        support_dir: path("supportDir").unwrap_or_default(),
        home: path("home").unwrap_or_default(),
        socket: path("socket"),
        hook_source: path("hookSource"),
    };
    let ctx = Ctx(ctx);
    let emit = Box::new(move |s: String| {
        let ctx = &ctx;
        if let Ok(cs) = CString::new(s) {
            cb(cs.as_ptr(), ctx.0);
        }
    });
    match Core::start(cfg, emit) {
        Ok(core) => {
            let _ = CORE.set(core);
            std::ptr::null_mut()
        }
        Err(e) => out(json!({"error": e})),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn island_send(cmd: *const c_char) {
    if let Some(core) = CORE.get() {
        core.send(&read(cmd));
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn island_call(req: *const c_char) -> *mut c_char {
    match CORE.get() {
        Some(core) => out(core.call(&read(req))),
        None => out(json!({"error": "core not started"})),
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn island_free(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}
