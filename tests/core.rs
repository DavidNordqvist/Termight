// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 David Nordqvist
//
// This file is part of Termight. Termight is free software: you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License, version 3, as published by the Free Software Foundation. It comes
// with no warranty. See the LICENSE file for the full text.

//! End-to-end tests of the termight-core binary.

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

/// Builds the binary's own path for end-to-end tests.
fn core() -> Command {
    Command::new(env!("CARGO_BIN_EXE_termight"))
}

/// The core runs commands in zsh or bash only. macOS has zsh; the Linux CI
/// runner has bash and no zsh.
fn shell() -> &'static str {
    if Path::new("/bin/zsh").exists() {
        "/bin/zsh"
    } else {
        "/bin/bash"
    }
}

fn scratch(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("termight-test-{tag}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&d);
    fs::create_dir_all(&d).unwrap();
    d
}

/// Finding 5: a child that keeps the output open must not outlast the
/// shell, the timeout or a cancel.
#[test]
fn background_child_does_not_hold_the_run() {
    let home = scratch("bg");
    let start = Instant::now();
    let out = core()
        .args(["--", "sleep 8 & echo started"])
        .env("HOME", &home)
        .env("SHELL", shell())
        .env("TERMIGHT_TIMEOUT", "5")
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.contains("started"), "{text}");
    assert!(text.starts_with('✓'), "{text}");
    assert!(
        start.elapsed() < Duration::from_secs(4),
        "took {:?}",
        start.elapsed()
    );
    let _ = fs::remove_dir_all(&home);
}

#[test]
fn timeout_applies_to_a_child_that_left_the_group() {
    let home = scratch("pgrp");
    let start = Instant::now();
    // perl moves itself to a new process group, so killing the command's
    // group does not reach it; the run must still end near the timeout.
    if !Path::new("/usr/bin/perl").exists() {
        return;
    }
    let out = core()
        .args(["--", "perl -e 'setpgrp(0,0); sleep 9' & sleep 9"])
        .env("HOME", &home)
        .env("SHELL", shell())
        .env("TERMIGHT_TIMEOUT", "1")
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.contains("killed after 1s timeout"), "{text}");
    assert!(
        start.elapsed() < Duration::from_secs(5),
        "took {:?}",
        start.elapsed()
    );
    let _ = fs::remove_dir_all(&home);
}

/// Finding 8: a command with a newline is one history row.
#[test]
fn multi_line_command_is_one_history_row() {
    let home = scratch("hist");
    core()
        .args(["--", "echo one\necho two"])
        .env("HOME", &home)
        .env("SHELL", shell())
        .output()
        .unwrap();
    core()
        .args(["--", " echo secret"])
        .env("HOME", &home)
        .env("SHELL", shell())
        .output()
        .unwrap();
    let history = fs::read_to_string(home.join("Library/Logs/termight/history.log")).unwrap();
    let rows: Vec<&str> = history.lines().collect();
    assert_eq!(rows.len(), 1, "{history}");
    assert!(rows[0].ends_with("\techo one\\necho two"), "{history}");
    assert!(!history.contains("secret"), "a leading space skips history");

    use std::os::unix::fs::PermissionsExt;
    let mode = |p: &str| fs::metadata(home.join(p)).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode("Library/Logs/termight"), 0o700);
    assert_eq!(mode("Library/Logs/termight/history.log"), 0o600);
    assert_eq!(mode("Library/Logs/termight/last.log"), 0o600);
    let _ = fs::remove_dir_all(&home);
}

/// A snippet value shaped like `a[$(cmd)]` is refused before anything runs,
/// even where the snippet puts it in arithmetic the core can't see (`let`).
#[test]
fn arithmetic_shaped_value_runs_nothing() {
    let home = scratch("arith");
    let marker = home.join("PWNED");
    let dir = home.join("Library/Application Support/Termight");
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("snippets.tsv"),
        "t\tlet \"x = {v}\"; echo ran\nn\techo $(( {#n} * 2 ))\n",
    )
    .unwrap();
    let line = format!("t 'a[$(touch {})]'", marker.display());
    let out = core()
        .args(["--", &line])
        .env("HOME", &home)
        .env("SHELL", shell())
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.starts_with('✗'), "{text}");
    assert!(!text.contains("ran"), "{text}");
    assert!(!marker.exists(), "value ran as code");

    let out = core()
        .args(["--", "n 21"])
        .env("HOME", &home)
        .env("SHELL", shell())
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.contains("42"), "{text}");
    let _ = fs::remove_dir_all(&home);
}

/// --color: the command sees a terminal (so it colors), a pipe inside it does
/// not, and colors arrive as SGR codes while the log stays plain.
#[test]
fn color_runs_on_a_terminal() {
    let home = scratch("color");
    let out = core()
        .args([
            "--stream",
            "--color",
            "--",
            "[ -t 1 ] && echo tty; [ -t 1 ] | cat; (test -t 1 && echo inner-tty) | cat; printf '\\033[32mok\\033[0m\\n'",
        ])
        .env("HOME", &home)
        .env("SHELL", shell())
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.contains("tty\n"), "{text:?}");
    assert!(
        !text.contains("inner-tty"),
        "a pipe is not a terminal: {text:?}"
    );
    assert!(text.contains("\x1b[32mok\x1b[0m"), "{text:?}");
    let log = fs::read_to_string(home.join("Library/Logs/termight/last.log")).unwrap();
    assert!(log.contains("ok") && !log.contains('\x1b'), "{log:?}");
    let _ = fs::remove_dir_all(&home);
}

/// A secret's value never shows in the output or the logs, and
/// TERMIGHT_NO_LOG writes nothing.
#[test]
fn secrets_are_redacted_and_no_log_writes_nothing() {
    let home = scratch("redact");
    let dir = home.join("Library/Application Support/Termight");
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("snippets.tsv"), "show\techo token={!api}\n").unwrap();
    let out = core()
        .args(["--stream", "--", "show"])
        .env("HOME", &home)
        .env("SHELL", shell())
        .env("TERMIGHT_SECRET_api", "hunter22")
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&out.stdout);
    assert_eq!(text, "token=••••\n");
    let log = fs::read_to_string(home.join("Library/Logs/termight/last.log")).unwrap();
    assert!(
        !log.contains("hunter22") && log.contains("token=••••"),
        "{log}"
    );

    let quiet = scratch("nolog");
    core()
        .args(["--", "echo hi"])
        .env("HOME", &quiet)
        .env("SHELL", shell())
        .env("TERMIGHT_NO_LOG", "1")
        .output()
        .unwrap();
    assert!(!quiet.join("Library/Logs/termight").exists());
    let _ = fs::remove_dir_all(&home);
    let _ = fs::remove_dir_all(&quiet);
}

/// SIGTERM (the launcher's Esc) still stops a running command promptly, and
/// a command that exits at once still reports its exit code.
#[test]
fn cancel_and_exit_codes_still_work() {
    let home = scratch("cancel");
    let child = core()
        .args(["--", "sleep 30"])
        .env("HOME", &home)
        .env("SHELL", shell())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    std::thread::sleep(Duration::from_millis(500));
    let start = Instant::now();
    unsafe { kill(child.id() as i32, 15) };
    let out = child.wait_with_output().unwrap();
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.starts_with("✗ cancelled"), "{text}");
    assert!(
        start.elapsed() < Duration::from_secs(3),
        "took {:?}",
        start.elapsed()
    );

    let out = core()
        .args(["--", "exit 7"])
        .env("HOME", &home)
        .env("SHELL", shell())
        .output()
        .unwrap();
    let text = String::from_utf8_lossy(&out.stdout);
    assert!(text.starts_with("✗ exit 7"), "{text}");
    let _ = fs::remove_dir_all(&home);
}

unsafe extern "C" {
    fn kill(pid: i32, sig: i32) -> i32;
}
