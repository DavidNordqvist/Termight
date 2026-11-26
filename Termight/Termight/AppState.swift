// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 David Nordqvist
//
// This file is part of Termight. Termight is free software: you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License, version 3, as published by the Free Software Foundation. It comes
// with no warranty. See the LICENSE file for the full text.

import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// UserDefaults keys and defaults, shared by @AppStorage views and plain code.
enum Prefs {
    static let hotKey = "hotKey"
    static let showMenuBarIcon = "showMenuBarIcon"
    static let showInDock = "showInDock"
    static let timeout = "timeout"
    static let maxLines = "maxLines"
    static let requireValid = "requireValid"
    static let openInteractiveInTerminal = "openInteractiveInTerminal"
    static let loadShellRC = "loadShellRC"
    static let notifyOnFinish = "notifyOnFinish"
    static let allowShortcuts = "allowShortcuts"
    static let lastCwd = "lastCwd"
    static let pinned = "launcherPinned"
    static let winX = "launcherX"
    static let winTop = "launcherTop"
    static let winW = "launcherWidth"
    static let winH = "launcherHeight"
    /// The bar's size before it was tiled; set only while it's tiled.
    static let untiledW = "launcherUntiledWidth"
    static let untiledH = "launcherUntiledHeight"
    static let checkForUpdates = "checkForUpdates"
    static let lastUpdateCheck = "lastUpdateCheck"
    static let notifiedUpdate = "notifiedUpdate"
    static let pendingUpdate = "pendingUpdate"
    static let updateFeedURL = "updateFeedURL"  // testing only, not in Settings
    static let colorOutput = "colorOutput"
    static let watchInterval = "watchInterval"
    static let statusCommands = "statusCommands"
    static let windowStyle = "windowStyle"  // "system" or "custom"
    static let windowColor = "windowColor"  // "r g b", 0–1 sRGB
    static let windowOpacity = "windowOpacity"
    static let windowBlur = "windowBlur"
    static let windowTheme = "windowTheme"  // a WindowTheme id, or "custom"
    static let windowText = "windowText"  // "auto" or "custom"
    static let windowTextColor = "windowTextColor"  // "r g b", 0–1 sRGB

    static func register() {
        UserDefaults.standard.register(defaults: [
            hotKey: HotKeyPreset.optionSpace.rawValue,
            showMenuBarIcon: true,
            showInDock: false,
            timeout: 300,  // launcher streams output and can be cancelled, so allow long runs
            maxLines: 500,
            requireValid: true,
            openInteractiveInTerminal: true,
            loadShellRC: false,
            notifyOnFinish: true,
            // Off until the user says so: a shortcut can run without anyone looking.
            allowShortcuts: false,
            checkForUpdates: true,
            colorOutput: true,
            watchInterval: 2,
            windowStyle: "system",
            windowColor: WindowLook.defaultColor,
            windowOpacity: 1.0,
            windowBlur: true,
            windowTheme: "system",
            windowText: "auto",
            windowTextColor: WindowLook.defaultTextColor,
        ])
    }

    static var d: UserDefaults { .standard }
}

enum HotKeyPreset: String, CaseIterable, Identifiable {
    case optionSpace, controlSpace, controlOptionSpace, commandShiftSpace, off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .optionSpace: "⌥ Space"
        case .controlSpace: "⌃ Space"
        case .controlOptionSpace: "⌃⌥ Space"
        case .commandShiftSpace: "⇧⌘ Space"
        case .off: "None"
        }
    }

    /// Carbon modifier mask, or nil when the hotkey is off.
    var carbonModifiers: UInt32? {
        switch self {
        case .optionSpace: UInt32(optionKey)
        case .controlSpace: UInt32(controlKey)
        case .controlOptionSpace: UInt32(controlKey | optionKey)
        case .commandShiftSpace: UInt32(cmdKey | shiftKey)
        case .off: nil
        }
    }

    static var current: HotKeyPreset {
        HotKeyPreset(rawValue: Prefs.d.string(forKey: Prefs.hotKey) ?? "") ?? .optionSpace
    }
}

/// Single owner of the long-lived pieces so the menu bar, Dock, settings and
/// launcher can all reach each other.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let jobs = JobStore()
    let launcher = Launcher()
    private var settingsWindow: NSWindow?

    @Published private(set) var hotKeyRegistered = true
    /// Bumped after each launcher run so the menu bar's "Run Again" list refreshes.
    @Published var historyVersion = 0

    private init() {
        applyHotKey()
        applyDockPolicy()
    }

    func applyHotKey() {
        hotKeyRegistered = launcher.setHotKey(HotKeyPreset.current)
    }

    func applyDockPolicy() {
        let showDock = Prefs.d.bool(forKey: Prefs.showInDock)
        NSApp.setActivationPolicy(showDock ? .regular : .accessory)
        // Switching to .accessory hides our windows' app; bring Settings back if it was open.
        if settingsWindow?.isVisible == true { NSApp.activate() }
    }

    func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Termight Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func clearHistory() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/termight")
        for f in ["history.log", "last.log"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
        jobs.clearFinished()
    }

    func revealLogs() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/termight")
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    /// Recent distinct commands, newest first, from the Rust core's history log.
    func recentCommands(limit: Int) -> [String] {
        Array(History.load().reversed().prefix(limit))
    }
}

/// Launch-at-login via SMAppService (shows under System Settings → Login Items).
enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }
    static var isEnabled: Bool { status == .enabled }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// Command history kept by the Rust core: `ts \t status \t command`, oldest
/// first. In the command field `\`, newline and tab are written `\\`, `\n`, `\t`
/// so a multi-line command stays one row.
@MainActor
enum History {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/termight/history.log")
    }

    /// The parsed file, kept until the file changes: the bar and the menu ask often.
    private static var cache: (modified: Date, commands: [String])?

    /// For commands that don't go through the core (handed off to Terminal).
    /// A line typed with a leading space is not recorded, as in the shell.
    static func append(_ command: String, status: String) {
        guard !command.hasPrefix(" ") else { return }
        let line = "\(Int(Date().timeIntervalSince1970))\t\(status)\t\(escape(command))\n"
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let h = try FileHandle(forWritingTo: url)
            try h.seekToEnd()
            try h.write(contentsOf: Data(line.utf8))
            try h.close()
        } catch {
            NSLog("Termight: could not write history: \(error)")
        }
    }

    /// Distinct commands, oldest first, newest `max`.
    static func load(max: Int = 200) -> [String] {
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        guard let modified else {
            cache = nil
            return []
        }
        if let cache, cache.modified == modified, cache.commands.count <= max {
            return cache.commands
        }
        guard let log = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var seen = Set<String>()
        var cmds: [String] = []
        for line in log.split(separator: "\n").reversed() {
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3 else { continue }
            let cmd = unescape(String(parts[2]))
            if seen.insert(cmd).inserted { cmds.append(cmd) }
            if cmds.count == max { break }
        }
        let commands = Array(cmds.reversed())
        cache = (modified, commands)
        return commands
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": break
            default: out.append(c)
            }
        }
        return out
    }

    static func unescape(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = ""
        var escaped = false
        for c in s {
            if escaped {
                switch c {
                case "n": out.append("\n")
                case "t": out.append("\t")
                default: out.append(c)  // `\\` and anything written before escaping existed
                }
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else {
                out.append(c)
            }
        }
        if escaped { out.append("\\") }
        return out
    }
}
