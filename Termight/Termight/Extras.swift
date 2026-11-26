// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 David Nordqvist
//
// This file is part of Termight. Termight is free software: you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License, version 3, as published by the Free Software Foundation. It comes
// with no warranty. See the LICENSE file for the full text.

import AppKit
import CoreSpotlight
import UserNotifications

// MARK: - Snippets

struct Snippet: Identifiable, Hashable {
    var id = UUID()
    var name: String
    var command: String

    var isValid: Bool {
        !name.isEmpty && !name.contains(where: \.isWhitespace) && !command.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Snippets live in a TSV file the Rust core reads too:
/// ~/Library/Application Support/Termight/snippets.tsv, one `name<TAB>command` per line.
enum SnippetStore {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Termight/snippets.tsv")
    }

    static func load() -> [Snippet] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            return parts.count == 2 ? Snippet(name: parts[0], command: parts[1]) : nil
        }
    }

    /// Writes valid snippets, then refreshes Spotlight and the Shortcuts/Spotlight
    /// action list. Throws when the file cannot be written, so Settings can say so.
    /// The file is readable by this user only: a command may hold a token.
    static func save(_ snippets: [Snippet]) throws {
        let valid = snippets.filter(\.isValid)
        let text = valid.map { "\($0.name)\t\($0.command.replacingOccurrences(of: "\n", with: " "))" }
            .joined(separator: "\n")
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try (text.isEmpty ? "" : text + "\n").write(to: url, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        SnippetIndex.reindex(valid)
        TermightShortcuts.updateAppShortcutParameters()
    }
}

/// Puts snippets in Spotlight's index: typing a snippet's name in ⌘Space shows it,
/// and choosing it opens the launcher with the snippet ready to run.
enum SnippetIndex {
    static let domain = "snippets"
    static let prefix = "snippet:"

    static func reindex(_ snippets: [Snippet]) {
        let items = snippets.map { s in
            let attrs = CSSearchableItemAttributeSet(contentType: .text)
            attrs.title = s.name
            // The name only: a snippet's command may hold a token, and the index is shared system-wide.
            attrs.contentDescription = "Termight snippet"
            attrs.keywords = [s.name, "termight", "snippet"]
            return CSSearchableItem(uniqueIdentifier: prefix + s.name, domainIdentifier: domain, attributeSet: attrs)
        }
        let index = CSSearchableIndex.default()
        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { _ in
            index.indexSearchableItems(items)
        }
    }
}

// MARK: - Terminal handoff

/// Opens a command in Terminal.app via a self-deleting .command file, so commands
/// that need a real terminal (vim, ssh, sudo prompts) work. Needs no Automation
/// permission. The window stays open in your shell afterwards.
enum TerminalHandoff {
    /// `command` is what runs (snippets already expanded by the core);
    /// `typed` is what the user entered, recorded in history.
    @MainActor static func open(_ command: String, typed: String, cwd: String) {
        let env = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shell = env.hasSuffix("/zsh") || env.hasSuffix("/bash") ? env : "/bin/zsh"
        // On its own line: a command ending in `\` or holding a `#` must not swallow the exec.
        let inner = "\(command)\nexec \(q(shell)) -l"
        let script = """
            #!/bin/sh
            rm -f "$0"
            cd \(q(cwd)) 2>/dev/null || cd ~
            clear
            exec \(q(shell)) -lic \(q(inner))

            """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("termight-\(UUID().uuidString.prefix(8)).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            NSLog("Termight: could not write Terminal script: \(error)")
            return
        }
        let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        if let terminal {
            NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
        History.append(typed, status: "→ Terminal")
    }

    /// Single-quote for sh.
    private static func q(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Notifications

enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Banners allowed? (Permission granted and alerts not switched off in System Settings.)
    static func isAllowed() async -> Bool {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        return s.authorizationStatus == .authorized && s.alertSetting == .enabled
    }

    static func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// "Done" notification for a command that finished while the launcher was hidden.
    static func commandFinished(_ command: String, status: String) {
        guard Prefs.d.bool(forKey: Prefs.notifyOnFinish) else { return }
        let content = UNMutableNotificationContent()
        content.title = status.hasPrefix("✓") ? "Command finished" : "Command failed"
        // A line typed with a leading space is kept out of history; keep it off the screen too.
        content.subtitle = command.hasPrefix(" ") ? "" : command
        content.body = status
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
