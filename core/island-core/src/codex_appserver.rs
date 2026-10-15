//! Minimal client for Codex's shared app-server daemon: WebSocket over a Unix socket carrying
//! JSON-RPC (without the "jsonrpc" field). Only what Agent Island needs: initialize, subscribe to
//! threads, receive server requests/notifications, send responses.
use serde_json::{json, Value};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;

/// Notifications we never want (token streaming would wake us constantly).
const OPT_OUT: &[&str] = &[
    "item/agentMessage/delta",
    "item/reasoning/summaryTextDelta",
    "item/reasoning/summaryPartAdded",
    "item/reasoning/textDelta",
    "item/commandExecution/outputDelta",
    "item/fileChange/outputDelta",
    "thread/tokenUsage/updated",
    "turn/diff/updated",
    "turn/plan/updated",
    "hook/started",
    "hook/completed",
];

pub fn socket_for(codex_home: &Path) -> PathBuf {
    codex_home.join("app-server-control/app-server-control.sock")
}

pub struct Conn {
    pub id: u64,
    pub codex_home: PathBuf,
    writer: Mutex<UnixStream>,
    next: AtomicU64,
}

impl Conn {
    /// Connect and upgrade to WebSocket. Returns the connection and its reader half.
    pub fn connect(id: u64, codex_home: &Path) -> io::Result<(Conn, BufReader<UnixStream>)> {
        let s = UnixStream::connect(socket_for(codex_home))?;
        s.set_read_timeout(Some(std::time::Duration::from_secs(5)))?;
        (&s).write_all(
            b"GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\
              Sec-WebSocket-Key: QWdlbnRJc2xhbmRLZXkxMg==\r\nSec-WebSocket-Version: 13\r\n\r\n",
        )?;
        let mut r = BufReader::new(s.try_clone()?);
        let mut status = String::new();
        r.read_line(&mut status)?;
        if !status.contains(" 101 ") {
            return Err(io::Error::other(format!("app-server refused upgrade: {}", status.trim())));
        }
        loop {
            let mut line = String::new();
            r.read_line(&mut line)?;
            if line == "\r\n" || line.is_empty() {
                break;
            }
        }
        s.set_read_timeout(None)?;
        Ok((Conn { id, codex_home: codex_home.to_path_buf(), writer: Mutex::new(s), next: AtomicU64::new(1) }, r))
    }

    fn frame(&self, opcode: u8, payload: &[u8]) -> io::Result<()> {
        // Client frames must be masked; a fixed mask is fine on a local socket.
        let mask = [0x41, 0x49, 0x53, 0x4c];
        let mut f = vec![0x80 | opcode];
        match payload.len() {
            n if n < 126 => f.push(0x80 | n as u8),
            n if n < 65536 => {
                f.push(0x80 | 126);
                f.extend_from_slice(&(n as u16).to_be_bytes());
            }
            n => {
                f.push(0x80 | 127);
                f.extend_from_slice(&(n as u64).to_be_bytes());
            }
        }
        f.extend_from_slice(&mask);
        f.extend(payload.iter().enumerate().map(|(i, b)| b ^ mask[i % 4]));
        self.writer.lock().unwrap_or_else(|e| e.into_inner()).write_all(&f)
    }

    pub fn send(&self, msg: &Value) -> io::Result<()> {
        self.frame(0x1, msg.to_string().as_bytes())
    }

    /// Send a request; returns its id (the response arrives on the reader).
    pub fn request(&self, method: &str, params: Value) -> io::Result<u64> {
        let id = self.next.fetch_add(1, Ordering::SeqCst) + 1_000_000; // never collides with server request ids
        self.send(&json!({"id": id, "method": method, "params": params}))?;
        Ok(id)
    }

    pub fn initialize(&self) -> io::Result<u64> {
        self.request(
            "initialize",
            json!({
                "clientInfo": {"name": "agent-island", "title": "Agent Island", "version": env!("CARGO_PKG_VERSION")},
                "capabilities": {"experimentalApi": true, "optOutNotificationMethods": OPT_OUT},
            }),
        )
    }

    pub fn initialized(&self) -> io::Result<()> {
        self.send(&json!({"method": "initialized"}))
    }

    pub fn shutdown(&self) {
        let _ = self.writer.lock().unwrap_or_else(|e| e.into_inner()).shutdown(std::net::Shutdown::Both);
    }

    /// Next text message; answers pings. Ok(None) on close.
    pub fn read(&self, r: &mut BufReader<UnixStream>) -> io::Result<Option<Value>> {
        let mut message = Vec::new();
        loop {
            let mut h = [0u8; 2];
            if r.read_exact(&mut h).is_err() {
                return Ok(None);
            }
            let (fin, opcode) = (h[0] & 0x80 != 0, h[0] & 0x0f);
            let mut len = (h[1] & 0x7f) as u64;
            if len == 126 {
                let mut b = [0u8; 2];
                r.read_exact(&mut b)?;
                len = u16::from_be_bytes(b) as u64;
            } else if len == 127 {
                let mut b = [0u8; 8];
                r.read_exact(&mut b)?;
                len = u64::from_be_bytes(b);
            }
            let mut mask = [0u8; 4];
            if h[1] & 0x80 != 0 {
                r.read_exact(&mut mask)?;
            }
            let mut payload = vec![0u8; len as usize];
            r.read_exact(&mut payload)?;
            if h[1] & 0x80 != 0 {
                payload.iter_mut().enumerate().for_each(|(i, b)| *b ^= mask[i % 4]);
            }
            match opcode {
                0x8 => return Ok(None),
                0x9 => self.frame(0xA, &payload)?,
                0xA => {}
                0x0 | 0x1 | 0x2 => {
                    message.extend_from_slice(&payload);
                    if fin {
                        return Ok(serde_json::from_slice(&message).ok().or(Some(Value::Null)));
                    }
                }
                _ => {}
            }
        }
    }
}
