// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 David Nordqvist
//
// This file is part of Termight. Termight is free software: you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License, version 3, as published by the Free Software Foundation. It comes
// with no warranty. See the LICENSE file for the full text.

//! Snippets: short names for commands, with `{placeholder}` values.
//!
//! A value is never written into the shell text. Each one is passed to the
//! shell as an environment variable, and the command refers to it
//! (`"${TERMIGHT_VALUE_1}"`), so the shell cannot parse the value as code
//! whatever it contains. The quoting around the reference depends on where the
//! placeholder sits.
//!
//! Placeholders:
//! - `{name}`, `{name:default}`: text, filled by the words typed after the
//!   snippet's name, in order.
//! - `{#name}`: a whole number.
//! - `{name|a|b|c}`: one of the listed choices.
//! - `{!name}`: a secret. Never typed: the app reads it from the Keychain and
//!   passes it as `TERMIGHT_SECRET_<name>`. Shown as `••••`.
//! - `{files}`: the files selected in Finder (`TERMIGHT_FILES` = count,
//!   `TERMIGHT_FILE_1` …), one word each. Files with no `{files}` in the
//!   command are added at its end.
//!
//! Arithmetic is the exception to "never parsed": it reads a variable's content
//! as an expression, and an array subscript in that expression can run a
//! command (`a[$(cmd)]`). So:
//! - Inside `$(( … ))` and `(( … ))`, only `{#name}` and `{name|…}` (whose
//!   values the snippet's author wrote) are allowed.
//! - Any typed text value with a `[` followed by `$` or a backtick is refused
//!   wherever the placeholder sits, because arithmetic the scanner does not
//!   see (`let`, `[[ a -eq b ]]`, a subscript, `typeset -i`) could run it. What
//!   remains there: a value like `x=5` can still set a shell variable.
//!
//! Not covered: commands that parse their arguments again (`eval`, `sh -c`,
//! `ssh host …`). A snippet that puts a placeholder there gets the value
//! evaluated by that command, as its author wrote it.

use std::fs;
use std::path::Path;

pub struct Snippet {
    pub name: String,
    pub command: String,
}

/// Snippets saved by the app: one `name<TAB>command` per line.
pub fn snippets(home: &Path) -> Vec<Snippet> {
    let file = home.join("Library/Application Support/Termight/snippets.tsv");
    fs::read_to_string(file)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| l.split_once('\t'))
        .filter(|(n, c)| !n.trim().is_empty() && !c.trim().is_empty())
        .map(|(n, c)| Snippet {
            name: n.trim().into(),
            command: c.trim().into(),
        })
        .collect()
}

/// What the app passes in besides the typed line.
#[derive(Default)]
pub struct Inputs {
    /// Files selected in Finder.
    pub files: Vec<String>,
    /// Names of the secrets the app supplied (`TERMIGHT_SECRET_<name>` is set).
    pub secrets: Vec<String>,
}

impl Inputs {
    pub fn from_env() -> Inputs {
        let count: usize = std::env::var("TERMIGHT_FILES")
            .ok()
            .and_then(|n| n.parse().ok())
            .unwrap_or(0);
        let files = (1..=count.min(10_000))
            .filter_map(|i| std::env::var(format!("TERMIGHT_FILE_{i}")).ok())
            .collect();
        let secrets = std::env::vars()
            .filter_map(|(k, _)| k.strip_prefix(SECRET_PREFIX).map(String::from))
            .collect();
        Inputs { files, secrets }
    }
}

pub const SECRET_PREFIX: &str = "TERMIGHT_SECRET_";

/// Result of expanding a typed line against the saved snippets.
pub struct Expansion {
    /// What the shell runs. Values appear only as references to `env`.
    pub command: String,
    /// The values, as environment variables for the shell.
    pub env: Vec<(String, String)>,
    /// The command with values shown in place (secrets as ••••), for people
    /// and for the launcher's heuristics. Never run.
    pub display: String,
    pub is_snippet: bool,
    /// Placeholders still waiting for a value, in order.
    pub missing: Vec<Missing>,
    /// Names of the secrets the command refers to.
    pub secrets: Vec<String>,
    /// Why this line cannot be expanded safely.
    pub error: Option<String>,
}

/// What kind of value a placeholder takes.
#[derive(Clone, Debug, PartialEq)]
pub enum Kind {
    Text,
    Number,
    Choice(Vec<String>),
    Secret,
}

/// A placeholder still waiting for a value.
#[derive(Debug, PartialEq)]
pub struct Missing {
    pub name: String,
    pub default: Option<String>,
    pub kind: Kind,
}

impl Missing {
    /// As written in the snippet: `{name}`, `{#name}`, `{name|a|b}`, `{!name}`.
    pub fn label(&self) -> String {
        label(&self.name, &self.kind)
    }

    /// One line for the launcher: name, `=default` or empty, kind, then the
    /// choices, separated by tabs.
    pub fn field(&self) -> String {
        let clean = |s: &str| s.replace(['\t', '\n'], " ");
        let mut parts = vec![
            clean(&self.name),
            self.default
                .as_deref()
                .map(|d| format!("={}", clean(d)))
                .unwrap_or_default(),
        ];
        match &self.kind {
            Kind::Text => parts.push("text".into()),
            Kind::Number => parts.push("number".into()),
            Kind::Secret => parts.push("secret".into()),
            Kind::Choice(options) => {
                parts.push("choice".into());
                parts.extend(options.iter().map(|o| clean(o)));
            }
        }
        parts.join("\t")
    }
}

fn label(name: &str, kind: &Kind) -> String {
    match kind {
        Kind::Text => format!("{{{name}}}"),
        Kind::Number => format!("{{#{name}}}"),
        Kind::Secret => format!("{{!{name}}}"),
        Kind::Choice(options) => format!("{{{name}|{}}}", options.join("|")),
    }
}

impl Expansion {
    /// Missing placeholders that have no default: the command can't run without them.
    pub fn required(&self) -> Vec<&str> {
        self.required_missing().map(|m| m.name.as_str()).collect()
    }

    /// The same, as written in the snippet (`{host}`, `{#port}`), for messages.
    pub fn required_labels(&self) -> Vec<String> {
        self.required_missing().map(Missing::label).collect()
    }

    fn required_missing(&self) -> impl Iterator<Item = &Missing> {
        self.missing.iter().filter(|m| m.default.is_none())
    }

    /// `command` as one script that carries its own values: an `export` line
    /// per value, then the command. For running it somewhere else (Terminal).
    /// Refused for a command with secrets, which would end up in that script.
    pub fn script(&self) -> Result<String, String> {
        if !self.secrets.is_empty() {
            return Err("a snippet with a secret runs only in Termight, not in Terminal".into());
        }
        let mut out = String::new();
        for (name, value) in &self.env {
            out.push_str(&format!(
                "export {name}='{}'\n",
                value.replace('\'', "'\\''")
            ));
        }
        out.push_str(&self.command);
        Ok(out)
    }
}

/// If the first word is a snippet name, swap in its command.
///
/// Each distinct typed placeholder (`{name}`, `{#name}`, `{name|…}`) is one
/// slot, in order of first appearance; the Nth word typed after the snippet
/// name fills the Nth slot (every occurrence of that name). Words past the
/// last slot are appended exactly as typed, unless `strict`: then they are
/// refused, because the caller (a shortcut) may be passing text nobody typed
/// as a command.
///
/// Not placeholders: `${VAR}`, `@{upstream}`, `%{http_code}`, `\{name}`, braces
/// that hold no identifier (`{1..3}`, `{}`, `{print $1|"sort"}`), and
/// `{{name}}`, which stands for a literal `{name}`.
pub fn expand_snippet(line: &str, home: &Path, strict: bool) -> Expansion {
    expand_inputs(line, &snippets(home), strict, &Inputs::from_env())
}

#[cfg(test)]
pub fn expand_with(line: &str, snippets: &[Snippet], strict: bool) -> Expansion {
    expand_inputs(line, snippets, strict, &Inputs::default())
}

pub fn expand_inputs(line: &str, snippets: &[Snippet], strict: bool, inputs: &Inputs) -> Expansion {
    let file_env: Vec<(String, String)> = inputs
        .files
        .iter()
        .enumerate()
        .map(|(i, f)| (format!("TERMIGHT_FILE_{}", i + 1), f.clone()))
        .collect();
    let file_refs = file_env
        .iter()
        .map(|(var, _)| format!("\"${{{var}}}\""))
        .collect::<Vec<_>>()
        .join(" ");
    let file_display = inputs
        .files
        .iter()
        .map(|f| display_word(f))
        .collect::<Vec<_>>()
        .join(" ");

    let trimmed = line.trim_start();
    let (first, rest) = trimmed
        .split_once(char::is_whitespace)
        .unwrap_or((trimmed, ""));
    let Some(s) = snippets.iter().find(|s| s.name == first) else {
        // Not a snippet: selected files go at the end.
        let mut command = line.to_string();
        let mut display = line.to_string();
        if !file_env.is_empty() {
            command = format!("{} {file_refs}", command.trim_end());
            display = format!("{} {file_display}", display.trim_end());
        }
        return Expansion {
            command,
            env: file_env,
            display,
            is_snippet: false,
            missing: vec![],
            secrets: vec![],
            error: None,
        };
    };

    let pieces = scan(&s.command);
    let mut slots: Vec<Slot> = vec![];
    for p in &pieces {
        let Piece::Slot {
            name,
            default,
            kind,
            ..
        } = p
        else {
            continue;
        };
        if !kind.is_typed() {
            continue;
        }
        match slots.iter_mut().find(|s| s.name == *name) {
            // `{#n}` or `{n|…}` anywhere decides the slot's kind everywhere.
            Some(slot) => {
                if slot.kind == PieceKind::Text {
                    slot.kind = kind.clone();
                }
            }
            None => slots.push(Slot {
                name,
                default: *default,
                kind: kind.clone(),
            }),
        }
    }

    let (typed, remainder) = take_words(rest, slots.len());
    let mut error: Option<String> = None;
    // A number goes to the shell in canonical form ("007" → "7"), so
    // arithmetic never reads it as octal.
    let values: Vec<String> = typed
        .iter()
        .zip(&slots)
        .map(|(v, slot)| match slot.check(v) {
            Ok(v) => v,
            Err(why) => {
                error.get_or_insert(why);
                v.clone()
            }
        })
        .collect();
    let mut command = String::new();
    let mut display = String::new();
    let mut secrets: Vec<String> = vec![];
    let mut missing_secrets: Vec<String> = vec![];
    let mut used_files = false;
    for p in &pieces {
        let (name, context, kind) = match p {
            Piece::Text(t) => {
                command.push_str(t);
                display.push_str(t);
                continue;
            }
            Piece::Slot {
                name,
                context,
                kind,
                ..
            } => (*name, *context, kind),
        };
        match kind {
            PieceKind::Secret => {
                let var = format!("{SECRET_PREFIX}{name}");
                match context.reference(&var, false) {
                    Some(r) => command.push_str(&r),
                    None => {
                        error.get_or_insert(format!("{{!{name}}} can't be used inside $(( ))"));
                    }
                }
                display.push_str("••••");
                if !secrets.iter().any(|s| s == name) {
                    secrets.push(name.to_string());
                }
                if !inputs.secrets.iter().any(|s| s == name)
                    && !missing_secrets.iter().any(|s| s == name)
                {
                    missing_secrets.push(name.to_string());
                }
            }
            PieceKind::Files => {
                used_files = true;
                if inputs.files.is_empty() {
                    error.get_or_insert(
                        "{files} is filled from Finder: select files, then right-click → Quick Actions → Run in Termight"
                            .into(),
                    );
                    command.push_str("{files}");
                } else if context == Context::Plain {
                    command.push_str(&file_refs);
                } else {
                    error.get_or_insert(
                        "{files} must not be inside quotes or $( ), where the files would not be one word each"
                            .into(),
                    );
                }
                display.push_str(&file_display);
            }
            _ => {
                let i = slots.iter().position(|s| s.name == name).unwrap_or(0);
                let slot = &slots[i];
                match (typed.get(i), slot.default) {
                    (Some(v), _) => {
                        let var = format!("TERMIGHT_VALUE_{}", i + 1);
                        match context.reference(&var, slot.kind.safe_in_arithmetic()) {
                            Some(r) => command.push_str(&r),
                            None => {
                                error.get_or_insert(format!(
                                    "{{{name}}} is inside $(( )), where only a number can be passed safely: write {{#{name}}}"
                                ));
                                command.push_str(&slot.label());
                            }
                        }
                        display.push_str(v);
                    }
                    // A default is the snippet author's own text: used as written.
                    (None, Some(d)) => {
                        command.push_str(d);
                        display.push_str(d);
                    }
                    (None, None) => {
                        command.push_str(&slot.label());
                        display.push_str(&slot.label());
                    }
                }
            }
        }
    }

    let remainder = remainder.trim();
    if !remainder.is_empty() {
        if strict {
            error.get_or_insert(format!(
                "snippet {} takes {} value{}; extra text was not run: {remainder}",
                s.name,
                slots.len(),
                if slots.len() == 1 { "" } else { "s" }
            ));
        } else {
            command.push(' ');
            command.push_str(remainder);
            display.push(' ');
            display.push_str(remainder);
        }
    }
    if !used_files && !file_env.is_empty() {
        command = format!("{} {file_refs}", command.trim_end());
        display = format!("{} {file_display}", display.trim_end());
    }

    let mut env: Vec<(String, String)> = values
        .iter()
        .enumerate()
        .map(|(i, v)| (format!("TERMIGHT_VALUE_{}", i + 1), v.clone()))
        .collect();
    env.extend(file_env);
    let mut missing: Vec<Missing> = slots
        .iter()
        .skip(values.len())
        .map(|s| Missing {
            name: s.name.to_string(),
            default: s.default.map(String::from),
            kind: s.kind.public(),
        })
        .collect();
    missing.extend(missing_secrets.into_iter().map(|name| Missing {
        name,
        default: None,
        kind: Kind::Secret,
    }));
    Expansion {
        command,
        env,
        display,
        is_snippet: true,
        missing,
        secrets,
        error,
    }
}

/// A word as people would type it: quoted only when it needs to be.
fn display_word(s: &str) -> String {
    let plain = !s.is_empty()
        && s.chars()
            .all(|c| c.is_alphanumeric() || "-_./:=@%+,~".contains(c));
    if plain {
        s.to_string()
    } else {
        format!("'{}'", s.replace('\'', "'\\''"))
    }
}

/// A placeholder's kind as the scanner finds it.
#[derive(Clone, Debug, PartialEq)]
enum PieceKind<'a> {
    Text,
    Number,
    Choice(Vec<&'a str>),
    Secret,
    Files,
}

impl PieceKind<'_> {
    /// Filled by the words typed after the snippet's name.
    fn is_typed(&self) -> bool {
        matches!(
            self,
            PieceKind::Text | PieceKind::Number | PieceKind::Choice(_)
        )
    }

    /// A number is checked; a choice is text the snippet's author wrote.
    fn safe_in_arithmetic(&self) -> bool {
        matches!(self, PieceKind::Number | PieceKind::Choice(_))
    }

    fn public(&self) -> Kind {
        match self {
            PieceKind::Number => Kind::Number,
            PieceKind::Choice(o) => Kind::Choice(o.iter().map(|s| s.to_string()).collect()),
            PieceKind::Secret => Kind::Secret,
            PieceKind::Text | PieceKind::Files => Kind::Text,
        }
    }
}

/// One distinct typed placeholder: the Nth typed value fills the Nth slot.
struct Slot<'a> {
    name: &'a str,
    default: Option<&'a str>,
    kind: PieceKind<'a>,
}

impl Slot<'_> {
    fn label(&self) -> String {
        label(self.name, &self.kind.public())
    }

    /// The value as the shell gets it, or why it is refused.
    fn check(&self, v: &str) -> Result<String, String> {
        match &self.kind {
            PieceKind::Number => {
                let digits = v.strip_prefix('-').unwrap_or(v);
                let n = (!digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()))
                    .then(|| v.parse::<i64>().ok())
                    .flatten();
                n.map(|n| n.to_string())
                    .ok_or_else(|| format!("{} takes a whole number, not {v:?}", self.label()))
            }
            PieceKind::Choice(options) => {
                if options.contains(&v) {
                    Ok(v.to_string())
                } else {
                    Err(format!(
                        "{{{}}} takes one of {}, not {v:?}",
                        self.name,
                        options.join(", ")
                    ))
                }
            }
            _ => {
                // Arithmetic runs a command only through a subscript holding an
                // expansion: `a[$(cmd)]`, ``a[`cmd`]``, `a[${x:=$(cmd)}]`.
                if let Some(i) = v.find('[')
                    && v[i..].contains(['$', '`'])
                {
                    return Err(format!(
                        "the value for {} has a `[` followed by `$` or a backtick, which shell arithmetic could run as a command, so it was not run",
                        self.label()
                    ));
                }
                Ok(v.to_string())
            }
        }
    }
}

/// Where in the shell grammar a placeholder sits.
#[derive(Clone, Copy, PartialEq, Debug)]
enum Context {
    /// Unquoted, including inside `$( … )` and backticks.
    Plain,
    Single,
    Double,
    /// `$'…'`
    AnsiC,
    /// `$(( … ))`
    Arithmetic,
    /// After `#` to the end of the line.
    Comment,
}

impl Context {
    /// How to refer to variable `var` here so its value is one literal word.
    /// None where no safe reference exists. `arithmetic_ok`: the value is safe
    /// to be read as an arithmetic expression (a checked number, or a choice).
    fn reference(self, var: &str, arithmetic_ok: bool) -> Option<String> {
        Some(match self {
            Context::Plain => format!("\"${{{var}}}\""),
            // Inside double quotes an expansion is not parsed again.
            Context::Double | Context::Comment => format!("${{{var}}}"),
            // Leave the quotes, refer to the variable, come back in.
            Context::Single => format!("'\"${{{var}}}\"'"),
            Context::AnsiC => format!("'\"${{{var}}}\"$'"),
            Context::Arithmetic if arithmetic_ok => format!("${{{var}}}"),
            Context::Arithmetic => return None,
        })
    }
}

enum Piece<'a> {
    Text(String),
    Slot {
        name: &'a str,
        default: Option<&'a str>,
        kind: PieceKind<'a>,
        context: Context,
    },
}

enum Frame {
    /// `closer`: what ends this frame (`)` for `$(`, a backtick), None at top level.
    Plain {
        closer: Option<char>,
        depth: u32,
    },
    Single,
    Double,
    AnsiC,
    Arithmetic {
        depth: u32,
    },
    Comment,
}

fn scan(t: &str) -> Vec<Piece<'_>> {
    let mut pieces = vec![];
    let mut text = String::new();
    let mut stack = vec![Frame::Plain {
        closer: None,
        depth: 0,
    }];
    let mut i = 0;

    while i < t.len() {
        let rest = &t[i..];
        let c = rest.chars().next().unwrap();
        let mut take = c.len_utf8();
        let context = match stack.last().unwrap() {
            Frame::Plain { .. } => Context::Plain,
            Frame::Single => Context::Single,
            Frame::Double => Context::Double,
            Frame::AnsiC => Context::AnsiC,
            Frame::Arithmetic { .. } => Context::Arithmetic,
            Frame::Comment => Context::Comment,
        };

        if c == '{' {
            match brace_at(t, i) {
                Brace::Slot {
                    name,
                    default,
                    kind,
                    len,
                } => {
                    if !text.is_empty() {
                        pieces.push(Piece::Text(std::mem::take(&mut text)));
                    }
                    pieces.push(Piece::Slot {
                        name,
                        default,
                        kind,
                        context,
                    });
                    i += len;
                    continue;
                }
                Brace::Escaped { literal, len } => {
                    text.push_str(literal);
                    i += len;
                    continue;
                }
                Brace::Other => {}
            }
        }

        let escapes = matches!(context, Context::Plain | Context::Double | Context::AnsiC);
        if c == '\\' && escapes {
            // A backslash takes the next character with it, so `\{name}` is literal.
            if let Some(next) = rest[1..].chars().next() {
                take += next.len_utf8();
            }
        } else {
            let top = stack.last_mut().unwrap();
            match top {
                Frame::Plain { closer, depth } => {
                    if rest.starts_with("$((") {
                        take = 3;
                        stack.push(Frame::Arithmetic { depth: 2 });
                    } else if rest.starts_with("((") && at_word_start(t, i) {
                        // The `(( … ))` command is arithmetic too.
                        take = 2;
                        stack.push(Frame::Arithmetic { depth: 2 });
                    } else if rest.starts_with("$(") {
                        take = 2;
                        stack.push(Frame::Plain {
                            closer: Some(')'),
                            depth: 0,
                        });
                    } else if rest.starts_with("$'") {
                        take = 2;
                        stack.push(Frame::AnsiC);
                    } else if c == '\'' {
                        stack.push(Frame::Single);
                    } else if c == '"' {
                        stack.push(Frame::Double);
                    } else if c == '`' {
                        if *closer == Some('`') {
                            stack.pop();
                        } else {
                            stack.push(Frame::Plain {
                                closer: Some('`'),
                                depth: 0,
                            });
                        }
                    } else if c == '(' && *closer == Some(')') {
                        *depth += 1;
                    } else if c == ')' && *closer == Some(')') {
                        if *depth == 0 {
                            stack.pop();
                        } else {
                            *depth -= 1;
                        }
                    } else if c == '#' && at_word_start(t, i) {
                        stack.push(Frame::Comment);
                    }
                }
                Frame::Double => {
                    if rest.starts_with("$((") {
                        take = 3;
                        stack.push(Frame::Arithmetic { depth: 2 });
                    } else if rest.starts_with("$(") {
                        take = 2;
                        stack.push(Frame::Plain {
                            closer: Some(')'),
                            depth: 0,
                        });
                    } else if c == '`' {
                        stack.push(Frame::Plain {
                            closer: Some('`'),
                            depth: 0,
                        });
                    } else if c == '"' {
                        stack.pop();
                    }
                }
                Frame::Single | Frame::AnsiC => {
                    if c == '\'' {
                        stack.pop();
                    }
                }
                Frame::Arithmetic { depth } => {
                    if c == '(' {
                        *depth += 1;
                    } else if c == ')' {
                        *depth -= 1;
                        if *depth == 0 {
                            stack.pop();
                        }
                    }
                }
                Frame::Comment => {
                    if c == '\n' {
                        stack.pop();
                    }
                }
            }
        }
        text.push_str(&t[i..i + take]);
        i += take;
    }
    if !text.is_empty() {
        pieces.push(Piece::Text(text));
    }
    pieces
}

fn at_word_start(t: &str, i: usize) -> bool {
    t[..i]
        .chars()
        .next_back()
        .is_none_or(|p| p.is_whitespace() || matches!(p, ';' | '|' | '&' | '('))
}

enum Brace<'a> {
    Slot {
        name: &'a str,
        default: Option<&'a str>,
        kind: PieceKind<'a>,
        len: usize,
    },
    /// `{{name}}`: a literal `{name}`.
    Escaped {
        literal: &'a str,
        len: usize,
    },
    Other,
}

/// What the `{` at byte `open` of `t` starts.
fn brace_at(t: &str, open: usize) -> Brace<'_> {
    let rest = &t[open..];
    if let Some(inner) = rest.strip_prefix("{{")
        && let Some(end) = inner.find("}}")
        && split_placeholder(&inner[..end]).is_some()
    {
        // `{{name}}` → the text `{name}`: the inner braces of the original.
        return Brace::Escaped {
            literal: &rest[1..end + 3],
            len: end + 4,
        };
    }
    let sigil = open > 0 && matches!(t.as_bytes()[open - 1], b'$' | b'@' | b'%');
    if sigil {
        return Brace::Other;
    }
    let Some(close) = rest.find('}') else {
        return Brace::Other;
    };
    match split_placeholder(&rest[1..close]) {
        Some((name, default, kind)) => Brace::Slot {
            name,
            default,
            kind,
            len: close + 1,
        },
        None => Brace::Other,
    }
}

fn is_ident(name: &str) -> bool {
    name.chars()
        .next()
        .is_some_and(|c| c.is_alphabetic() || c == '_')
        && name.chars().all(|c| c.is_alphanumeric() || c == '_')
}

/// The inside of a placeholder's braces: `name`, `name:default`, `#name`,
/// `name|a|b`, `!name` or `files`. None for anything else, which stays
/// literal text.
fn split_placeholder(inner: &str) -> Option<(&str, Option<&str>, PieceKind<'_>)> {
    let (sigil, body) = match inner.as_bytes().first() {
        Some(b'#') => (Some('#'), &inner[1..]),
        Some(b'!') => (Some('!'), &inner[1..]),
        _ => (None, inner),
    };
    let (head, default) = match body.split_once(':') {
        Some((h, d)) => (h, Some(d)),
        None => (body, None),
    };
    let mut parts = head.split('|');
    let name = parts.next()?;
    let options: Vec<&str> = parts.collect();
    if !is_ident(name) {
        return None;
    }
    let kind = match (sigil, options.is_empty()) {
        (None, true) if name == "files" && default.is_none() => PieceKind::Files,
        (None, true) => PieceKind::Text,
        // Choices are single words, so code like `{print $1|"sort"}` is not one.
        (None, false) => {
            if options
                .iter()
                .any(|o| o.is_empty() || o.contains(char::is_whitespace))
            {
                return None;
            }
            PieceKind::Choice(options)
        }
        (Some('#'), true) => PieceKind::Number,
        // A secret's name becomes part of an environment variable's name.
        (Some('!'), true)
            if default.is_none()
                && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_') =>
        {
            PieceKind::Secret
        }
        _ => return None,
    };
    Some((name, default, kind))
}

/// The first `max` shell words of `s` (whitespace separates; '…' and "…" group;
/// \ escapes) and the untouched text after them.
pub fn take_words(s: &str, max: usize) -> (Vec<String>, &str) {
    let mut words = vec![];
    let mut cur = String::new();
    let mut in_word = false;
    let mut quote: Option<char> = None;
    let mut chars = s.char_indices();
    while let Some((i, c)) = chars.next() {
        if words.len() == max && !in_word {
            return (words, &s[i..]);
        }
        match (quote, c) {
            (Some(q), c) if c == q => quote = None,
            (Some('"'), '\\') => cur.extend(chars.next().map(|(_, c)| c)),
            (Some(_), c) => cur.push(c),
            (None, '\'' | '"') => {
                quote = Some(c);
                in_word = true;
            }
            (None, '\\') => {
                cur.extend(chars.next().map(|(_, c)| c));
                in_word = true;
            }
            (None, c) if c.is_whitespace() => {
                if in_word {
                    words.push(std::mem::take(&mut cur));
                    in_word = false;
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
    (words, "")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    fn sn(name: &str, command: &str) -> Snippet {
        Snippet {
            name: name.into(),
            command: command.into(),
        }
    }

    fn expand(line: &str, s: &[Snippet]) -> Expansion {
        expand_with(line, s, false)
    }

    /// The command as people see it.
    fn shown(line: &str, s: &[Snippet]) -> String {
        expand(line, s).display
    }

    /// Run an expansion in a real shell, as the core does. Returns its output.
    fn run_in_shell(shell: &str, e: &Expansion, dir: &Path) -> String {
        assert!(e.error.is_none(), "refused: {:?}", e.error);
        let out = Command::new(shell)
            .args(["-c", "eval \"$1\" 2>&1", "termight", &e.command])
            .envs(e.env.iter().cloned())
            .current_dir(dir)
            .output()
            .expect("shell runs");
        String::from_utf8_lossy(&out.stdout).into_owned()
    }

    fn shells() -> Vec<&'static str> {
        ["/bin/zsh", "/bin/bash", "/bin/sh"]
            .into_iter()
            .filter(|s| Path::new(s).exists())
            .collect()
    }

    fn temp_dir(tag: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("termight-test-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn snippet_expansion() {
        let s = vec![
            sn("hi", "echo hello"),
            sn("gc", "git commit -m"),
            sn("deploy", "kubectl apply -f {env}.yaml --context {ctx:prod}"),
            sn("say", "echo \"{msg}\" and ${HOME} {1..2}"),
            sn("twice", "echo {a} {a} {b}"),
            sn("curl", "curl {url:http://x} -H {token}"),
            sn("gd", "git diff @{upstream} {path}"),
        ];
        assert_eq!(shown("hi", &s), "echo hello");
        assert_eq!(shown("other thing", &s), "other thing");
        assert!(!expand("other", &s).is_snippet);

        // Words past the last slot are appended exactly as typed (quotes kept).
        assert_eq!(expand("hi there", &s).command, "echo hello there");
        assert_eq!(
            expand("gc \"fix the bug\"", &s).command,
            "git commit -m \"fix the bug\""
        );
        assert_eq!(
            shown("deploy staging dev -v 'x y'", &s),
            "kubectl apply -f staging.yaml --context dev -v 'x y'"
        );

        // Values travel as environment variables; the command only refers to them.
        let e = expand("deploy staging", &s);
        assert_eq!(
            e.command,
            "kubectl apply -f \"${TERMIGHT_VALUE_1}\".yaml --context prod"
        );
        assert_eq!(
            e.env,
            vec![("TERMIGHT_VALUE_1".to_string(), "staging".to_string())]
        );
        assert_eq!(e.display, "kubectl apply -f staging.yaml --context prod");

        // Defaults and missing values.
        let e = expand("deploy", &s);
        assert_eq!(e.display, "kubectl apply -f {env}.yaml --context prod");
        assert_eq!(e.required(), vec!["env"]);
        assert_eq!(e.missing.len(), 2);
        assert!(expand("deploy x", &s).required().is_empty());

        // Slots are distinct names in order: a repeated name is one slot.
        assert_eq!(shown("twice 1 2", &s), "echo 1 1 2");
        assert_eq!(expand("twice 1 2", &s).env.len(), 2);
        // A defaulted slot before a required one still takes the first value.
        assert_eq!(shown("curl http://y abc", &s), "curl http://y -H abc");
        let e = expand("curl", &s);
        assert_eq!(e.required(), vec!["token"]);
        assert_eq!(
            e.missing[0],
            Missing {
                name: "url".into(),
                default: Some("http://x".into()),
                kind: Kind::Text
            }
        );

        // Not placeholders: ${VAR}, {1..2}, {}, @{upstream}.
        assert_eq!(shown("say hey", &s), "echo \"hey\" and ${HOME} {1..2}");
        assert_eq!(shown("gd src", &s), "git diff @{upstream} src");
        assert_eq!(expand("gd", &s).required(), vec!["path"]);
    }

    #[test]
    fn braces_that_are_not_placeholders() {
        let s = vec![
            sn("code", "curl -s -o /dev/null -w '%{http_code}' {url}"),
            sn("awk", "awk '{{print}}' {file}"),
            sn("lit", "echo \\{x} {{y}} {{z:1}} {}"),
        ];
        // %{…} is curl's own syntax.
        let e = expand("code", &s);
        assert_eq!(e.required(), vec!["url"]);
        assert_eq!(
            shown("code http://a", &s),
            "curl -s -o /dev/null -w '%{http_code}' http://a"
        );
        // {{name}} is a literal {name}.
        assert_eq!(expand("awk", &s).required(), vec!["file"]);
        assert_eq!(shown("awk /etc/shells", &s), "awk '{print}' /etc/shells");
        // \{name} is left alone too.
        let e = expand("lit", &s);
        assert!(e.missing.is_empty());
        assert_eq!(e.command, "echo \\{x} {y} {z:1} {}");
    }

    /// Finding 1: whatever the value and wherever the placeholder sits, the
    /// shell must see the value as text, never as code.
    #[test]
    fn values_are_never_parsed_by_the_shell() {
        let dir = temp_dir("inject");
        let marker = dir.join("PWNED");
        let attack = |v: &str| v.replace("MARK", &marker.display().to_string());
        // (template, typed value)
        let cases = [
            ("echo {x}", "a;touch MARK"),
            ("echo {x}", "$(touch MARK)"),
            ("echo {x}", "`touch MARK`"),
            ("echo \"hello {x}\"", "\"; touch MARK; echo \""),
            ("echo \"hello {x}\"", "$(touch MARK)"),
            ("echo 'it is {x}'", "'; touch MARK; echo '"),
            ("echo \"$(basename {x})\"", "a;touch MARK"),
            ("echo $(basename {x})", "a;touch MARK"),
            ("echo `basename {x}`", "a`touch MARK`"),
            ("echo $'it\\'s {x}'", ";touch MARK;#"),
            ("echo hi # don't forget {x}", "\ntouch MARK"),
            ("echo {x} | cat", "a | touch MARK"),
            ("echo {x}", "a\ntouch MARK"),
            ("echo {x}", "-n $(touch MARK)"),
        ];
        for shell in shells() {
            for (template, value) in cases {
                let s = vec![sn("t", template)];
                // The launcher passes each value as one quoted shell word.
                let typed = format!("t '{}'", attack(value).replace('\'', "'\\''"));
                let e = expand(&typed, &s);
                assert_eq!(e.env[0].1, attack(value), "value arrives unchanged");
                run_in_shell(shell, &e, &dir);
                assert!(
                    !marker.exists(),
                    "{shell}: value ran as code. template: {template}  value: {value:?}"
                );
            }
        }
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn values_arrive_as_one_literal_word() {
        let dir = temp_dir("literal");
        let value = "two  words 'q' \"dq\" $HOME * \\n";
        let typed = format!("t '{}'", value.replace('\'', "'\\''"));
        for shell in shells() {
            for template in [
                "printf '%s\\n' {x}",
                "printf '%s\\n' \"{x}\"",
                "printf '%s\\n' '{x}'",
                "printf '%s\\n' \"$(printf '%s' {x})\"",
            ] {
                let e = expand(&typed, &[sn("t", template)]);
                assert_eq!(
                    run_in_shell(shell, &e, &dir),
                    format!("{value}\n"),
                    "{shell}: {template}"
                );
            }
        }
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn arithmetic_placeholders_are_refused() {
        let s = vec![sn("n", "echo $(( {n} + 1 ))")];
        let e = expand("n 5", &s);
        assert!(e.error.as_deref().unwrap().contains("write {#n}"));
        let s2 = vec![sn("c", "(( {n} > 3 )) && echo big")];
        assert!(expand("c 5", &s2).error.is_some());
        // Without a value there is nothing to refuse yet: it asks for one.
        assert_eq!(expand("n", &s).required(), vec!["n"]);
    }

    #[test]
    fn number_placeholders() {
        let dir = temp_dir("number");
        let s = vec![
            sn("inc", "echo $(( {#n} + 1 ))"),
            sn("big", "(( {#n} > 3 )) && echo big || echo small"),
            sn("both", "echo {#n} \"$(( {n} * 2 ))\""),
            sn("dflt", "echo $(( {#n:10} + 1 ))"),
        ];
        for shell in shells() {
            let run = |line: &str| run_in_shell(shell, &expand(line, &s), &dir);
            assert_eq!(run("inc 41"), "42\n", "{shell}");
            assert_eq!(run("inc -3"), "-2\n", "{shell}");
            // Canonical form: 010 is ten, not octal eight.
            assert_eq!(run("inc 010"), "11\n", "{shell}");
            assert_eq!(run("both 4"), "4 8\n", "{shell}");
            assert_eq!(run("dflt"), "11\n", "{shell}");
            if shell != "/bin/sh" {
                assert_eq!(run("big 7"), "big\n", "{shell}");
            }
        }
        for bad in [
            "x",
            "1.5",
            "+3",
            "1e3",
            "",
            "- 1",
            "99999999999999999999",
            "a[$(touch X)]",
            "١",
        ] {
            let typed = format!("inc '{bad}'");
            let e = expand(&typed, &s);
            assert!(
                e.error
                    .as_deref()
                    .is_some_and(|m| m.contains("whole number")),
                "{bad:?}: {:?}",
                e.error
            );
        }
        assert_eq!(expand("dflt", &s).missing[0].name, "n");
        assert_eq!(expand("inc", &s).required_labels(), vec!["{#n}"]);
        // {#n} anywhere makes the slot a number, also where it is written {n}.
        assert_eq!(expand("both", &s).required_labels(), vec!["{#n}"]);
        assert_eq!(expand("inc", &s).display, "echo $(( {#n} + 1 ))");
        // {{#n}} is a literal {#n}.
        assert_eq!(expand("x", &[sn("x", "echo {{#n}}")]).command, "echo {#n}");
        // ${#arr} is shell syntax, not a placeholder.
        assert!(expand("x", &[sn("x", "echo ${#PATH}")]).missing.is_empty());
        let _ = fs::remove_dir_all(&dir);
    }

    /// A value shaped like `a[$(cmd)]` is refused everywhere, because
    /// arithmetic the scanner does not see would run it.
    #[test]
    fn values_that_arithmetic_could_run_are_refused() {
        let dir = temp_dir("arith");
        let marker = dir.join("PWNED");
        let m = marker.display().to_string();
        let templates = [
            "let \"x = {v}\"",
            "[[ {v} -eq 0 ]]",
            "a=(1 2); echo \"${a[{v}]}\"",
            "s=hello; echo \"${s:{v}}\"",
            "typeset -i n; n={v}",
            "echo {v}",
        ];
        let values = [
            format!("a[$(touch {m})]"),
            format!("a[`touch {m}`]"),
            format!("x[${{y:=$(touch {m})}}]"),
            format!("[ $(touch {m}) ]"),
        ];
        for t in templates {
            for v in &values {
                let typed = format!("t '{}'", v.replace('\'', "'\\''"));
                let e = expand(&typed, &[sn("t", t)]);
                assert!(e.error.is_some(), "{t} with {v} not refused");
            }
        }
        // Values without that shape still pass, in any position.
        for ok in ["[x]", "a[1]", "$HOME", "`date`", "x=5", "a]$["] {
            let typed = format!("t '{ok}'");
            assert!(
                expand(&typed, &[sn("t", "echo {v}")]).error.is_none(),
                "{ok}"
            );
        }
        assert!(!marker.exists());
        let _ = fs::remove_dir_all(&dir);
    }

    /// Finding 2: text a shortcut passes beyond the placeholders must not run.
    #[test]
    fn strict_refuses_surplus_words() {
        let s = vec![sn("plain", "echo hello"), sn("one", "echo {a}")];
        let e = expand_with("plain ; touch X", &s, true);
        assert!(e.error.is_some());
        assert_eq!(e.command, "echo hello");
        let e = expand_with("one v ; touch X", &s, true);
        assert!(e.error.is_some());
        assert!(expand_with("one v", &s, true).error.is_none());
        assert!(expand_with("plain", &s, true).error.is_none());
        // The launcher, where the user typed the words, still appends them.
        assert_eq!(
            expand_with("plain ; touch X", &s, false).command,
            "echo hello ; touch X"
        );
    }

    #[test]
    fn script_carries_its_values() {
        let s = vec![sn("t", "echo {x}")];
        let e = expand("t \"it's\"", &s);
        assert_eq!(
            e.script().unwrap(),
            "export TERMIGHT_VALUE_1='it'\\''s'\necho \"${TERMIGHT_VALUE_1}\""
        );
    }

    #[test]
    fn word_splitting() {
        let all = |s| take_words(s, usize::MAX).0;
        assert_eq!(
            all(r#"a 'b c' "d \"e\"" f\ g"#),
            vec!["a", "b c", "d \"e\"", "f g"]
        );
        assert_eq!(all("  "), Vec::<String>::new());
        assert_eq!(all("''"), vec![""]);
        assert_eq!(
            take_words("a 'b c'  d \"e f\"", 2),
            (vec!["a".to_string(), "b c".to_string()], " d \"e f\"")
        );
        assert_eq!(take_words("a b", 0), (vec![], "a b"));
        assert_eq!(take_words("a", 3), (vec!["a".to_string()], ""));
    }

    #[test]
    fn choice_placeholders() {
        let dir = temp_dir("choice");
        let s = vec![
            sn("dep", "echo deploying to {env|dev|staging|prod}"),
            sn("op", "echo $(( 6 {o|+|-|*} 2 ))"),
            sn("dflt", "echo {env|dev|prod:prod}"),
            sn("awk", "awk '{print $1|\"sort\"}' {f}"),
        ];
        for shell in shells() {
            let run = |line: &str| run_in_shell(shell, &expand(line, &s), &dir);
            assert_eq!(run("dep staging"), "deploying to staging\n", "{shell}");
            assert_eq!(run("op '*'"), "12\n", "{shell}");
            assert_eq!(run("dflt"), "prod\n", "{shell}");
        }
        let e = expand("dep qa", &s);
        assert!(
            e.error
                .as_deref()
                .unwrap()
                .contains("one of dev, staging, prod")
        );
        let e = expand("dep", &s);
        assert_eq!(e.required_labels(), vec!["{env|dev|staging|prod}"]);
        assert_eq!(e.missing[0].field(), "env\t\tchoice\tdev\tstaging\tprod");
        assert_eq!(expand("dflt", &s).missing.len(), 1);
        assert_eq!(
            expand("dflt", &s).missing[0].field(),
            "env\t=prod\tchoice\tdev\tprod"
        );
        // awk code with a | and spaces is not a choice.
        assert_eq!(expand("awk", &s).required(), vec!["f"]);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn secret_placeholders() {
        let dir = temp_dir("secret");
        let s = vec![sn("api", "printf '%s|%s\\n' {!token} {path}")];
        // Without the secret: asked for, never typed.
        let e = expand("api /v1", &s);
        assert_eq!(e.required_labels(), vec!["{!token}"]);
        assert_eq!(e.missing[0].field(), "token\t\tsecret");
        assert_eq!(e.display, "printf '%s|%s\\n' •••• /v1");
        // With it: referenced, never in the command text or the env list.
        let inputs = Inputs {
            files: vec![],
            secrets: vec!["token".into()],
        };
        let e = expand_inputs("api /v1", &s, false, &inputs);
        assert!(e.missing.is_empty() && e.error.is_none());
        assert_eq!(e.secrets, vec!["token"]);
        assert!(e.command.contains("${TERMIGHT_SECRET_token}"));
        assert!(e.env.iter().all(|(k, _)| !k.starts_with(SECRET_PREFIX)));
        assert!(e.script().is_err(), "never written to a Terminal script");
        for shell in shells() {
            let out = Command::new(shell)
                .args(["-c", "eval \"$1\"", "termight", &e.command])
                .envs(e.env.iter().cloned())
                .env("TERMIGHT_SECRET_token", "s3cr3t'; touch X")
                .current_dir(&dir)
                .output()
                .unwrap();
            assert_eq!(
                String::from_utf8_lossy(&out.stdout),
                "s3cr3t'; touch X|/v1\n",
                "{shell}"
            );
        }
        // Not a secret: a default, or a name that can't be a variable name.
        assert!(expand("x", &[sn("x", "echo {!a:b}")]).missing.is_empty());
        assert!(expand("x", &[sn("x", "echo {!naïve}")]).missing.is_empty());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn files_placeholder() {
        let dir = temp_dir("files");
        let a = dir.join("a b.txt");
        let b = dir.join("it's;$(touch X).txt");
        fs::write(&a, "1").unwrap();
        fs::write(&b, "2").unwrap();
        let inputs = Inputs {
            files: vec![a.display().to_string(), b.display().to_string()],
            secrets: vec![],
        };
        let s = vec![
            sn("count", "for f in {files}; do echo \"[$f]\"; done"),
            sn("hi", "echo hi"),
            sn("quoted", "echo \"{files}\""),
        ];
        for shell in shells() {
            let e = expand_inputs("count", &s, false, &inputs);
            let out = run_in_shell(shell, &e, &dir);
            assert_eq!(
                out,
                format!("[{}]\n[{}]\n", a.display(), b.display()),
                "{shell}"
            );
            // No {files}: added at the end, one word each.
            let e = expand_inputs("ls -1", &s, false, &inputs);
            assert_eq!(
                run_in_shell(shell, &e, &dir),
                format!("{}\n{}\n", a.display(), b.display())
            );
            let e = expand_inputs("hi", &s, false, &inputs);
            assert!(
                e.command.ends_with("\"${TERMIGHT_FILE_2}\""),
                "{}",
                e.command
            );
        }
        assert!(!dir.join("X").exists());
        assert!(expand_inputs("quoted", &s, false, &inputs).error.is_some());
        assert!(
            expand("count", &s)
                .error
                .as_deref()
                .unwrap()
                .contains("Finder")
        );
        let e = expand_inputs("count", &s, false, &inputs);
        assert!(e.script().unwrap().contains("export TERMIGHT_FILE_1="));
        let _ = fs::remove_dir_all(&dir);
    }
}
