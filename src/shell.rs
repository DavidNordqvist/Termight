// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 David Nordqvist
//
// This file is part of Termight. Termight is free software: you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License, version 3, as published by the Free Software Foundation. It comes
// with no warranty. See the LICENSE file for the full text.

//! Shell detection, the user's login PATH, rc-file aliases/functions, and the
//! private files the core keeps (caches, logs).

use std::fs;
use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime};

const CACHE_TTL: Duration = Duration::from_secs(3600);
/// A command that is not on the cached PATH triggers one fresh look, but not
/// more often than this: every keystroke of a typo would start a shell.
const MISS_REFRESH_AFTER: Duration = Duration::from_secs(30);

/// Create `dir` (and parents) readable by this user only.
pub fn private_dir(dir: &Path) {
    let _ = fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir);
    let _ = fs::set_permissions(dir, fs::Permissions::from_mode(0o700));
}

/// Write `data` to `path`, readable by this user only, replacing the file in
/// one step so a reader never sees half of it.
pub fn write_private(path: &Path, data: &[u8]) -> std::io::Result<()> {
    let tmp = path.with_extension(format!("tmp{}", std::process::id()));
    let mut f = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)?;
    f.write_all(data)?;
    drop(f);
    fs::rename(&tmp, path)
}

#[derive(Clone, Copy, PartialEq)]
pub enum Kind {
    Zsh,
    Bash,
}

pub struct Shell {
    pub path: String,
    pub kind: Kind,
}

impl Shell {
    /// The user's $SHELL if it is zsh or bash; otherwise /bin/zsh (the run
    /// script uses POSIX-ish syntax that fish and others don't accept).
    pub fn detect() -> Shell {
        let s = std::env::var("SHELL").unwrap_or_default();
        if s.ends_with("/zsh") {
            Shell {
                path: s,
                kind: Kind::Zsh,
            }
        } else if s.ends_with("/bash") {
            Shell {
                path: s,
                kind: Kind::Bash,
            }
        } else {
            Shell {
                path: "/bin/zsh".into(),
                kind: Kind::Zsh,
            }
        }
    }

    fn rc_prelude(&self) -> &'static str {
        match self.kind {
            Kind::Zsh => "[ -f ~/.zshrc ] && source ~/.zshrc >/dev/null 2>&1; ",
            Kind::Bash => {
                "shopt -s expand_aliases; [ -f ~/.bashrc ] && source ~/.bashrc >/dev/null 2>&1; "
            }
        }
    }

    /// Script for `shell -lc <script> termight <command>`: runs $1 with stderr
    /// merged, then records the final directory so `cd` can persist.
    pub fn run_script(&self, rc: bool) -> String {
        format!(
            "{}eval \"$1\" 2>&1; __termight_s=$?; printf %s \"$PWD\" > \"$TERMIGHT_PWD_FILE\" 2>/dev/null; exit $__termight_s",
            if rc { self.rc_prelude() } else { "" }
        )
    }

    fn rc_file(&self, home: &Path) -> PathBuf {
        home.join(match self.kind {
            Kind::Zsh => ".zshrc",
            Kind::Bash => ".bashrc",
        })
    }
}

/// Set by the app when "Load shell config" is on.
pub fn rc_enabled() -> bool {
    std::env::var("TERMIGHT_RC").is_ok_and(|v| v == "1")
}

fn cache_dir(home: &Path) -> PathBuf {
    home.join("Library/Caches/termight")
}

fn is_fresh(cache: &Path, newer_than: Option<&Path>) -> bool {
    let Ok(t) = fs::metadata(cache).and_then(|m| m.modified()) else {
        return false;
    };
    // A modification time in the future is not trusted.
    match SystemTime::now().duration_since(t) {
        Ok(age) if age < CACHE_TTL => {}
        _ => return false,
    }
    match newer_than.and_then(|p| fs::metadata(p).and_then(|m| m.modified()).ok()) {
        Some(src) => t >= src,
        None => true,
    }
}

/// PATH as the user's login shell sees it (GUI apps get a minimal PATH).
/// Cached for an hour so keystroke checks don't start a shell.
pub fn login_path(home: &Path) -> String {
    let cache = cache_dir(home).join("path");
    if is_fresh(&cache, None)
        && let Ok(p) = fs::read_to_string(&cache)
    {
        return p;
    }
    compute_login_path(home)
}

/// Ask the login shell for PATH and cache it.
fn compute_login_path(home: &Path) -> String {
    let sh = Shell::detect();
    let path = Command::new(&sh.path)
        // A newline first, then PATH: whatever a login file prints lands on
        // earlier lines, and only the last line is taken.
        .args(["-lc", "printf '\\n%s' \"$PATH\""])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| {
            String::from_utf8_lossy(&o.stdout)
                .lines()
                .next_back()
                .unwrap_or_default()
                .to_string()
        })
        .filter(|p| !p.is_empty())
        .unwrap_or_else(|| std::env::var("PATH").unwrap_or_default());
    private_dir(&cache_dir(home));
    let _ = write_private(&cache_dir(home).join("path"), path.as_bytes());
    path
}

/// A fresh PATH when the cached one is old enough that a newly installed
/// command could be missing from it; None when it was refreshed just now.
pub fn refreshed_login_path(home: &Path) -> Option<String> {
    let cache = cache_dir(home).join("path");
    let age = fs::metadata(&cache)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| SystemTime::now().duration_since(t).ok());
    match age {
        Some(a) if a < MISS_REFRESH_AFTER => None,
        _ => Some(compute_login_path(home)),
    }
}

/// Alias and function names from the rc file. Empty unless rc loading is on.
/// Cached; refreshed when the rc file changes or after an hour.
pub fn rc_names(home: &Path) -> Vec<String> {
    if !rc_enabled() {
        return vec![];
    }
    let sh = Shell::detect();
    let cache = cache_dir(home).join("rcnames");
    let text = if is_fresh(&cache, Some(&sh.rc_file(home))) {
        fs::read_to_string(&cache).unwrap_or_default()
    } else {
        let list = match sh.kind {
            Kind::Zsh => "print -rl -- ${(k)aliases} ${(k)functions}",
            Kind::Bash => "compgen -a; compgen -A function",
        };
        let script = format!("{}{list}", sh.rc_prelude());
        let out = Command::new(&sh.path)
            .args(["-lc", &script])
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
            .unwrap_or_default();
        private_dir(&cache_dir(home));
        let _ = write_private(&cache, out.as_bytes());
        out
    };
    text.lines()
        .map(str::trim)
        .filter(|n| !n.is_empty() && !n.starts_with('_'))
        .map(String::from)
        .collect()
}

pub fn is_executable(p: &Path) -> bool {
    fs::metadata(p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// Executable names on the login PATH starting with `prefix`.
pub fn path_commands(home: &Path, prefix: &str) -> Vec<String> {
    let mut out = vec![];
    for dir in login_path(home).split(':').filter(|d| !d.is_empty()) {
        let Ok(entries) = fs::read_dir(dir) else {
            continue;
        };
        for e in entries.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if name.starts_with(prefix) && is_executable(&e.path()) {
                out.push(name);
            }
        }
    }
    out
}
