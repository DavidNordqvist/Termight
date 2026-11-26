// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 David Nordqvist
//
// This file is part of Termight. Termight is free software: you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License, version 3, as published by the Free Software Foundation. It comes
// with no warranty. See the LICENSE file for the full text.

//! termight-core — run one shell command headlessly; also checks and completes
//! commands for the Termight launcher.
//!
//! Usage:
//!   termight [--cwd DIR] [--] <command...>   run; status line first, output trimmed
//!   termight --stream [--cwd DIR] -- <cmd>   run; output streamed live to stdout,
//!                                            then `status`, `cwd`, `code` lines
//!                                            (key<TAB>value) on stderr
//!   termight --check [--cwd DIR] -- <line>   exit 0 runnable, 2 runnable but needs a
//!                                            real terminal, 3 snippet needs values
//!                                            (one line per unfilled placeholder:
//!                                            name, `=default` or empty, kind
//!                                            text|number|choice|secret, then any
//!                                            choices, tab-separated), 1 not runnable;
//!                                            prints how it resolved or why not
//!   termight --complete [--cwd DIR] -- <line>  first line: word being completed,
//!                                            then one candidate per line
//!   termight --expand -- <line>              print the line as a script, any snippet
//!                                            expanded and its values exported
//!   termight --which -- <name>               exit 0 and print where a command of that
//!                                            name comes from, ignoring snippets
//!   echo "ls ~" | termight                   command read from stdin
//!
//!   --strict-values   with a snippet: refuse words beyond its placeholders instead
//!                     of appending them (for callers that pass text nobody typed)
//!   --color           (with --stream) run on a pseudo-terminal, so programs color
//!                     their output as in Terminal; colors (SGR codes) and carriage
//!                     returns are passed through, everything else is stripped
//!
//! Env:
//!   TERMIGHT_TIMEOUT   seconds before the command is killed (default 30)
//!   TERMIGHT_LINES     max output lines in the non-stream result (default 40)
//!   TERMIGHT_RC=1      source ~/.zshrc (or ~/.bashrc) first: aliases and functions
//!   TERMIGHT_LOG_FILE  also write this run's full output to this path
//!   TERMIGHT_NO_LOG=1  write no logs or history (menu bar commands)
//!   TERMIGHT_COLUMNS   terminal width for --color (default 100)
//!   TERMIGHT_FILES, TERMIGHT_FILE_<n>, TERMIGHT_SECRET_<name>: see snippet.rs.
//!                      A secret's value is replaced by •••• in the output.
//!
//! Snippets (Library/Application Support/Termight/snippets.tsv) expand when the
//! first word is a snippet name; see snippet.rs. A snippet with a required
//! placeholder still unfilled is refused, not run. A `cd` in the command is
//! reported back as the final `cwd` so the launcher can keep it for the next
//! command.
//!
//! A line that starts with a space is not written to the history.
//!
//! SIGTERM kills the running command's whole process group (launcher Esc).
//! Run mode always exits 0 so callers show the result; the status line says how
//! the command ended.

mod check;
mod shell;
mod snippet;

use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

unsafe extern "C" {
    fn kill(pid: i32, sig: i32) -> i32;
    fn signal(sig: i32, handler: extern "C" fn(i32)) -> usize;
}
const SIGTERM: i32 = 15;
const SIGKILL: i32 = 9;
/// Output kept in memory for the log / non-stream result.
const CAPTURE_CAP: usize = 5 * 1024 * 1024;
/// After the shell exits, how long something else may keep its output open
/// (a background child) before the process group is killed.
const DRAIN_GRACE: Duration = Duration::from_millis(300);
/// After that kill, how long to keep reading before giving up on a process
/// that left the group.
const DRAIN_GIVE_UP: Duration = Duration::from_millis(500);
/// history.log is cut back to its last HISTORY_KEEP lines once it passes this size.
const HISTORY_TRIM_AT: u64 = 512 * 1024;
const HISTORY_KEEP: usize = 5000;

static CANCELLED: AtomicBool = AtomicBool::new(false);
extern "C" fn on_sigterm(_: i32) {
    // Only an atomic store: the one thing that is safe in a signal handler.
    CANCELLED.store(true, Ordering::SeqCst);
}

fn kill_group(pgid: i32) {
    unsafe { kill(-pgid, SIGTERM) };
    thread::sleep(Duration::from_millis(300));
    unsafe { kill(-pgid, SIGKILL) };
}

fn env_num(key: &str, default: u64) -> u64 {
    std::env::var(key)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

/// The home folder. Without HOME there is no safe place for snippets, caches
/// or logs (/tmp is writable by everyone), so point at a folder that holds
/// nothing and cannot be written: no snippets load and nothing is saved.
fn home() -> PathBuf {
    match std::env::var("HOME") {
        Ok(h) if !h.is_empty() => PathBuf::from(h),
        _ => PathBuf::from("/var/empty"),
    }
}

enum Mode {
    Run,
    Check,
    Complete,
    Expand,
    Which,
}

struct Opts {
    mode: Mode,
    stream: bool,
    strict: bool,
    color: bool,
    cwd: Option<PathBuf>,
    text: String,
}

fn parse_args() -> Opts {
    let mut args = std::env::args().skip(1).peekable();
    let mut o = Opts {
        mode: Mode::Run,
        stream: false,
        strict: false,
        color: false,
        cwd: None,
        text: String::new(),
    };
    while let Some(a) = args.peek() {
        match a.as_str() {
            "--check" => o.mode = Mode::Check,
            "--complete" => o.mode = Mode::Complete,
            "--expand" => o.mode = Mode::Expand,
            "--which" => o.mode = Mode::Which,
            "--stream" => o.stream = true,
            "--strict-values" => o.strict = true,
            "--color" => o.color = true,
            "--cwd" => {
                args.next();
                o.cwd = args.peek().map(PathBuf::from);
            }
            "--" => {
                args.next();
                break;
            }
            _ => break,
        }
        args.next();
    }
    let rest: Vec<String> = args.collect();
    o.text = if rest.is_empty() && matches!(o.mode, Mode::Run) {
        let mut s = String::new();
        let _ = std::io::stdin().read_to_string(&mut s);
        s
    } else {
        rest.join(" ")
    };
    o
}

fn main() {
    let o = parse_args();
    let home = home();
    let cwd = o
        .cwd
        .clone()
        .filter(|p| p.is_dir())
        .unwrap_or_else(|| home.clone());

    match o.mode {
        Mode::Check => match check::check(o.text.trim(), &cwd, &home, o.strict) {
            Ok(found) => {
                println!("{}", found.info);
                let code = if found.needs {
                    3
                } else if found.interactive {
                    2
                } else {
                    0
                };
                std::process::exit(code);
            }
            Err(reason) => {
                println!("{reason}");
                std::process::exit(1);
            }
        },
        Mode::Complete => {
            let (token, cands) = check::complete(&o.text, &cwd, &home);
            println!("{token}");
            for c in cands {
                println!("{c}");
            }
        }
        Mode::Expand => {
            let e = snippet::expand_snippet(o.text.trim(), &home, o.strict);
            if let Some(error) = e.error {
                eprintln!("{error}");
                std::process::exit(1);
            }
            match e.script() {
                Ok(script) => println!("{script}"),
                Err(error) => {
                    eprintln!("{error}");
                    std::process::exit(1);
                }
            }
        }
        Mode::Which => match check::which(o.text.trim(), &cwd, &home) {
            Some(found) => println!("{found}"),
            None => std::process::exit(1),
        },
        Mode::Run => run(
            &o.text,
            o.stream,
            o.strict,
            o.stream && o.color,
            &cwd,
            &home,
        ),
    }
}

fn run(raw: &str, stream: bool, strict: bool, color: bool, cwd: &Path, home: &Path) {
    // A leading space keeps the line out of the history, as in the shell.
    // TERMIGHT_NO_HISTORY: a watched command's later runs, already in the history once.
    let keep_history =
        !raw.starts_with(' ') && std::env::var("TERMIGHT_NO_HISTORY").as_deref() != Ok("1");
    let typed = raw.trim();
    if typed.is_empty() {
        println!("✗ no command given");
        return;
    }
    unsafe { signal(SIGTERM, on_sigterm) };

    let expansion = snippet::expand_snippet(typed, home, strict);
    let timeout = Duration::from_secs(env_num("TERMIGHT_TIMEOUT", 30));
    let max_lines = env_num("TERMIGHT_LINES", 40) as usize;
    let required = expansion.required_labels();
    if !required.is_empty() {
        let names = required;
        let status = format!("✗ snippet needs a value for {}", names.join(" "));
        finish(stream, &status, "", cwd, None, max_lines);
        return;
    }
    if let Some(error) = &expansion.error {
        finish(stream, &format!("✗ {error}"), "", cwd, None, max_lines);
        return;
    }
    let sh = shell::Shell::detect();
    let pwd_file = std::env::temp_dir().join(format!("termight-pwd-{}", std::process::id()));
    // A file left by an earlier process with this pid must not be read as this run's folder.
    let _ = fs::remove_file(&pwd_file);

    // With --color the command writes to a pseudo-terminal, so programs that
    // color only for a terminal (ls, git, grep) do; a pipe inside the command
    // still gets plain text, as in Terminal.
    let pty = if color {
        match pty::open(env_num("TERMIGHT_COLUMNS", 100).clamp(20, 500) as u16) {
            Ok(p) => Some(p),
            Err(e) => {
                let status = format!("✗ could not open a terminal for colors: {e}");
                finish(stream, &status, "", cwd, None, max_lines);
                return;
            }
        }
    } else {
        None
    };
    let (reader, out_stdio): (Box<dyn Read + Send>, Stdio) = match pty {
        Some((master, slave)) => (Box::new(master), Stdio::from(slave)),
        None => (Box::new(std::io::empty()), Stdio::piped()),
    };

    // Login shell so Homebrew/PATH from ~/.zprofile resolves. The command is
    // passed as $1 and eval'd, so no quoting is needed. Snippet values go in
    // as environment variables the command refers to (snippet.rs).
    let spawned = {
        use std::os::unix::process::CommandExt;
        let mut cmd = Command::new(&sh.path);
        cmd.args([
            "-lc",
            &sh.run_script(shell::rc_enabled()),
            "termight",
            &expansion.command,
        ])
        .envs(expansion.env.iter().cloned())
        .env("TERMIGHT_PWD_FILE", &pwd_file)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(out_stdio)
        .stderr(Stdio::null())
        .process_group(0); // own group so timeout/cancel kills children too
        if color {
            // A terminal, but nobody to page or answer: pagers print straight through.
            cmd.env("TERM", "xterm-256color")
                .env("CLICOLOR", "1")
                .env("PAGER", "cat")
                .env("GIT_PAGER", "cat")
                .env("MANPAGER", "cat")
                .env("GH_PAGER", "cat")
                .env("AWS_PAGER", "")
                .env("SYSTEMD_PAGER", "cat");
        }
        cmd.spawn()
        // `cmd` is dropped here, closing this process's copy of the terminal,
        // so reading it ends when the command's side closes.
    };
    let mut child = match spawned {
        Ok(c) => c,
        Err(e) => {
            let status = format!("✗ could not start {}: {e}", sh.path);
            finish(stream, &status, "", cwd, None, max_lines);
            return;
        }
    };

    let pgid = child.id() as i32;
    let mut stdout: Box<dyn Read + Send> = match child.stdout.take() {
        Some(pipe) => Box::new(pipe),
        None => reader,
    };
    let secret_values: Vec<String> = std::env::vars()
        .filter(|(k, v)| k.starts_with(snippet::SECRET_PREFIX) && v.chars().count() >= 4)
        .map(|(_, v)| v)
        .collect();
    let captured = Arc::new(Mutex::new(Vec::new()));
    let truncated = Arc::new(AtomicBool::new(false));
    let drained = Arc::new(AtomicBool::new(false));
    {
        let (captured, truncated, drained, secrets) = (
            Arc::clone(&captured),
            Arc::clone(&truncated),
            Arc::clone(&drained),
            secret_values.clone(),
        );
        // Not joined: a process that keeps the pipe open must not hold up the result.
        thread::spawn(move || {
            // Shown: colors kept with --color. Logged: plain text.
            let mut shown = Filter {
                keep_color: color,
                ..Filter::default()
            };
            let mut plain = Filter::default();
            let mut redactor = Redactor::new(&secrets);
            let mut buf = [0u8; 8192];
            let mut out = std::io::stdout();
            loop {
                // A terminal reports EIO once the command's side is closed.
                let n = match stdout.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => n,
                };
                let visible = shown.push(&buf[..n]);
                let clean = if color {
                    plain.push(&visible)
                } else {
                    visible.clone()
                };
                if stream {
                    let _ = out.write_all(&redactor.push(&visible));
                    let _ = out.flush();
                }
                let mut c = captured.lock().unwrap();
                if c.len() < CAPTURE_CAP {
                    c.extend_from_slice(&clean);
                } else {
                    truncated.store(true, Ordering::SeqCst);
                }
            }
            if stream {
                let _ = out.write_all(&redactor.finish());
                let _ = out.flush();
            }
            drained.store(true, Ordering::SeqCst);
        });
    }

    // Wait for the shell, then for its output to end. The timeout and cancel
    // apply the whole time: a child that outlives the shell, or leaves the
    // process group, cannot keep this run going.
    let start = Instant::now();
    let mut timed_out = false;
    let mut status = None;
    let mut exited_at: Option<Instant> = None;
    let mut group_killed_at: Option<Instant> = None;
    loop {
        if exited_at.is_none() {
            match child.try_wait() {
                Ok(Some(s)) => {
                    status = Some(s);
                    exited_at = Some(Instant::now());
                }
                Ok(None) => {}
                Err(_) => exited_at = Some(Instant::now()),
            }
        }
        if exited_at.is_some() && drained.load(Ordering::SeqCst) {
            break;
        }
        let cancelled = CANCELLED.load(Ordering::SeqCst);
        let over = start.elapsed() >= timeout;
        match (exited_at, group_killed_at) {
            // The shell is still running.
            (None, _) => {
                if cancelled || over {
                    timed_out = over && !cancelled;
                    kill_group(pgid);
                    status = child.wait().ok();
                    exited_at = Some(Instant::now());
                    group_killed_at = exited_at;
                }
            }
            // The shell is gone but something still holds its output.
            (Some(at), None) => {
                if cancelled || over || at.elapsed() >= DRAIN_GRACE {
                    kill_group(pgid);
                    group_killed_at = Some(Instant::now());
                }
            }
            // Killed the group and it is still open: that process left the group.
            (Some(_), Some(at)) => {
                if at.elapsed() >= DRAIN_GIVE_UP {
                    break;
                }
            }
        }
        thread::sleep(Duration::from_millis(20));
    }
    let elapsed = exited_at.unwrap_or_else(Instant::now) - start;
    let mut output = String::from_utf8_lossy(&captured.lock().unwrap()).into_owned();
    // Complete here, where a chunk boundary can't split a secret.
    for secret in &secret_values {
        output = output.replace(secret.as_str(), "••••");
    }
    if truncated.load(Ordering::SeqCst) {
        if !output.ends_with('\n') {
            output.push('\n');
        }
        output.push_str("… output truncated at 5 MB\n");
    }
    let code = status.and_then(|s| s.code());

    let secs = format!("{:.1}s", elapsed.as_secs_f64());
    let status_line = if timed_out {
        format!("✗ killed after {}s timeout", timeout.as_secs())
    } else if CANCELLED.load(Ordering::SeqCst) {
        format!("✗ cancelled · {secs}")
    } else {
        match code {
            Some(0) => format!("✓ {secs}"),
            Some(n) => format!("✗ exit {n} · {secs}"),
            None => format!("✗ terminated by signal · {secs}"),
        }
    };

    let new_cwd = fs::read_to_string(&pwd_file)
        .ok()
        .map(PathBuf::from)
        .filter(|p| p.is_dir());
    let _ = fs::remove_file(&pwd_file);
    let final_cwd = new_cwd.as_deref().unwrap_or(cwd);

    finish(stream, &status_line, &output, final_cwd, code, max_lines);
    if std::env::var("TERMIGHT_NO_LOG").as_deref() != Ok("1") {
        log(home, typed, &status_line, &output, keep_history);
    }
}

fn finish(
    stream: bool,
    status: &str,
    output: &str,
    cwd: &Path,
    code: Option<i32>,
    max_lines: usize,
) {
    if stream {
        // Output already went out live; metadata goes on stderr.
        eprintln!("status\t{status}");
        eprintln!("cwd\t{}", cwd.display());
        eprintln!("code\t{}", code.map(|c| c.to_string()).unwrap_or_default());
        return;
    }
    // Status line first so it is visible even when output is long.
    println!("{status}");
    let lines: Vec<&str> = output.trim_end().lines().collect();
    let shown = lines.len().min(max_lines);
    for l in &lines[..shown] {
        println!("{l}");
    }
    if lines.len() > shown {
        let more = lines.len() - shown;
        if std::env::var("TERMIGHT_NO_LOG").as_deref() == Ok("1") {
            println!("… {more} more lines");
        } else {
            println!("… {more} more lines in ~/Library/Logs/termight/last.log");
        }
    }
}

/// Replaces each secret's value with •••• in streamed output. Works on bytes,
/// so a character split between chunks is left intact, and holds back the end
/// of a chunk while it could be the start of a secret that the next chunk
/// completes.
struct Redactor {
    secrets: Vec<Vec<u8>>,
    pending: Vec<u8>,
}

impl Redactor {
    const MASK: &'static [u8] = "••••".as_bytes();

    fn new(secrets: &[String]) -> Redactor {
        Redactor {
            secrets: secrets.iter().map(|s| s.as_bytes().to_vec()).collect(),
            pending: Vec::new(),
        }
    }

    fn push(&mut self, chunk: &[u8]) -> Vec<u8> {
        if self.secrets.is_empty() {
            return chunk.to_vec();
        }
        let mut data = std::mem::take(&mut self.pending);
        data.extend_from_slice(chunk);
        let mut out = self.replace(&data);
        // The longest tail that is the start of some secret waits for more.
        let hold = (1..=out.len().min(self.longest().saturating_sub(1)))
            .rev()
            .find(|&n| {
                let tail = &out[out.len() - n..];
                self.secrets
                    .iter()
                    .any(|s| s.len() > n && s.starts_with(tail))
            })
            .unwrap_or(0);
        self.pending = out.split_off(out.len() - hold);
        out
    }

    /// Whatever is held back, once the output has ended.
    fn finish(&mut self) -> Vec<u8> {
        std::mem::take(&mut self.pending)
    }

    fn longest(&self) -> usize {
        self.secrets.iter().map(Vec::len).max().unwrap_or(0)
    }

    fn replace(&self, data: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(data.len());
        let mut i = 0;
        'outer: while i < data.len() {
            for s in &self.secrets {
                if !s.is_empty() && data[i..].starts_with(s) {
                    out.extend_from_slice(Self::MASK);
                    i += s.len();
                    continue 'outer;
                }
            }
            out.push(data[i]);
            i += 1;
        }
        out
    }
}

/// A pseudo-terminal for `--color`, opened with libc calls (no dependencies).
mod pty {
    use std::ffi::CStr;
    use std::fs::{File, OpenOptions};
    use std::os::fd::FromRawFd;
    use std::os::unix::fs::OpenOptionsExt;

    unsafe extern "C" {
        fn posix_openpt(flags: i32) -> i32;
        fn grantpt(fd: i32) -> i32;
        fn unlockpt(fd: i32) -> i32;
        fn ptsname(fd: i32) -> *const std::ffi::c_char;
        fn fcntl(fd: i32, cmd: i32, ...) -> i32;
        fn ioctl(fd: i32, request: std::ffi::c_ulong, ...) -> i32;
    }
    const O_RDWR: i32 = 2;
    #[cfg(target_os = "macos")]
    const O_NOCTTY: i32 = 0x20000;
    #[cfg(not(target_os = "macos"))]
    const O_NOCTTY: i32 = 0o400;
    #[cfg(target_os = "macos")]
    const TIOCSWINSZ: std::ffi::c_ulong = 0x8008_7467;
    #[cfg(not(target_os = "macos"))]
    const TIOCSWINSZ: std::ffi::c_ulong = 0x5414;
    const F_SETFD: i32 = 2;
    const FD_CLOEXEC: i32 = 1;

    #[repr(C)]
    struct WinSize {
        rows: u16,
        cols: u16,
        x: u16,
        y: u16,
    }

    /// (master, slave). The slave is not made anyone's controlling terminal, so
    /// a program that opens /dev/tty to ask for a password still can't.
    pub fn open(cols: u16) -> std::io::Result<(File, File)> {
        let err = std::io::Error::last_os_error;
        unsafe {
            let fd = posix_openpt(O_RDWR | O_NOCTTY);
            if fd < 0 {
                return Err(err());
            }
            let master = File::from_raw_fd(fd);
            fcntl(fd, F_SETFD, FD_CLOEXEC);
            if grantpt(fd) != 0 || unlockpt(fd) != 0 {
                return Err(err());
            }
            let name = ptsname(fd);
            if name.is_null() {
                return Err(err());
            }
            let path = CStr::from_ptr(name).to_string_lossy().into_owned();
            let slave = OpenOptions::new()
                .read(true)
                .write(true)
                .custom_flags(O_NOCTTY)
                .open(path)?;
            let size = WinSize {
                rows: 50,
                cols,
                x: 0,
                y: 0,
            };
            ioctl(fd, TIOCSWINSZ, &size as *const WinSize);
            Ok((master, slave))
        }
    }
}

/// Strips terminal escape sequences (cursor moves, titles, and colors unless
/// `keep_color`) and turns lone `\r` (progress-bar redraws) into newlines,
/// or with `keep_color` passes them on for the app to redraw the line. Keeps
/// state across chunks.
#[derive(Default)]
struct Filter {
    state: FilterState,
    pending_cr: bool,
    /// Pass on SGR sequences (`ESC [ … m`, colors and styles) and lone `\r`.
    keep_color: bool,
    /// Parameter bytes of the CSI sequence being read.
    csi: Vec<u8>,
}

#[derive(Default, Clone, Copy, PartialEq)]
enum FilterState {
    #[default]
    Text,
    /// After ESC.
    Escape,
    /// `ESC [ … final byte`
    Csi,
    /// A string sequence (OSC, DCS, APC, PM, SOS) and how many bytes of it so far.
    Str(u16),
    /// ESC inside a string sequence: `ESC \` ends it.
    StrEscape(u16),
    /// `ESC (`, `)`, `*` or `+`: one more byte names a character set.
    Charset,
}

impl Filter {
    /// A string sequence should end with BEL or `ESC \`. One that never does
    /// must not swallow the rest of the output: stop at a newline or this length.
    const MAX_STRING: u16 = 1024;

    fn after_escape(b: u8) -> FilterState {
        match b {
            b'[' => FilterState::Csi,
            b']' | b'P' | b'_' | b'^' | b'X' => FilterState::Str(0),
            b'(' | b')' | b'*' | b'+' => FilterState::Charset,
            _ => FilterState::Text,
        }
    }

    fn push(&mut self, input: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(input.len());
        for &b in input {
            if self.pending_cr {
                self.pending_cr = false;
                if b != b'\n' {
                    out.push(if self.keep_color { b'\r' } else { b'\n' });
                }
            }
            self.state = match self.state {
                FilterState::Text => match b {
                    0x1b => FilterState::Escape,
                    b'\r' => {
                        self.pending_cr = true;
                        FilterState::Text
                    }
                    _ => {
                        out.push(b);
                        FilterState::Text
                    }
                },
                FilterState::Escape => {
                    self.csi.clear();
                    Self::after_escape(b)
                }
                FilterState::Csi => {
                    if (0x40..=0x7e).contains(&b) {
                        let sgr = b == b'm'
                            && self.csi.len() <= 64
                            && self
                                .csi
                                .iter()
                                .all(|c| c.is_ascii_digit() || *c == b';' || *c == b':');
                        if self.keep_color && sgr {
                            out.extend_from_slice(b"\x1b[");
                            out.extend_from_slice(&self.csi);
                            out.push(b'm');
                        }
                        FilterState::Text
                    } else {
                        if self.csi.len() <= 64 {
                            self.csi.push(b);
                        }
                        FilterState::Csi
                    }
                }
                FilterState::Str(n) => match b {
                    0x07 => FilterState::Text,
                    0x1b => FilterState::StrEscape(n),
                    b'\n' => {
                        out.push(b);
                        FilterState::Text
                    }
                    _ if n >= Self::MAX_STRING => FilterState::Text,
                    _ => FilterState::Str(n + 1),
                },
                FilterState::StrEscape(n) => match b {
                    b'\\' => FilterState::Text,
                    // Not a terminator: a new escape sequence starts here.
                    _ if n >= Self::MAX_STRING => Self::after_escape(b),
                    _ => match Self::after_escape(b) {
                        FilterState::Text => FilterState::Str(n + 1),
                        other => other,
                    },
                },
                FilterState::Charset => FilterState::Text,
            };
        }
        out
    }
}

/// One history field on one line: `\`, newline and tab are written as `\\`,
/// `\n` and `\t`. The launcher undoes this when it loads the file.
fn escape_field(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\t' => out.push_str("\\t"),
            '\r' => {}
            c => out.push(c),
        }
    }
    out
}

/// Logs are readable by this user only (folder 0700, files 0600): they hold
/// every command and its output. Failures are ignored on purpose: a full disk
/// or a read-only home must not stop the command's result from being shown,
/// and in stream mode stderr is the result channel.
fn log(home: &Path, cmd: &str, status: &str, output: &str, keep_history: bool) {
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let dir = home.join("Library/Logs/termight");
    shell::private_dir(&dir);
    let full = format!("$ {cmd}\n{status}\n{output}");
    let _ = shell::write_private(&dir.join("last.log"), full.as_bytes());
    // The launcher gives each job its own log so ⌘L opens the right one.
    if let Ok(path) = std::env::var("TERMIGHT_LOG_FILE") {
        let path = PathBuf::from(path);
        if let Some(parent) = path.parent() {
            shell::private_dir(parent);
        }
        let _ = shell::write_private(&path, full.as_bytes());
    }
    if !keep_history {
        return;
    }
    let history = dir.join("history.log");
    if let Ok(mut f) = OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(&history)
    {
        let _ = writeln!(f, "{ts}\t{status}\t{}", escape_field(cmd));
    }
    trim_history(&history);
}

/// Keep history.log from growing forever: past HISTORY_TRIM_AT, keep its last
/// HISTORY_KEEP lines.
fn trim_history(history: &Path) {
    use std::os::unix::fs::PermissionsExt;
    // Files from before the log was private.
    let _ = fs::set_permissions(history, fs::Permissions::from_mode(0o600));
    let too_big = fs::metadata(history).is_ok_and(|m| m.len() > HISTORY_TRIM_AT);
    if !too_big {
        return;
    }
    let Ok(text) = fs::read_to_string(history) else {
        return;
    };
    let lines: Vec<&str> = text.lines().collect();
    let keep = &lines[lines.len().saturating_sub(HISTORY_KEEP)..];
    let mut kept = keep.join("\n");
    kept.push('\n');
    let _ = shell::write_private(history, kept.as_bytes());
}

#[cfg(test)]
mod tests {
    use super::*;

    fn filtered(input: &[u8]) -> String {
        String::from_utf8(Filter::default().push(input)).unwrap()
    }

    #[test]
    fn filter_strips_ansi_and_cr() {
        assert_eq!(
            filtered(b"\x1b[1;32mgreen\x1b[0m ok\r\n50%\r100%\n\x1b]0;title\x07done"),
            "green ok\n50%\n100%\ndone"
        );
        // sequence split across chunks
        let mut f = Filter::default();
        let mut s = f.push(b"a\x1b[3");
        s.extend(f.push(b"1mb"));
        assert_eq!(String::from_utf8(s).unwrap(), "ab");
    }

    #[test]
    fn filter_survives_malformed_sequences() {
        // An OSC that never ends stops at the newline, not at the end of the output.
        assert_eq!(
            filtered(b"before\n\x1b]0;title\nmore\n"),
            "before\n\nmore\n"
        );
        // …or after MAX_STRING bytes when there is no newline either.
        let mut long = b"a\x1b]0;".to_vec();
        long.extend(std::iter::repeat_n(b'x', 2000));
        let out = filtered(&long);
        assert!(out.starts_with('a') && out.len() > 900 && out.len() < 1000);
        // OSC ended by ESC \ ; DCS, APC and PM strings.
        assert_eq!(
            filtered(b"a\x1b]8;;http://x\x1b\\link\x1b]8;;\x1b\\b"),
            "alinkb"
        );
        assert_eq!(
            filtered(b"a\x1bPdcs\x1b\\b\x1b_apc\x07c\x1b^pm\x1b\\d"),
            "abcd"
        );
        // Character-set selection takes one more byte.
        assert_eq!(filtered(b"a\x1b(Bb\x1b)0c"), "abc");
        // A new escape inside an unterminated string is still handled.
        assert_eq!(filtered(b"a\x1b]0;t\x1b[31mred"), "ared");
    }

    #[test]
    fn history_fields_stay_on_one_line() {
        assert_eq!(escape_field("echo a\necho b"), "echo a\\necho b");
        assert_eq!(escape_field("printf 'a\\tb'\t#x"), "printf 'a\\\\tb'\\t#x");
        assert!(!escape_field("a\r\nb").contains(['\n', '\r']));
    }

    #[test]
    fn filter_keeps_color_when_asked() {
        let mut f = Filter {
            keep_color: true,
            ..Filter::default()
        };
        let out = f.push(b"\x1b[1;31mred\x1b[0m \x1b[2Kx\x1b]0;title\x07 50%\r100%\r\n");
        assert_eq!(
            String::from_utf8(out).unwrap(),
            "\x1b[1;31mred\x1b[0m x 50%\r100%\n"
        );
        // Without it, the same input is plain text.
        assert_eq!(
            filtered(b"\x1b[1;31mred\x1b[0m 50%\r100%\r\n"),
            "red 50%\n100%\n"
        );
        // A long or odd CSI is never passed on.
        let mut f = Filter {
            keep_color: true,
            ..Filter::default()
        };
        let long = format!("\x1b[{}mz", "1;".repeat(60));
        assert_eq!(String::from_utf8(f.push(long.as_bytes())).unwrap(), "z");
        assert_eq!(String::from_utf8(f.push(b"\x1b[?25ly")).unwrap(), "y");
    }

    #[test]
    fn redactor_works_across_chunks_and_keeps_utf8() {
        let mut r = Redactor::new(&["s3cr3t-VALUE".to_string()]);
        // A chunk that is nothing but the start of the secret is held whole.
        let mut out = r.push(b"s3cr");
        assert!(out.is_empty());
        out.extend(r.push(b"3t-VALUE"));
        out.extend(r.finish());
        assert_eq!(String::from_utf8(out).unwrap(), "••••");
        let mut out = r.push(b"token: s3cr");
        out.extend(r.push(b"3t-VALUE\n"));
        out.extend(r.finish());
        assert_eq!(String::from_utf8(out).unwrap(), "token: ••••\n");
        // A tail that only looks like a secret's start comes out in the end.
        let mut out = r.push(b"ends with s3");
        assert_eq!(out, b"ends with ");
        out.extend(r.finish());
        assert_eq!(out, b"ends with s3");
        // A character split across chunks is not damaged.
        let e = "é".as_bytes();
        let mut out = r.push(&[b'x', e[0]]);
        out.extend(r.push(&[e[1], b'!']));
        assert_eq!(String::from_utf8(out).unwrap(), "xé!");
        // No secrets: nothing is held.
        let mut none = Redactor::new(&[]);
        assert_eq!(none.push(b"abc"), b"abc");
    }
}
