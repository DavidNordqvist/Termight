// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 David Nordqvist
//
// This file is part of Termight. Termight is free software: you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License, version 3, as published by the Free Software Foundation. It comes
// with no warranty. See the LICENSE file for the full text.

//! `--check`: is the typed line runnable, and does it need a real terminal?
//! `--complete`: Tab-completion candidates for the last word.
//! Both run on keystrokes, so they avoid spawning a shell (caches in shell.rs).

use crate::shell::{self, is_executable};
use crate::snippet;
use std::fs;
use std::path::{Path, PathBuf};

/// zsh/bash builtins and reserved words that have no file on PATH.
const BUILTINS: &[&str] = &[
    "!", ".", ":", "[", "[[", "{", "(", "((", "alias", "autoload", "bg", "bindkey", "break",
    "builtin", "case", "cd", "command", "continue", "declare", "dirs", "disown", "echo", "emulate",
    "eval", "exec", "exit", "export", "false", "fc", "fg", "for", "function", "getopts", "hash",
    "history", "if", "jobs", "kill", "let", "local", "noglob", "popd", "print", "printf", "pushd",
    "pwd", "read", "rehash", "repeat", "return", "select", "set", "setopt", "shift", "source",
    "test", "time", "trap", "true", "type", "typeset", "ulimit", "umask", "unalias", "unset",
    "unsetopt", "until", "wait", "whence", "where", "which", "while", "zmodload",
];

/// Full-screen or prompt-driven programs that hang without a TTY.
const ALWAYS_INTERACTIVE: &[&str] = &[
    "vim", "vi", "nvim", "nano", "emacs", "pico", "micro", "hx", "less", "more", "most", "man",
    "top", "htop", "btop", "atop", "glances", "tmux", "screen", "watch", "passwd", "su", "login",
    "ftp", "sftp", "telnet", "mosh", "visudo", "sudo", "ranger", "nnn", "lazygit", "tig", "fzf",
    "k9s", "vimtutor",
];

/// Programs that open a REPL when run with no arguments.
const REPL_WITHOUT_ARGS: &[&str] = &[
    "python",
    "python3",
    "node",
    "irb",
    "ruby",
    "ghci",
    "psql",
    "mysql",
    "sqlite3",
    "redis-cli",
    "bc",
    "lua",
    "R",
    "julia",
    "php",
    "ipython",
    "deno",
    "zsh",
    "bash",
    "sh",
    "fish",
];

/// ssh flags that take a value (so the value isn't mistaken for the host).
const SSH_VALUE_FLAGS: &[&str] = &[
    "-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L", "-l", "-m", "-O", "-o", "-p", "-Q",
    "-R", "-S", "-W", "-w", "-B",
];

/// Words that run the command after them: the check looks past these.
const WRAPPERS: &[&str] = &[
    "env", "command", "time", "nohup", "exec", "builtin", "noglob",
];

/// Commands after which the next word is again a command (for completion).
const COMMAND_PREFIXES: &[&str] = &[
    "|", "||", "&&", ";", "sudo", "time", "nohup", "xargs", "exec", "command",
];

pub struct Found {
    pub info: String,
    pub interactive: bool,
    /// A snippet still needs values. `info` then lists every unfilled
    /// placeholder, one per line, as `name` or `name<TAB>default`.
    pub needs: bool,
}

/// Ok when the line is runnable (info = how it resolved), Err(reason) otherwise.
///
/// This is a hint for the launcher's dot, decided without starting a shell. It
/// errs towards "runnable": a line the shell would accept must not be blocked
/// just because this cannot tell where its first word comes from.
pub fn check(line: &str, cwd: &Path, home: &Path, strict: bool) -> Result<Found, String> {
    let expansion = snippet::expand_snippet(line, home, strict);
    let is_snippet = expansion.is_snippet;
    if !expansion.required().is_empty() {
        let fields: Vec<String> = expansion.missing.iter().map(|m| m.field()).collect();
        return Ok(Found {
            info: fields.join("\n"),
            interactive: false,
            needs: true,
        });
    }
    if let Some(error) = expansion.error {
        return Err(error);
    }
    // Values shown in place: this text is only looked at, never run.
    let expanded = expansion.display;
    let resolved = resolve_line(&expanded, cwd, home)?;
    let info = if is_snippet {
        format!("snippet → {expanded}")
    } else {
        resolved
    };
    Ok(Found {
        info,
        interactive: segments(&expanded).iter().any(|s| is_interactive(s)),
        needs: false,
    })
}

/// Where a command called `name` comes from, ignoring snippets: for warning
/// that a snippet hides a real command.
pub fn which(name: &str, cwd: &Path, home: &Path) -> Option<String> {
    if name.is_empty() || name.contains(char::is_whitespace) {
        return None;
    }
    resolve(name, cwd, home).ok()
}

/// How the first command word of `line` resolves.
fn resolve_line(line: &str, cwd: &Path, home: &Path) -> Result<String, String> {
    if line.trim_start().starts_with('#') {
        return Ok("comment".into());
    }
    let mut tokens = line.split_whitespace().peekable();
    loop {
        let Some(tok) = tokens.peek().copied() else {
            // Nothing but assignments and redirections: the shell runs that.
            return if line.trim().is_empty() {
                Err("empty".into())
            } else {
                Ok("assignment".into())
            };
        };
        if is_assignment(tok) {
            tokens.next();
        } else if let Some(target_follows) = redirection(tok) {
            tokens.next();
            if target_follows {
                tokens.next();
            }
        } else {
            break;
        }
    }
    let tok = tokens.next().unwrap_or_default();
    // `\ls` runs ls, skipping any alias.
    let word = strip_quotes(tok.strip_prefix('\\').unwrap_or(tok));
    if word.is_empty() {
        return Err("empty".into());
    }
    if let Some(op) = leading_operator(&word) {
        return resolve(&op, cwd, home);
    }
    // `$HOME/bin/x`, `~user/x`, `$(which x)`: only the shell knows what these are.
    if word.contains('$')
        || word.contains('`')
        || (word.starts_with('~') && !word.starts_with("~/") && word != "~")
    {
        return Ok("runs as typed".into());
    }
    resolve(&word, cwd, home)
}

/// Is `tok` a redirection (`>file`, `2>&1`, `<`, `&>`)? Some(true) when its
/// target is the next word.
fn redirection(tok: &str) -> Option<bool> {
    let rest = tok.trim_start_matches(|c: char| c.is_ascii_digit());
    let rest = rest.strip_prefix('&').unwrap_or(rest);
    let after = rest.trim_start_matches(['>', '<']);
    if after.len() == rest.len() {
        return None;
    }
    Some(after.is_empty() || after == "|")
}

fn resolve(word: &str, cwd: &Path, home: &Path) -> Result<String, String> {
    if BUILTINS.contains(&word) {
        return Ok("builtin".into());
    }
    if word.contains('/') {
        let p = to_path(word, cwd, home);
        return if is_executable(&p) {
            Ok(p.display().to_string())
        } else {
            Err(format!("not executable: {word}"))
        };
    }
    let on_path = |path: &str| {
        path.split(':')
            .filter(|d| !d.is_empty())
            .map(|dir| Path::new(dir).join(word))
            .find(|p| is_executable(p))
    };
    if let Some(p) = on_path(&shell::login_path(home)) {
        return Ok(p.display().to_string());
    }
    if shell::rc_names(home).iter().any(|n| n == word) {
        return Ok("alias or function".into());
    }
    // Maybe it was installed since PATH was cached: look once more.
    if let Some(p) = shell::refreshed_login_path(home).and_then(|path| on_path(&path)) {
        return Ok(p.display().to_string());
    }
    Err(format!("not a command: {word}"))
}

/// The simple commands of a line: split at unquoted `;`, `|`, `&`, newlines
/// and parentheses, each as its words with quotes removed.
fn segments(line: &str) -> Vec<Vec<String>> {
    let mut out = vec![];
    let mut words: Vec<String> = vec![];
    let mut cur = String::new();
    let mut in_word = false;
    let mut quote: Option<char> = None;
    let mut chars = line.chars();
    while let Some(c) = chars.next() {
        match (quote, c) {
            (Some(q), c) if c == q => quote = None,
            (Some('"'), '\\') => cur.extend(chars.next()),
            (Some(_), c) => cur.push(c),
            (None, '\'' | '"') => {
                quote = Some(c);
                in_word = true;
            }
            (None, '\\') => {
                cur.extend(chars.next());
                in_word = true;
            }
            (None, c) if c.is_whitespace() || matches!(c, ';' | '|' | '&' | '(' | ')') => {
                if in_word {
                    words.push(std::mem::take(&mut cur));
                    in_word = false;
                }
                if (!c.is_whitespace() || c == '\n') && !words.is_empty() {
                    out.push(std::mem::take(&mut words));
                }
            }
            (None, c) => {
                cur.push(c);
                in_word = true;
            }
        }
    }
    if in_word {
        words.push(cur);
    }
    if !words.is_empty() {
        out.push(words);
    }
    out
}

fn is_assignment(tok: &str) -> bool {
    tok.split_once('=').is_some_and(|(name, _)| {
        !name.is_empty() && name.chars().all(|c| c.is_alphanumeric() || c == '_')
    })
}

fn strip_quotes(w: &str) -> String {
    let end = w.find([';', '|', '&', '<', '>', ')']).unwrap_or(w.len());
    w[..end]
        .chars()
        .filter(|c| *c != '\'' && *c != '"')
        .collect()
}

/// "(cd x" → "(", "{echo" → "{": the operator is the word.
fn leading_operator(w: &str) -> Option<String> {
    ["((", "[[", "(", "{", "!"]
        .iter()
        .find(|op| w.starts_with(**op))
        .map(|op| op.to_string())
}

fn to_path(word: &str, cwd: &Path, home: &Path) -> PathBuf {
    let p = match word.strip_prefix("~/") {
        Some(rest) => home.join(rest),
        None if word == "~" => home.to_path_buf(),
        None => PathBuf::from(word),
    };
    if p.is_absolute() { p } else { cwd.join(p) }
}

/// Does this simple command need a real terminal?
fn is_interactive(segment: &[String]) -> bool {
    // Look past `VAR=x`, and wrappers such as `env FOO=1` or `command`.
    let mut ws: Vec<&str> = segment.iter().map(String::as_str).collect();
    loop {
        match ws.first() {
            Some(w) if is_assignment(w) => {
                ws.remove(0);
            }
            Some(w) if WRAPPERS.contains(w) => {
                ws.remove(0);
                // env's own options and assignments.
                while ws
                    .first()
                    .is_some_and(|w| w.starts_with('-') || is_assignment(w))
                {
                    ws.remove(0);
                }
            }
            _ => break,
        }
    }
    let Some(first) = ws.first() else {
        return false;
    };
    let name = first.rsplit('/').next().unwrap_or(first);
    let args = &ws[1..];
    let has = |flags: &[&str]| args.iter().any(|a| flags.contains(a));

    match name {
        "sudo" if has(&["-n", "--non-interactive"]) => false,
        n if ALWAYS_INTERACTIVE.contains(&n) => true,
        n if REPL_WITHOUT_ARGS.contains(&n) => args.is_empty(),
        "ssh" => ssh_has_no_remote_command(args),
        "crontab" => has(&["-e"]),
        "git" => match args.first().copied() {
            Some("commit") => !args.iter().any(|a| {
                matches!(*a, "-F" | "--no-edit" | "-C" | "--file" | "--message") || (a.starts_with('-') && !a.starts_with("--") && a.contains('m')) // -m, -am
                    || a.starts_with("--message=")
            }),
            Some("rebase") => has(&["-i", "--interactive"]),
            Some("add") => has(&["-p", "-i", "--patch", "--interactive"]),
            _ => false,
        },
        "docker" | "podman" | "kubectl" => {
            has(&["-it", "-ti"]) || (has(&["-i", "--interactive"]) && has(&["-t", "--tty"]))
        }
        _ => false,
    }
}

fn ssh_has_no_remote_command(args: &[&str]) -> bool {
    let mut positional = 0;
    let mut i = 0;
    while i < args.len() {
        let a = args[i];
        if SSH_VALUE_FLAGS.contains(&a) {
            i += 2;
            continue;
        }
        if !a.starts_with('-') {
            positional += 1;
        }
        i += 1;
    }
    positional <= 1
}

/// Completion for the last word of `line`. Returns (word being completed, candidates).
pub fn complete(line: &str, cwd: &Path, home: &Path) -> (String, Vec<String>) {
    let new_word = line.is_empty() || line.ends_with(char::is_whitespace);
    let toks: Vec<&str> = line.split_whitespace().collect();
    let (token, before) = if new_word {
        ("", &toks[..])
    } else {
        (*toks.last().unwrap(), &toks[..toks.len() - 1])
    };

    let command_position = match before.last() {
        None => true,
        Some(prev) => {
            COMMAND_PREFIXES.contains(prev)
                || prev.ends_with(';')
                || prev.ends_with('|')
                || before.iter().all(|t| is_assignment(t))
        }
    };

    let mut cands = if command_position
        && !token.contains('/')
        && !token.starts_with('~')
        && !token.starts_with('.')
    {
        complete_command(token, home)
    } else {
        complete_path(token, cwd, home, command_position)
    };
    cands.sort();
    cands.dedup();
    cands.truncate(200);
    (token.to_string(), cands)
}

fn complete_command(prefix: &str, home: &Path) -> Vec<String> {
    if prefix.is_empty() {
        return vec![]; // listing every command on PATH isn't useful
    }
    let mut out: Vec<String> = BUILTINS
        .iter()
        .filter(|b| b.starts_with(prefix) && b.chars().all(char::is_alphanumeric))
        .map(|b| b.to_string())
        .collect();
    out.extend(shell::path_commands(home, prefix));
    out.extend(
        snippet::snippets(home)
            .into_iter()
            .map(|s| s.name)
            .filter(|n| n.starts_with(prefix)),
    );
    out.extend(
        shell::rc_names(home)
            .into_iter()
            .filter(|n| n.starts_with(prefix)),
    );
    out
}

fn complete_path(token: &str, cwd: &Path, home: &Path, executables_only: bool) -> Vec<String> {
    let raw = token.replace("\\ ", " ");
    if raw == "~" {
        return vec!["~/".into()];
    }
    let (dir_part, prefix) = match raw.rfind('/') {
        Some(i) => (&raw[..=i], &raw[i + 1..]),
        None => ("", raw.as_str()),
    };
    let dir = if dir_part.is_empty() {
        cwd.to_path_buf()
    } else {
        to_path(dir_part, cwd, home)
    };
    let Ok(entries) = fs::read_dir(&dir) else {
        return vec![];
    };

    entries
        .flatten()
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            if !name.starts_with(prefix) || (name.starts_with('.') && !prefix.starts_with('.')) {
                return None;
            }
            let is_dir = e.path().is_dir();
            if executables_only && !is_dir && !is_executable(&e.path()) {
                return None;
            }
            let full = format!("{dir_part}{name}{}", if is_dir { "/" } else { "" });
            Some(full.replace(' ', "\\ "))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn home() -> PathBuf {
        PathBuf::from(std::env::var("HOME").unwrap())
    }

    fn interactive(line: &str) -> bool {
        segments(line).iter().any(|s| is_interactive(s))
    }

    fn ok(line: &str) -> bool {
        let h = home();
        check(line, &h, &h, false).is_ok()
    }

    #[test]
    fn check_cases() {
        let h = home();
        assert!(ok("ls ~"));
        assert!(ok("FOO=1 BAR=x ls"));
        assert!(ok("cd /tmp"));
        assert!(ok("(cd /tmp; ls)"));
        assert!(ok("/bin/echo hi"));
        assert!(!ok("zzqx is not real"));
        assert!(!ok("/nope/thing"));
        assert!(!ok("   "));
        // relative paths resolve against cwd
        assert!(check("./ls", Path::new("/bin"), &h, false).is_ok());
        assert!(check("./ls", &h, &h, false).is_err());
    }

    /// Finding 10: lines the shell runs must not be blocked as "not a command".
    #[test]
    fn check_does_not_block_what_the_shell_runs() {
        for line in [
            "a=b",
            "FOO=1",
            "\\ls",
            ">/dev/null echo hi",
            "2>&1 ls",
            "> /dev/null ls",
            "$HOME/bin/x",
            "~root/bin/x",
            "$(which ls) -l",
            "# just a comment",
        ] {
            assert!(ok(line), "{line} should be allowed");
        }
        assert!(!ok("> /dev/null zzqx"));
        assert!(!ok("\\zzqx"));
    }

    #[test]
    fn redirections() {
        assert_eq!(redirection(">"), Some(true));
        assert_eq!(redirection("2>"), Some(true));
        assert_eq!(redirection(">>"), Some(true));
        assert_eq!(redirection(">/dev/null"), Some(false));
        assert_eq!(redirection("2>&1"), Some(false));
        assert_eq!(redirection("&>out"), Some(false));
        assert_eq!(redirection("<in"), Some(false));
        assert_eq!(redirection("ls"), None);
        assert_eq!(redirection("2"), None);
    }

    #[test]
    fn which_ignores_snippets() {
        let h = home();
        assert!(which("ls", &h, &h).is_some());
        assert_eq!(which("cd", &h, &h).as_deref(), Some("builtin"));
        assert!(which("zzqx", &h, &h).is_none());
        assert!(which("", &h, &h).is_none());
    }

    #[test]
    fn interactive_cases() {
        for yes in [
            "vim notes.txt",
            "top",
            "python3",
            "ssh myhost",
            "ssh -i key.pem -p 22 myhost",
            "sudo rm x",
            "git commit",
            "git rebase -i HEAD~3",
            "docker run -it ubuntu",
            "crontab -e",
            // Finding 10: anywhere on the line, and behind a wrapper.
            "echo hi; vim x",
            "cd /tmp && vim x",
            "env FOO=1 vim x",
            "command vim x",
            "echo x | sudo tee /f",
            "FOO=1 vim x",
            "(cd /tmp; top)",
            "time nohup less f",
        ] {
            assert!(interactive(yes), "{yes} should be interactive");
        }
        for no in [
            "ls",
            "python3 script.py",
            "ssh myhost uptime",
            "sudo -n true",
            "git commit -m 'x'",
            "git commit -am wip",
            "git status",
            "docker ps",
            "crontab -l",
            "FOO=1 make",
            "echo 'vim; top'",
            "echo vim",
            "ls | grep vim",
            "env FOO=1 make",
        ] {
            assert!(!interactive(no), "{no} should not be interactive");
        }
    }

    #[test]
    fn completion_cases() {
        let h = home();
        let (tok, c) = complete("gi", &h, &h);
        assert_eq!(tok, "gi");
        assert!(c.contains(&"git".to_string()));

        let (tok, c) = complete("ls /us", &h, &h);
        assert_eq!(tok, "/us");
        assert_eq!(c, vec!["/usr/".to_string()]);

        let (tok, c) = complete("cd ", Path::new("/"), &h);
        assert_eq!(tok, "");
        assert!(c.contains(&"usr/".to_string()));
        assert!(
            !c.iter().any(|x| x.starts_with('.')),
            "hidden files only with a . prefix"
        );

        let (_, c) = complete("ls ~", &h, &h);
        assert_eq!(c, vec!["~/".to_string()]);

        let (_, c) = complete("echo hi | gre", &h, &h);
        assert!(c.contains(&"grep".to_string()));
    }
}
