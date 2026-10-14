//! Find an agent's own interactive process. Codex hooks run inside its shared app-server daemon,
//! so the hook's environment and parents describe the daemon, not the terminal the user typed in.
//! Called once per new session (never polled).
use crate::store::Terminal;
use std::collections::BTreeMap;

pub struct Found {
    pub pid: i32,
    pub terminal: Terminal,
}

#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn devname(dev: libc::dev_t, kind: libc::mode_t) -> *const libc::c_char;
}

#[cfg(target_os = "macos")]
fn bsdinfo(pid: i32) -> Option<libc::proc_bsdinfo> {
    let mut bi: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as i32;
    let n = unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, &mut bi as *mut _ as *mut libc::c_void, size) };
    (n == size).then_some(bi)
}

#[cfg(target_os = "macos")]
fn cwd_of(pid: i32) -> Option<String> {
    let mut vi: libc::proc_vnodepathinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_vnodepathinfo>() as i32;
    let n = unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDVNODEPATHINFO, 0, &mut vi as *mut _ as *mut libc::c_void, size) };
    if n != size {
        return None;
    }
    let p = unsafe { std::ffi::CStr::from_ptr(vi.pvi_cdir.vip_path.as_ptr() as *const libc::c_char) };
    Some(p.to_string_lossy().into_owned())
}

/// Environment of a same-user process (KERN_PROCARGS2: argc, exec path, argv, env).
#[cfg(target_os = "macos")]
fn env_of(pid: i32) -> BTreeMap<String, String> {
    let mut size: libc::size_t = 0;
    let mut mib = [libc::CTL_KERN, libc::KERN_PROCARGS2, pid];
    let mut out = BTreeMap::new();
    if unsafe { libc::sysctl(mib.as_mut_ptr(), 3, std::ptr::null_mut(), &mut size, std::ptr::null_mut(), 0) } != 0 {
        return out;
    }
    let mut buf = vec![0u8; size];
    if unsafe { libc::sysctl(mib.as_mut_ptr(), 3, buf.as_mut_ptr() as *mut libc::c_void, &mut size, std::ptr::null_mut(), 0) } != 0 {
        return out;
    }
    buf.truncate(size);
    if buf.len() < 4 {
        return out;
    }
    let argc = i32::from_ne_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;
    let mut parts = buf[4..].split(|b| *b == 0).filter(|s| !s.is_empty());
    parts.next(); // exec path
    for _ in 0..argc {
        parts.next();
    }
    for kv in parts {
        let kv = String::from_utf8_lossy(kv);
        if let Some((k, v)) = kv.split_once('=') {
            out.insert(k.to_string(), v.to_string());
        }
    }
    out
}

fn realpath(p: &str) -> String {
    std::fs::canonicalize(p).map(|p| p.to_string_lossy().into_owned()).unwrap_or_else(|_| p.to_string())
}

/// The newest process named `comm` with a controlling terminal whose cwd is `cwd`.
#[cfg(target_os = "macos")]
pub fn interactive(comm: &str, cwd: &str) -> Option<Found> {
    let want = realpath(cwd);
    let uid = unsafe { libc::getuid() };
    let n = unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) };
    let mut pids = vec![0i32; n.max(0) as usize + 64];
    let got = unsafe { libc::proc_listallpids(pids.as_mut_ptr() as *mut libc::c_void, (pids.len() * 4) as i32) };
    pids.truncate(got.max(0) as usize);
    let mut best: Option<(u64, i32, String)> = None;
    for pid in pids {
        let Some(bi) = bsdinfo(pid) else { continue };
        let name = unsafe { std::ffi::CStr::from_ptr(bi.pbi_comm.as_ptr()) }.to_string_lossy().into_owned();
        if name != comm || bi.pbi_uid != uid || bi.e_tdev == u32::MAX || bi.e_tdev == 0 {
            continue;
        }
        if cwd_of(pid).map(|c| realpath(&c)) != Some(want.clone()) {
            continue;
        }
        let tty = unsafe { devname(bi.e_tdev as libc::dev_t, libc::S_IFCHR) };
        if tty.is_null() {
            continue;
        }
        let tty = unsafe { std::ffi::CStr::from_ptr(tty) }.to_string_lossy().into_owned();
        if best.as_ref().is_none_or(|b| bi.pbi_start_tvsec > b.0) {
            best = Some((bi.pbi_start_tvsec, pid, tty));
        }
    }
    let (_, pid, tty) = best?;
    let env = env_of(pid);
    let e = |k: &str| env.get(k).filter(|v| !v.is_empty()).cloned();
    // Ancestors, nearest first, for terminal/editor matching.
    let mut pids = vec![pid];
    let mut p = pid;
    for _ in 0..32 {
        match bsdinfo(p) {
            Some(bi) if bi.pbi_ppid > 1 => {
                p = bi.pbi_ppid as i32;
                pids.push(p);
            }
            _ => break,
        }
    }
    Some(Found {
        pid,
        terminal: Terminal {
            program: e("TERM_PROGRAM"),
            bundle_id: e("__CFBundleIdentifier"),
            tty: Some(tty),
            tmux: e("TMUX"),
            tmux_pane: e("TMUX_PANE"),
            iterm_session: e("ITERM_SESSION_ID"),
            term_session: e("TERM_SESSION_ID"),
            host_session: None,
            pids,
        },
    })
}

#[cfg(not(target_os = "macos"))]
pub fn interactive(_comm: &str, _cwd: &str) -> Option<Found> {
    None
}
