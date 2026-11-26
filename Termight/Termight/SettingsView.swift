// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 David Nordqvist
//
// This file is part of Termight. Termight is free software: you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License, version 3, as published by the Free Software Foundation. It comes
// with no warranty. See the LICENSE file for the full text.

import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            CommandSettings().tabItem { Label("Commands", systemImage: "terminal") }
            SnippetSettings().tabItem { Label("Snippets", systemImage: "text.badge.plus") }
            MenuBarSettings().tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
        }
        .frame(width: 600, height: 560)
    }
}

private struct GeneralSettings: View {
    @ObservedObject private var state = AppState.shared

    @AppStorage(Prefs.hotKey) private var hotKey = HotKeyPreset.optionSpace.rawValue
    @AppStorage(Prefs.showMenuBarIcon) private var showMenuBarIcon = true
    @AppStorage(Prefs.showInDock) private var showInDock = false
    @AppStorage(Prefs.notifyOnFinish) private var notifyOnFinish = true

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginStatus = LoginItem.status
    @State private var loginError: String?
    @State private var notificationsAllowed = true

    private func refreshNotificationStatus() {
        Task { notificationsAllowed = await Notifier.isAllowed() }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("Approve Termight in Login Items to finish.").font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }.controlSize(.small)
                    }
                }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Show in menu bar", isOn: $showMenuBarIcon)
                Toggle("Show in Dock", isOn: $showInDock)
                    .onChange(of: showInDock) { state.applyDockPolicy() }
                if !showMenuBarIcon && !showInDock {
                    Text("Open Termight from Spotlight or Finder to get back to Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Launcher") {
                Picker("Hotkey", selection: $hotKey) {
                    ForEach(HotKeyPreset.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .onChange(of: hotKey) { state.applyHotKey() }
                if !state.hotKeyRegistered {
                    Text("That shortcut is taken by another app. Pick a different one.")
                        .font(.caption).foregroundStyle(.orange)
                }
                LabeledContent("Window") {
                    Button("Reset Position and Size") { state.launcher.resetFrame() }
                }
                Text("Drag the bar to move it and drag its edges to resize. Pin it (⌘P) to keep it open and on top.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Notify when a command finishes in the background", isOn: $notifyOnFinish)
                    .onChange(of: notifyOnFinish) { _, on in
                        if on { Notifier.requestPermission() }
                        refreshNotificationStatus()
                    }
                HStack {
                    if notifyOnFinish && !notificationsAllowed {
                        Text("macOS has notifications turned off for Termight.")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Text("Banner style and sounds are set in System Settings.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Notification Settings…") { Notifier.openSystemSettings() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                Text("Close the bar (click outside or press the hotkey) and the command keeps running.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            UpdateSettings()
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = LoginItem.isEnabled
            loginStatus = LoginItem.status
            refreshNotificationStatus()
        }
        // Coming back from System Settings: re-read the permission.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshNotificationStatus()
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        guard on != LoginItem.isEnabled else { return }
        do {
            try LoginItem.set(on)
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        loginStatus = LoginItem.status
        launchAtLogin = LoginItem.isEnabled || loginStatus == .requiresApproval
    }
}

private struct UpdateSettings: View {
    @ObservedObject private var updater = Updater.shared
    @AppStorage(Prefs.checkForUpdates) private var checkForUpdates = true

    private var status: String {
        let message = updater.state.message
        if !message.isEmpty { return message }
        guard let last = updater.lastChecked else { return "Not checked yet." }
        return "Last checked " + last.formatted(.relative(presentation: .named)) + "."
    }

    var body: some View {
        Section("Updates") {
            if updater.supported {
                Toggle("Check for updates automatically", isOn: $checkForUpdates)
                HStack {
                    Text("Version \(updater.current) · \(status)")
                        .font(.caption)
                        .foregroundStyle(updater.state.isFailure ? .orange : .secondary)
                    Spacer()
                    if case .available(let r) = updater.state {
                        Button("Install \(r.version)…") { updater.offer(r) }
                    } else {
                        Button("Check Now") { Task { await updater.check(userInitiated: true) } }
                            .disabled(updater.state == .checking || updater.state == .installing)
                    }
                }
                Text("Checks GitHub once a day. An update installs only if Apple notarized it and it is signed by the same developer as this copy.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Version \(updater.current). This copy isn't signed by a developer team, so it can't update itself.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

extension Updater.State {
    var isFailure: Bool { if case .failed = self { true } else { false } }
}

private struct CommandSettings: View {
    @ObservedObject private var state = AppState.shared

    @AppStorage(Prefs.requireValid) private var requireValid = true
    @AppStorage(Prefs.openInteractiveInTerminal) private var openInteractive = true
    @AppStorage(Prefs.loadShellRC) private var loadShellRC = false
    @AppStorage(Prefs.allowShortcuts) private var allowShortcuts = false
    @AppStorage(Prefs.timeout) private var timeout = 300
    @AppStorage(Prefs.maxLines) private var maxLines = 500
    @AppStorage(Prefs.colorOutput) private var colorOutput = true
    @AppStorage(Prefs.watchInterval) private var watchInterval = 2

    @State private var historyCleared = false

    var body: some View {
        Form {
            Section {
                Toggle("Only run recognized commands", isOn: $requireValid)
                Text(requireValid
                     ? "Return runs commands with a green dot. ⇧Return runs anything."
                     : "Return runs whatever you type.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Open interactive commands in Terminal", isOn: $openInteractive)
                Text("vim, ssh, top, sudo, git commit without -m and similar get a blue dot and open in Terminal. ⌘Return opens any command there.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Allow Spotlight and Shortcuts to run commands", isOn: $allowShortcuts)
                Text("Off: the Run Command and Run Snippet actions do nothing. On: they run with no confirmation, including from a shortcut or automation you did not write yourself.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Load ~/.zshrc (aliases and functions)", isOn: $loadShellRC)
                Text("Slightly slower per command, depending on what your shell config does.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Output") {
                Toggle("Show colors", isOn: $colorOutput)
                Text("Commands run as if in a terminal, so ls, git and grep color their output and fit it to the bar's width. Pagers print straight through. Turn off to get plain text from a pipe.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper(value: $watchInterval, in: 1...3600) {
                    LabeledContent("Watch (⌥Return) runs every", value: Self.duration(watchInterval))
                }
                Text("A watched command runs again until you press Esc; lines that changed since the last run are highlighted.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Limits") {
                Stepper(value: $timeout, in: 5...3600, step: timeout < 60 ? 5 : 30) {
                    LabeledContent("Launcher timeout", value: Self.duration(timeout))
                }
                Stepper(value: $maxLines, in: 50...5000, step: 50) {
                    LabeledContent("Lines kept on screen", value: "\(maxLines)")
                }
                Text("Spotlight runs use a 30 s timeout. Output is saved to the log, up to 5 MB per command.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("History") {
                HStack {
                    Button("Show Logs in Finder") { state.revealLogs() }
                    Spacer()
                    Button(historyCleared ? "Cleared" : "Clear History", role: .destructive) {
                        state.clearHistory()
                        historyCleared = true
                    }
                    .disabled(historyCleared)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { historyCleared = false }
    }

    private static func duration(_ s: Int) -> String {
        s < 60 ? "\(s) s" : s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s"
    }
}

private struct SnippetSettings: View {
    @State private var snippets = SnippetStore.load()
    @State private var selection: Snippet.ID?
    @State private var saveError: String?
    /// Snippet names that are also real commands: the snippet wins, which may surprise.
    @State private var shadowing: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Type a snippet's name in the launcher to run its command. Words typed after the name fill its placeholders in order; any not filled are asked for.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                GridRow { Text("{name}  {name:default}").monospaced(); Text("text, with an optional fallback") }
                GridRow { Text("{#count}").monospaced(); Text("a whole number, the only text allowed in $(( ))") }
                GridRow { Text("{env|dev|staging|prod}").monospaced(); Text("one of the choices, picked from a list") }
                GridRow { Text("{!token}").monospaced(); Text("a secret from the Keychain, never shown or logged") }
                GridRow { Text("{files}").monospaced(); Text("the files you right-click in Finder → Run in Termight") }
                GridRow { Text("{{name}}").monospaced(); Text("a literal {name}") }
            }
            .font(.caption).foregroundStyle(.secondary)

            Table($snippets, selection: $selection) {
                TableColumn("Name") { $s in
                    TextField("name", text: $s.name)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(nameIsFine(s) ? .primary : Color.orange)
                }
                .width(min: 90, ideal: 120, max: 180)
                TableColumn("Command") { $s in
                    TextField("command", text: $s.command)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .onChange(of: snippets) { save() }

            HStack(alignment: .top) {
                Button { add() } label: { Image(systemName: "plus") }
                Button { remove() } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    if let saveError {
                        Text("Not saved: \(saveError)").foregroundStyle(.red)
                    }
                    ForEach(warnings, id: \.self) { Text($0).foregroundStyle(.orange) }
                }
                .font(.caption)
            }

            SecretList()
        }
        .padding(20)
        .onAppear {
            snippets = SnippetStore.load()
            checkShadowing()
        }
    }

    private var duplicates: Set<String> {
        var seen = Set<String>(), twice = Set<String>()
        for name in snippets.map(\.name) where !name.isEmpty {
            if !seen.insert(name).inserted { twice.insert(name) }
        }
        return twice
    }

    private func nameIsFine(_ s: Snippet) -> Bool {
        s.name.isEmpty || (s.isValid && !duplicates.contains(s.name) && !shadowing.contains(s.name))
    }

    private var warnings: [String] {
        var out: [String] = []
        if snippets.contains(where: { !$0.name.isEmpty && $0.name.contains(where: \.isWhitespace) }) {
            out.append("Names can't contain spaces.")
        }
        let twice = duplicates.sorted()
        if !twice.isEmpty {
            out.append("Used more than once (the first one runs): \(twice.joined(separator: ", "))")
        }
        let hidden = shadowing.intersection(snippets.map(\.name)).sorted()
        if !hidden.isEmpty {
            out.append("Also a real command (the snippet runs instead): \(hidden.joined(separator: ", "))")
        }
        return out
    }

    private func save() {
        do {
            try SnippetStore.save(snippets)
            saveError = nil
        } catch {
            saveError = error.localizedDescription
        }
        checkShadowing()
    }

    private func checkShadowing() {
        let names = Set(snippets.map(\.name).filter { !$0.isEmpty && !$0.contains(where: \.isWhitespace) })
        Task {
            var found = Set<String>()
            for name in names where await Runner.isCommand(name) { found.insert(name) }
            shadowing = found
        }
    }

    private func add() {
        let s = Snippet(name: "", command: "")
        snippets.append(s)
        selection = s.id
    }

    private func remove() {
        snippets.removeAll { $0.id == selection }
        selection = nil
    }
}

/// The `{!name}` secrets stored in the Keychain: add, replace, delete. Values
/// are never shown again once saved.
private struct SecretList: View {
    @State private var names = Secrets.names()
    @State private var newName = ""
    @State private var newValue = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Secrets").font(.headline)
            if names.isEmpty {
                Text("None yet. A snippet's {!name} asks for its secret the first time and saves it here.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(names, id: \.self) { name in
                            HStack {
                                Text("{!\(name)}").monospaced()
                                Text("••••••••").foregroundStyle(.secondary)
                                Spacer()
                                Button("Delete", role: .destructive) {
                                    Secrets.delete(name)
                                    names = Secrets.names()
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
                .frame(maxHeight: 70)
            }
            HStack {
                TextField("name", text: $newName).frame(width: 120).monospaced()
                SecureField("value", text: $newValue)
                Button("Save") {
                    do {
                        try Secrets.set(newName, newValue)
                        newName = ""
                        newValue = ""
                        error = nil
                        names = Secrets.names()
                    } catch let e {
                        error = e.localizedDescription
                    }
                }
                .disabled(!Secrets.isValidName(newName) || newValue.isEmpty)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onAppear { names = Secrets.names() }
    }
}

/// Commands whose output stays in the menu bar.
private struct MenuBarSettings: View {
    @ObservedObject private var store = StatusCommands.shared
    @State private var selection: StatusCommand.ID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Each command gets its own item in the menu bar, showing the first line of its output, and runs again on its schedule. Click an item for the rest of the output. Snippets work here too.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Table($store.items, selection: $selection) {
                TableColumn("Label") { $c in
                    TextField("optional", text: $c.label)
                }
                .width(min: 60, ideal: 80, max: 120)
                TableColumn("Command") { $c in
                    TextField("e.g. ipconfig getifaddr en0", text: $c.command)
                        .font(.system(.body, design: .monospaced))
                }
                TableColumn("Every") { $c in
                    Stepper(value: $c.interval, in: StatusCommand.minInterval...86_400,
                            step: c.interval < 60 ? 5 : 60) {
                        Text(c.interval < 60 ? "\(c.interval) s" : "\(c.interval / 60) min")
                            .monospacedDigit()
                    }
                }
                .width(min: 90, ideal: 100, max: 120)
            }
            HStack {
                Button { add() } label: { Image(systemName: "plus") }
                    .disabled(store.items.count >= StatusCommand.maxCount)
                Button { remove() } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                Button("Refresh All") { store.refreshAll() }
                Spacer()
                Text("Up to \(StatusCommand.maxCount). They run on their own, so keep them quick and harmless.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private func add() {
        let c = StatusCommand()
        store.items.append(c)
        selection = c.id
    }

    private func remove() {
        store.items.removeAll { $0.id == selection }
        selection = nil
    }
}
