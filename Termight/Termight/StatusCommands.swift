// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 David Nordqvist
//
// This file is part of Termight. Termight is free software: you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License, version 3, as published by the Free Software Foundation. It comes
// with no warranty. See the LICENSE file for the full text.

import AppKit
import SwiftUI

/// A command whose output stays in the menu bar, run again every `interval`
/// seconds: an IP address, a build status, a count.
struct StatusCommand: Codable, Identifiable, Hashable {
    var id = UUID()
    var label = ""
    var command = ""
    var interval = 60

    static let minInterval = 5
    static let maxCount = 5

    var isValid: Bool { !command.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// The menu bar commands from Settings → Menu Bar, one status item each.
@MainActor
final class StatusCommands: ObservableObject {
    static let shared = StatusCommands()

    @Published var items: [StatusCommand] {
        didSet {
            save()
            sync()
        }
    }

    private var bars: [UUID: StatusBar] = [:]

    private init() {
        if let data = Prefs.d.data(forKey: Prefs.statusCommands),
           let saved = try? JSONDecoder().decode([StatusCommand].self, from: data) {
            items = saved
        } else {
            items = []
        }
    }

    func start() { sync() }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { Prefs.d.set(data, forKey: Prefs.statusCommands) }
    }

    /// One status item per valid command, in order; removed ones go away.
    private func sync() {
        let wanted = items.filter(\.isValid).prefix(StatusCommand.maxCount)
        for id in bars.keys where !wanted.contains(where: { $0.id == id }) {
            bars[id]?.remove()
            bars[id] = nil
        }
        for item in wanted {
            if let bar = bars[item.id] { bar.update(item) } else { bars[item.id] = StatusBar(item) }
        }
    }

    func refreshAll() { bars.values.forEach { $0.refresh() } }
}

/// One menu bar item: the first line of its command's output as the title,
/// the rest in its menu.
@MainActor
final class StatusBar: NSObject, NSMenuDelegate {
    private var item: StatusCommand
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var timer: Timer?
    private var lines: [String] = []
    private var status = ""
    private var lastRun: Date?
    private var current: Task<Void, Never>?

    init(_ item: StatusCommand) {
        self.item = item
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        setTitle("…")
        schedule()
        refresh()
    }

    func update(_ new: StatusCommand) {
        let rerun = new.command != item.command || new.interval != item.interval
        item = new
        if rerun {
            schedule()
            refresh()
        } else {
            showResult()
        }
    }

    func remove() {
        timer?.invalidate()
        current?.cancel()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func schedule() {
        timer?.invalidate()
        let every = TimeInterval(max(item.interval, StatusCommand.minInterval))
        timer = Timer.scheduledTimer(withTimeInterval: every, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard current == nil else { return }
        let command = item.command
        // Quiet: no history or logs for something that runs every minute.
        let env = ["TERMIGHT_NO_LOG": "1",
                   "TERMIGHT_TIMEOUT": String(min(max(item.interval, StatusCommand.minInterval), 60)),
                   "TERMIGHT_LINES": "25"]
        current = Task {
            let out = (try? await Runner.run(command, strictValues: true, environment: env)) ?? "✗ termight-core missing"
            var all = out.components(separatedBy: "\n")
            status = all.isEmpty ? "" : all.removeFirst()
            lines = all.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            lastRun = Date()
            current = nil
            showResult()
        }
    }

    private func showResult() {
        let failed = status.hasPrefix("✗")
        let first = lines.first ?? (failed ? "" : "—")
        var title = item.label.isEmpty ? first : first.isEmpty ? item.label : "\(item.label) \(first)"
        if failed { title = "⚠︎ " + (item.label.isEmpty ? String(item.command.prefix(20)) : item.label) }
        setTitle(title)
    }

    private func setTitle(_ s: String) {
        statusItem.button?.title = s.count > 40 ? String(s.prefix(39)) + "…" : s
        statusItem.button?.toolTip = item.command
    }

    // The menu is built when it opens, from the last run.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: item.command, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        var when = status
        if let lastRun { when += " · " + lastRun.formatted(date: .omitted, time: .shortened) }
        let statusRow = NSMenuItem(title: when, action: nil, keyEquivalent: "")
        statusRow.isEnabled = false
        menu.addItem(statusRow)
        menu.addItem(.separator())
        for line in lines.prefix(20) {
            let row = NSMenuItem(title: line.count > 80 ? String(line.prefix(79)) + "…" : line, action: nil, keyEquivalent: "")
            row.attributedTitle = NSAttributedString(
                string: row.title, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
            row.isEnabled = false
            menu.addItem(row)
        }
        if lines.isEmpty {
            let none = NSMenuItem(title: "No output", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        menu.addItem(action("Refresh Now", #selector(refreshNow)))
        menu.addItem(action("Open in Termight", #selector(openInLauncher)))
        menu.addItem(action("Menu Bar Settings…", #selector(openSettings)))
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        m.target = self
        return m
    }

    @objc private func refreshNow() { refresh() }
    @objc private func openInLauncher() { AppState.shared.launcher.show(prefill: item.command) }
    @objc private func openSettings() { AppState.shared.openSettings() }
}
