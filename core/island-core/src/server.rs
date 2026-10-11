//! The running core: local socket server, process-exit watcher and deadline timer around the Store.
//! Event-driven throughout: threads block on accept / kevent / a condvar; nothing polls.
use crate::install::{Integrations, UninstallMode};
use crate::protocol::{HookMessage, HookReply};
use crate::store::{Millis, Store};
use serde_json::{json, Value};
use std::collections::HashSet;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::Duration;

pub struct Config {
    pub support_dir: PathBuf,
    pub home: PathBuf,
    /// Defaults to `<support_dir>/island.sock`.
    pub socket: Option<PathBuf>,
    /// The hook binary inside the app bundle; copied to `<support_dir>/bin/island-hook` on start.
    pub hook_source: Option<PathBuf>,
}

pub type Emit = Box<dyn Fn(String) + Send + Sync>;

struct Shared {
    store: Store,
    paused: bool,
    last_emit: String,
    watched: HashSet<i32>,
}

struct Inner {
    shared: Mutex<Shared>,
    wake: Condvar,
    emit: Emit,
    kq: i32,
    sock: PathBuf,
    stop: AtomicBool,
    integrations: Integrations,
}

pub struct Core {
    inner: Arc<Inner>,
}

pub fn now_ms() -> Millis {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_millis() as Millis)
}

impl Inner {
    fn lock(&self) -> MutexGuard<'_, Shared> {
        self.shared.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn snapshot_json(g: &Shared) -> String {
        let mut v = serde_json::to_value(g.store.snapshot()).unwrap_or(Value::Null);
        v["paused"] = json!(g.paused);
        v.to_string()
    }

    /// Call after every mutation: watch new PIDs, emit if anything visible changed, re-arm the timer.
    fn changed(&self, g: &mut Shared) {
        let pids: Vec<i32> = g.store.snapshot().sessions.iter().filter_map(|s| s.pid).collect();
        for pid in pids {
            if g.watched.insert(pid) && !watch_exit(self.kq, pid) {
                g.store.process_exited(pid, now_ms()); // already gone
            }
        }
        let json = Self::snapshot_json(g);
        if json != g.last_emit {
            g.last_emit = json.clone();
            (self.emit)(json);
        }
        self.wake.notify_all();
    }

    fn handle_conn(&self, stream: UnixStream) {
        let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
        let mut line = String::new();
        if BufReader::new(&stream).read_line(&mut line).is_err() {
            return;
        }
        let Ok(msg) = serde_json::from_str::<HookMessage>(&line) else { return };
        let stdout = {
            let mut g = self.lock();
            if msg.agent == "query" {
                Self::snapshot_json(&g)
            } else {
                g.store.handle(&msg, now_ms());
                self.changed(&mut g);
                String::new()
            }
        };
        let reply = serde_json::to_string(&HookReply { stdout }).unwrap();
        let _ = (&stream).write_all(format!("{reply}\n").as_bytes());
    }
}

fn kq_user(kq: i32, flags: u16, fflags: u32) {
    let ev = libc::kevent { ident: 0, filter: libc::EVFILT_USER, flags, fflags, data: 0, udata: std::ptr::null_mut() };
    unsafe { libc::kevent(kq, &ev, 1, std::ptr::null_mut(), 0, std::ptr::null()) };
}

/// Register for the process's exit. Returns false only if it has already exited.
#[cfg(target_os = "macos")]
fn watch_exit(kq: i32, pid: i32) -> bool {
    let ev = libc::kevent {
        ident: pid as usize,
        filter: libc::EVFILT_PROC,
        flags: libc::EV_ADD | libc::EV_ONESHOT,
        fflags: libc::NOTE_EXIT,
        data: 0,
        udata: std::ptr::null_mut(),
    };
    let ok = unsafe { libc::kevent(kq, &ev, 1, std::ptr::null_mut(), 0, std::ptr::null()) } == 0;
    ok || std::io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
}

impl Core {
    pub fn start(cfg: Config, emit: Emit) -> Result<Core, String> {
        std::fs::create_dir_all(&cfg.support_dir).map_err(|e| e.to_string())?;
        let integrations = Integrations::new(cfg.support_dir.clone(), cfg.home.clone());
        if let Some(src) = &cfg.hook_source {
            install_hook_binary(src, &integrations.hook_path())?;
        }
        let sock = cfg.socket.clone().unwrap_or_else(|| cfg.support_dir.join("island.sock"));
        if UnixStream::connect(&sock).is_ok() {
            return Err("Agent Island is already running".into());
        }
        let _ = std::fs::remove_file(&sock);
        let listener = UnixListener::bind(&sock).map_err(|e| format!("bind {}: {e}", sock.display()))?;
        let _ = std::fs::set_permissions(&sock, std::fs::Permissions::from_mode(0o600));

        let kq = unsafe { libc::kqueue() };
        // User event used only to wake the PID thread for shutdown.
        kq_user(kq, libc::EV_ADD | libc::EV_CLEAR, 0);
        let inner = Arc::new(Inner {
            shared: Mutex::new(Shared { store: Store::default(), paused: false, last_emit: String::new(), watched: HashSet::new() }),
            wake: Condvar::new(),
            emit,
            kq,
            sock,
            stop: AtomicBool::new(false),
            integrations,
        });

        let i = inner.clone();
        std::thread::Builder::new().name("island-accept".into()).spawn(move || {
            for conn in listener.incoming() {
                if i.stop.load(Ordering::SeqCst) {
                    break;
                }
                if let Ok(c) = conn {
                    let i = i.clone();
                    std::thread::spawn(move || i.handle_conn(c));
                }
            }
        }).map_err(|e| e.to_string())?;

        let i = inner.clone();
        std::thread::Builder::new().name("island-pids".into()).spawn(move || loop {
            let mut ev: libc::kevent = unsafe { std::mem::zeroed() };
            let n = unsafe { libc::kevent(i.kq, std::ptr::null(), 0, &mut ev, 1, std::ptr::null()) };
            if i.stop.load(Ordering::SeqCst) {
                unsafe { libc::close(i.kq) }; // only this thread closes it, so the fd can't be reused under us
                break;
            }
            if n == 1 && ev.filter == libc::EVFILT_PROC {
                let pid = ev.ident as i32;
                let mut g = i.lock();
                g.watched.remove(&pid);
                g.store.process_exited(pid, now_ms());
                i.changed(&mut g);
            }
        }).map_err(|e| e.to_string())?;

        let i = inner.clone();
        std::thread::Builder::new().name("island-timer".into()).spawn(move || {
            let mut g = i.lock();
            while !i.stop.load(Ordering::SeqCst) {
                let now = now_ms();
                g = match g.store.next_deadline() {
                    Some(d) if d <= now => {
                        g.store.tick(now);
                        i.changed(&mut g);
                        g
                    }
                    Some(d) => i.wake.wait_timeout(g, Duration::from_millis(d - now)).unwrap_or_else(|e| e.into_inner()).0,
                    None => i.wake.wait(g).unwrap_or_else(|e| e.into_inner()),
                };
            }
        }).map_err(|e| e.to_string())?;

        Ok(Core { inner })
    }

    /// Fire-and-forget commands from the UI: `{"type":"viewed","agent":..,"id":..}`, `{"type":"pause","paused":true}`.
    pub fn send(&self, cmd: &Value) {
        let mut g = self.inner.lock();
        match cmd["type"].as_str() {
            Some("viewed") => {
                let (a, id) = (cmd["agent"].as_str().unwrap_or_default(), cmd["id"].as_str().unwrap_or_default());
                g.store.viewed(a, id, now_ms());
            }
            Some("pause") => g.paused = cmd["paused"].as_bool().unwrap_or(false),
            _ => return,
        }
        self.inner.changed(&mut g);
    }

    /// Synchronous requests from the UI (installer). Returns `{"ok":..}` or `{"error":..}`.
    pub fn call(&self, req: &Value) -> Value {
        let it = &self.inner.integrations;
        let r: Result<Value, String> = match req["op"].as_str().unwrap_or_default() {
            "planInstall" => Ok(json!(it.plan_install())),
            "applyInstall" => {
                let ids: Vec<&str> = req["ids"].as_array().into_iter().flatten().filter_map(Value::as_str).collect();
                it.apply_install(&ids).map(|_| Value::Null)
            }
            "planUninstall" => Ok(json!(it.plan_uninstall())),
            "applyUninstall" => serde_json::from_value::<UninstallMode>(req["mode"].clone())
                .map_err(|e| e.to_string())
                .and_then(|m| it.apply_uninstall(m).map(|_| Value::Null)),
            "snapshot" => Ok(serde_json::from_str(&Inner::snapshot_json(&self.inner.lock())).unwrap_or(Value::Null)),
            op => Err(format!("unknown op {op}")),
        };
        match r {
            Ok(v) => json!({"ok": v}),
            Err(e) => json!({"error": e}),
        }
    }
}

impl Drop for Core {
    fn drop(&mut self) {
        self.inner.stop.store(true, Ordering::SeqCst);
        let _ = UnixStream::connect(&self.inner.sock); // wake accept()
        let _ = std::fs::remove_file(&self.inner.sock);
        self.inner.wake.notify_all();
        kq_user(self.inner.kq, 0, libc::NOTE_TRIGGER); // wake kevent()
    }
}

/// Keep the stable hook path pointing at the bundle's current binary (survives app moves/updates).
fn install_hook_binary(src: &std::path::Path, dst: &std::path::Path) -> Result<(), String> {
    let new = std::fs::read(src).map_err(|e| format!("hook binary: {e}"))?;
    if std::fs::read(dst).ok().as_deref() == Some(new.as_slice()) {
        return Ok(());
    }
    std::fs::create_dir_all(dst.parent().unwrap()).map_err(|e| e.to_string())?;
    let tmp = dst.with_extension("new");
    std::fs::write(&tmp, &new).map_err(|e| e.to_string())?;
    std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o755)).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, dst).map_err(|e| e.to_string())
}
