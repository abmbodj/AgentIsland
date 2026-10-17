//! The running core: local socket server, process-exit watcher and deadline timer around the Store.
//! Event-driven throughout: threads block on accept / kevent / a condvar; nothing polls.
use crate::codex_appserver::Conn;
use crate::install::{Integrations, UninstallMode};
use crate::protocol::{HookMessage, HookReply};
use crate::store::{Answer, Millis, Store};
use std::collections::HashMap;
use std::io::Read;
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
    /// Hooks waiting for the user's answer, by attention id.
    held: HashMap<u64, UnixStream>,
    /// Codex app-server connections, one per CODEX_HOME.
    codex: HashMap<PathBuf, CodexLink>,
    /// Our outstanding JSON-RPC requests: (connection, request id) → what it was.
    rpc: HashMap<(u64, u64), Rpc>,
    /// Codex threads with an attach / identity lookup already started.
    attaching: HashSet<String>,
    identified: HashSet<String>,
    next_conn: u64,
}

struct CodexLink {
    conn: Arc<Conn>,
    ready: bool,
    queued: Vec<String>,
}

enum Rpc {
    Initialize,
    Resume(String),
}

fn write_reply(mut stream: &UnixStream, stdout: String) {
    let reply = serde_json::to_string(&HookReply { stdout }).unwrap();
    let _ = stream.write_all(format!("{reply}\n").as_bytes());
}

struct Inner {
    shared: Mutex<Shared>,
    wake: Condvar,
    emit: Emit,
    kq: i32,
    sock: PathBuf,
    stop: AtomicBool,
    integrations: Integrations,
    home: PathBuf,
}

pub struct Core {
    inner: Arc<Inner>,
    chats: crate::chat::Chats,
    options: crate::options::Options,
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
        for (id, stdout) in g.store.take_replies() {
            if let Some(stream) = g.held.remove(&id) {
                write_reply(&stream, stdout);
                let _ = stream.shutdown(std::net::Shutdown::Both);
            }
        }
        for (conn_id, msg) in g.store.take_appserver_replies() {
            if let Some(l) = g.codex.values().find(|l| l.conn.id == conn_id) {
                let _ = l.conn.send(&msg);
            }
        }
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

    fn handle_conn(self: &Arc<Self>, stream: UnixStream) {
        let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
        let mut line = String::new();
        if BufReader::new(&stream).read_line(&mut line).is_err() {
            return;
        }
        let Ok(msg) = serde_json::from_str::<HookMessage>(&line) else { return };
        let (stdout, held) = {
            let mut g = self.lock();
            if msg.agent == "query" {
                (Self::snapshot_json(&g), None)
            } else {
                let mut hold = g.store.handle(&msg, now_ms());
                if msg.agent == "codex" {
                    self.codex_followups(&mut g, &msg);
                }
                if let Some(id) = hold {
                    match (g.paused, stream.try_clone()) {
                        (false, Ok(w)) => {
                            g.held.insert(id, w);
                        }
                        _ => {
                            g.store.detach(id); // let the agent's own prompt handle it
                            hold = None;
                        }
                    }
                }
                self.changed(&mut g);
                (String::new(), hold)
            }
        };
        let Some(id) = held else {
            write_reply(&stream, stdout);
            return;
        };
        // Wait for the user. EOF here means the hook died (the agent cancelled it) or we replied.
        let _ = stream.set_read_timeout(None);
        let mut buf = [0u8; 64];
        while matches!((&stream).read(&mut buf), Ok(n) if n > 0) {}
        let mut g = self.lock();
        if g.held.remove(&id).is_some() {
            g.store.hook_gone(id, now_ms());
            self.changed(&mut g);
        }
    }
}

impl Inner {
    /// After a Codex hook event: attach to its app-server, resolve the TUI's identity, read limits.
    fn codex_followups(self: &Arc<Self>, g: &mut Shared, msg: &HookMessage) {
        let Ok(p) = serde_json::from_str::<Value>(&msg.payload) else { return };
        let (Some(thread), Some(cwd)) = (p["session_id"].as_str(), p["cwd"].as_str()) else { return };
        let (thread, cwd) = (thread.to_string(), cwd.to_string());
        let event = p["hook_event_name"].as_str().unwrap_or_default();
        let home = msg.env.get("CODEX_HOME").map(PathBuf::from).unwrap_or_else(|| self.home.join(".codex"));
        let inline = g.store.snapshot().sessions.iter().any(|s| s.agent == "codex" && s.id == thread && s.inline);

        if event == "SessionEnd" {
            if let Some(l) = g.codex.get(&home) {
                let _ = l.conn.request("thread/unsubscribe", json!({"threadId": thread}));
            }
            g.attaching.remove(&thread);
            return;
        }
        if !inline && g.attaching.insert(thread.clone()) {
            let i = self.clone();
            let (t, h) = (thread.clone(), home.clone());
            std::thread::spawn(move || i.attach(h, t));
        }
        if g.identified.insert(thread.clone()) {
            let i = self.clone();
            let (t, c, transcript) = (thread.clone(), cwd.clone(), p["transcript_path"].as_str().map(PathBuf::from));
            std::thread::spawn(move || i.identify(t, c, transcript));
        }
        if !inline && matches!(event, "Stop" | "UserPromptSubmit") {
            if let Some(path) = p["transcript_path"].as_str().map(PathBuf::from) {
                let i = self.clone();
                std::thread::spawn(move || {
                    if let Some(line) = last_rate_limits(&path) {
                        let mut g = i.lock();
                        g.store.codex_rollout_rate_limits(&line, now_ms());
                        i.changed(&mut g);
                    }
                });
            }
        }
    }

    /// Subscribe to the thread on its CODEX_HOME's shared daemon (if one is running).
    fn attach(self: &Arc<Self>, home: PathBuf, thread: String) {
        let existing = self.lock().codex.get(&home).map(|l| l.conn.clone());
        if existing.is_none() {
            match Conn::connect(0, &home) {
                Ok((mut conn, reader)) => {
                    let mut g = self.lock();
                    if !g.codex.contains_key(&home) {
                        g.next_conn += 1;
                        conn.id = g.next_conn;
                        let conn = Arc::new(conn);
                        if let Ok(rid) = conn.initialize() {
                            g.rpc.insert((conn.id, rid), Rpc::Initialize);
                        }
                        g.codex.insert(home.clone(), CodexLink { conn: conn.clone(), ready: false, queued: vec![] });
                        let i = self.clone();
                        let h = home.clone();
                        std::thread::Builder::new().name("island-codex".into()).spawn(move || i.read_codex(h, conn, reader)).ok();
                    }
                }
                Err(_) => {
                    // No daemon (embedded TUI or Desktop's private server): stay a handoff, retry next event.
                    self.lock().attaching.remove(&thread);
                    return;
                }
            }
        }
        let mut g = self.lock();
        let Some(link) = g.codex.get_mut(&home) else { return };
        if link.ready {
            let conn = link.conn.clone();
            if let Ok(rid) = conn.request("thread/resume", json!({"threadId": thread, "excludeTurns": true})) {
                g.rpc.insert((conn.id, rid), Rpc::Resume(thread));
            }
        } else {
            link.queued.push(thread);
        }
    }

    fn read_codex(self: Arc<Self>, home: PathBuf, conn: Arc<Conn>, mut reader: BufReader<UnixStream>) {
        while let Ok(Some(m)) = conn.read(&mut reader) {
            let mut g = self.lock();
            let is_response = m.get("method").is_none();
            if let (true, Some(rid)) = (is_response, m["id"].as_u64()) {
                match g.rpc.remove(&(conn.id, rid)) {
                    Some(Rpc::Initialize) => {
                        let _ = conn.initialized();
                        let queued = g.codex.get_mut(&home).map(|l| {
                            l.ready = true;
                            std::mem::take(&mut l.queued)
                        });
                        for t in queued.unwrap_or_default() {
                            if let Ok(r) = conn.request("thread/resume", json!({"threadId": t, "excludeTurns": true})) {
                                g.rpc.insert((conn.id, r), Rpc::Resume(t));
                            }
                        }
                    }
                    Some(Rpc::Resume(t)) => {
                        if m.get("result").is_some() {
                            g.store.set_attached("codex", &t, Some(conn.id));
                        } else {
                            g.attaching.remove(&t);
                        }
                    }
                    None => {}
                }
            } else {
                g.store.appserver_message(conn.id, &m, now_ms());
            }
            self.changed(&mut g);
        }
        let mut g = self.lock();
        g.codex.remove(&home);
        g.rpc.retain(|(c, _), _| *c != conn.id);
        g.attaching.clear();
        g.store.appserver_closed(conn.id);
        self.changed(&mut g);
    }

    /// Codex hooks run in the daemon; find the TUI the user actually typed in (or the Desktop app).
    fn identify(self: &Arc<Self>, thread: String, cwd: String, transcript: Option<PathBuf>) {
        let found = crate::procscan::interactive("codex", &cwd);
        let desktop = found.is_none()
            && transcript
                .and_then(|p| std::fs::File::open(p).ok())
                .and_then(|f| BufReader::new(f).lines().next()?.ok())
                .is_some_and(|l| l.contains("\"originator\":\"Codex Desktop\""));
        let mut g = self.lock();
        match found {
            Some(f) => g.store.set_identity("codex", &thread, f.terminal, Some(f.pid)),
            None if desktop => {
                let t = crate::store::Terminal { bundle_id: Some("com.openai.codex".into()), ..Default::default() };
                g.store.set_identity("codex", &thread, t, None);
            }
            None => return,
        }
        self.changed(&mut g);
    }
}

/// The last `rate_limits` record in a Codex rollout (reads only the file's tail).
fn last_rate_limits(path: &std::path::Path) -> Option<Value> {
    use std::io::{Seek, SeekFrom};
    let mut f = std::fs::File::open(path).ok()?;
    let len = f.metadata().ok()?.len();
    f.seek(SeekFrom::Start(len.saturating_sub(256 * 1024))).ok()?;
    let mut tail = String::new();
    f.read_to_string(&mut tail).ok()?;
    tail.lines().rev().filter(|l| l.contains("\"rate_limits\"")).find_map(|l| serde_json::from_str(l).ok())
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
        let mut store = Store::default();
        store.desktop_sessions = Some(cfg.home.join("Library/Application Support/Claude/claude-code-sessions"));
        let inner = Arc::new(Inner {
            shared: Mutex::new(Shared {
                store,
                paused: false,
                last_emit: String::new(),
                watched: HashSet::new(),
                held: HashMap::new(),
                codex: HashMap::new(),
                rpc: HashMap::new(),
                attaching: HashSet::new(),
                identified: HashSet::new(),
                next_conn: 0,
            }),
            wake: Condvar::new(),
            emit,
            kq,
            sock,
            stop: AtomicBool::new(false),
            integrations,
            home: cfg.home.clone(),
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

        Ok(Core { inner, chats: Default::default(), options: Default::default() })
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
            Some("release") => g.store.release(cmd["id"].as_u64().unwrap_or_default()),
            Some("answer") => {
                let answer = match (cmd["decision"].as_str(), cmd["answers"].as_object()) {
                    (Some("allow"), _) => Answer::Allow,
                    (Some("deny"), _) => Answer::Deny,
                    (Some("allowSession"), _) => Answer::AllowSession,
                    (_, Some(m)) => Answer::Answers(m.iter().map(|(k, v)| (k.clone(), v.as_str().unwrap_or_default().to_string())).collect()),
                    _ => return,
                };
                g.store.answer(cmd["id"].as_u64().unwrap_or_default(), answer, now_ms());
            }
            _ => return,
        }
        self.inner.changed(&mut g);
    }

    /// Synchronous requests from the UI (installer). Returns `{"ok":..}` or `{"error":..}`.
    fn tools(&self) -> crate::pr::Tools {
        crate::pr::Tools::standard(&self.inner.home)
    }

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
            // Run off the main thread: these call git, gh and a headless agent.
            "prReady" => Ok(json!(crate::pr::ready(&self.tools(), req["cwd"].as_str().unwrap_or_default(), req["offered"] == true))),
            "prCreate" => {
                let s = |k: &str| req[k].as_str().unwrap_or_default();
                crate::pr::create(&self.tools(), s("cwd"), s("agent"), s("base"), s("recap")).map(|c| json!(c))
            }
            "prCancel" => {
                crate::pr::cancel(req["cwd"].as_str().unwrap_or_default());
                Ok(Value::Null)
            }
            "chatOptions" => Ok(self.options.get(&self.tools(), req["refresh"] == true)),
            "chatStart" => {
                let s = |k: &str| req[k].as_str().unwrap_or_default();
                turn_settings(&req).and_then(|t| self.chats.start(&self.tools(), s("agent"), s("cwd"), s("text"), turn_images(&req), t)).map(|id| json!({"id": id}))
            }
            "chatSend" => turn_settings(&req)
                .and_then(|t| self.chats.send(&self.tools(), req["id"].as_u64().unwrap_or_default(), req["text"].as_str().unwrap_or_default(), turn_images(&req), t))
                .map(|_| Value::Null),
            "chatPlan" => self.chats.plan_action(&self.tools(), req["id"].as_u64().unwrap_or_default(), req["version"].as_u64().unwrap_or_default(), req["action"].as_str().unwrap_or_default(), req["feedback"].as_str()).map(|_| Value::Null),
            "chatLogin" => self.chats.login(&self.tools(), req["id"].as_u64().unwrap_or_default()).map(|_| Value::Null),
            "chatAnswer" => self.chats.answer(req["id"].as_u64().unwrap_or_default(), req.get("answers").filter(|a| a.is_object()).cloned()).map(|_| Value::Null),
            "chatPermission" => self.chats.permission(req["id"].as_u64().unwrap_or_default(), req["requestId"].as_str().unwrap_or_default(), req["allow"] == true).map(|_| Value::Null),
            "chatHandoff" => self.chats.request_handoff(req["id"].as_u64().unwrap_or_default(), req["target"].as_str().unwrap_or_default()).map(|_| Value::Null),
            "chatHandoffCancel" => self.chats.cancel_handoff(req["id"].as_u64().unwrap_or_default()).map(|_| Value::Null),
            "chatHandoffClaim" => Ok(self.chats.claim_handoffs(&self.tools())),
            "chatHandoffFinish" => self.chats.finish_handoff(req["id"].as_u64().unwrap_or_default(), req["token"].as_u64().unwrap_or_default(), req["error"].as_str()).map(|_| Value::Null),
            "chatStop" => {
                self.chats.stop(req["id"].as_u64().unwrap_or_default());
                Ok(Value::Null)
            }
            "chatDelete" => {
                self.chats.delete(req["id"].as_u64().unwrap_or_default());
                Ok(Value::Null)
            }
            "transcript" => self.chats.transcript(req["id"].as_u64().unwrap_or_default(), req["since"].as_u64().unwrap_or_default()),
            "chatList" => Ok(self.chats.list()),
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
        self.chats.kill_all();
        self.inner.stop.store(true, Ordering::SeqCst);
        let _ = UnixStream::connect(&self.inner.sock); // wake accept()
        let _ = std::fs::remove_file(&self.inner.sock);
        self.inner.wake.notify_all();
        kq_user(self.inner.kq, 0, libc::NOTE_TRIGGER); // wake kevent()
    }
}

/// A turn's optional `settings` object; absent means Default for everything.
fn turn_images(req: &Value) -> Vec<crate::chat::Image> {
    serde_json::from_value(req["images"].clone()).unwrap_or_default()
}

fn turn_settings(req: &Value) -> Result<crate::chat::Settings, String> {
    if req["settings"].is_null() {
        return Ok(Default::default());
    }
    serde_json::from_value(req["settings"].clone()).map_err(|e| format!("Unreadable settings: {e}"))
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
