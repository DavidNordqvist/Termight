// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 David Nordqvist
//
// This file is part of Termight. Termight is free software: you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License, version 3, as published by the Free Software Foundation. It comes
// with no warranty. See the LICENSE file for the full text.

import AppKit
import SwiftUI

/// One command run from the launcher. Several can run at once; the launcher
/// shows one, the menu bar lists them all. A watched job (⌥Return) runs its
/// command again every few seconds until stopped.
@MainActor
final class Job: ObservableObject, Identifiable {
    let id = UUID()
    let command: String
    let startedAt = Date()
    let logURL: URL
    /// Files from Finder this job runs on (kept for Run Again).
    let files: [String]
    /// Seconds between runs of a watched job; nil runs once.
    let watchEvery: Double?
    /// Run on a pseudo-terminal with colors (Settings), unless the command
    /// needs a real terminal: a pager would wait there for keys that never come.
    let color: Bool
    /// Folder the job started in; a different folder at the end means it ran `cd`.
    private(set) var startCwd = ""

    /// Raw output: may hold color codes and `\r` redraws (see Ansi).
    @Published private(set) var output = ""
    /// `output`, styled for the screen.
    @Published private(set) var rendered = AttributedString()
    @Published private(set) var trimmedFront = false
    @Published private(set) var status = ""
    @Published private(set) var running = true
    @Published private(set) var finishedAt: Date?
    /// Watched job: how many runs so far, and whether it is waiting for the next.
    @Published private(set) var runs = 0
    @Published private(set) var waiting = false

    private var stream: StreamRun?
    /// Secret values and files for the core. Dropped when the job ends.
    private var environment: [String: String]
    private var onFinish: (@MainActor (Job, StreamRun.Meta) -> Void)?
    private var lastMeta = StreamRun.Meta()
    private var stopped = false
    private var waitTask: Task<Void, Never>?
    /// A watched job's next output, shown when that run ends.
    private var incoming = ""
    private var changed: Set<Int> = []
    /// The most text kept on screen for one job; the full output is in its log.
    private static let maxOutputBytes = 1_000_000

    init(command: String, environment: [String: String] = [:], files: [String] = [], watchEvery: Double? = nil,
         color: Bool = true) {
        self.command = command
        self.color = color && Prefs.d.bool(forKey: Prefs.colorOutput)
        self.environment = environment
        self.files = files
        self.watchEvery = watchEvery
        logURL = JobStore.logDir.appendingPathComponent("\(id.uuidString).log")
    }

    var succeeded: Bool { status.hasPrefix("✓") }
    var watching: Bool { watchEvery != nil && running }

    /// The output without color codes, as Copy puts it on the clipboard.
    var plainOutput: String { Ansi.plain(output) }

    /// Menu-sized status mark.
    var glyph: String { watching ? "↻" : running ? "◌" : succeeded ? "✓" : "✗" }

    func elapsedText(now: Date = Date()) -> String {
        let s = Int((finishedAt ?? now).timeIntervalSince(startedAt))
        return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
    }

    func start(cwd: String, columns: Int, onFinish: @escaping @MainActor (Job, StreamRun.Meta) -> Void) {
        startCwd = cwd
        self.onFinish = onFinish
        runOnce(columns: columns)
    }

    private func runOnce(columns: Int) {
        runs += 1
        let buffer = ChunkBuffer { [weak self] s in self?.received(s) }
        let env = Runner.baseEnvironment.merging([
            "TERMIGHT_TIMEOUT": String(Prefs.d.integer(forKey: Prefs.timeout)),
            "TERMIGHT_LOG_FILE": logURL.path,
            "TERMIGHT_COLUMNS": String(columns),
        ]) { $1 }
            // A watched command goes into the history once, not on every run.
            .merging(runs > 1 ? ["TERMIGHT_NO_HISTORY": "1"] : [:]) { $1 }
            .merging(environment) { $1 }
        do {
            let s = try StreamRun(command: command, cwd: startCwd, environment: env,
                                  color: color, onOutput: { buffer.append($0) })
            stream = s
            Task {
                let meta = await s.result()
                received(buffer.take())
                runEnded(meta, columns: columns)
            }
        } catch {
            finish("✗ \(error.localizedDescription)")
            onFinish?(self, StreamRun.Meta(status: status))
        }
    }

    /// Esc: stops the run, and a watched job's next runs.
    func cancel() {
        stopped = true
        if waiting {
            waitTask?.cancel()
            waiting = false
            finish(status)
            onFinish?(self, lastMeta)
        } else {
            stream?.cancel()
        }
    }

    private func runEnded(_ meta: StreamRun.Meta, columns: Int) {
        stream = nil
        lastMeta = meta
        guard let every = watchEvery else {
            finish(meta.status)
            onFinish?(self, meta)
            return
        }
        if runs > 1 {
            // Swap in the new run's output and mark the lines that changed.
            let before = Ansi.lines(output).map(Ansi.plainLine)
            output = ""
            trimmedFront = false
            append(incoming, render: false)
            incoming = ""
            let after = Ansi.lines(output).map(Ansi.plainLine)
            changed = Set(after.indices.filter { $0 >= before.count || after[$0] != before[$0] })
            renderOutput()
        }
        status = meta.status
        if stopped {
            finish(meta.status)
            onFinish?(self, meta)
            return
        }
        waiting = true
        waitTask = Task {
            try? await Task.sleep(for: .seconds(every))
            guard !Task.isCancelled, !stopped else { return }
            waiting = false
            runOnce(columns: columns)
        }
    }

    private func finish(_ s: String) {
        status = s
        running = false
        finishedAt = Date()
        stream = nil
        environment = [:]  // secret values don't outlive the job
    }

    private func received(_ s: String) {
        guard !s.isEmpty else { return }
        if watchEvery != nil && runs > 1 {
            incoming += s
            if incoming.utf8.count > Self.maxOutputBytes { incoming = String(incoming.suffix(Self.maxOutputBytes / 2)) }
        } else {
            append(s)
        }
    }

    /// Adds streamed text, keeping only the last `maxLines` lines on screen
    /// (the full output is in the job's log).
    private func append(_ s: String, render: Bool = true) {
        guard !s.isEmpty else { return }
        output += s
        // By size first: output with no newlines (a progress bar, `yes | tr -d '\n'`)
        // would otherwise grow without limit.
        if output.utf8.count > Self.maxOutputBytes {
            output = String(output.suffix(Self.maxOutputBytes / 2))
            trimmedFront = true
        }
        let limit = max(Prefs.d.integer(forKey: Prefs.maxLines), 20)
        var newlines = 0
        var cut: String.Index?
        for i in output.indices.reversed() where output[i] == "\n" {
            newlines += 1
            if newlines > limit { cut = output.index(after: i); break }
        }
        if let cut {
            output = String(output[cut...])
            trimmedFront = true
        }
        if render { renderOutput() }
    }

    private func renderOutput() {
        rendered = Ansi.render(Ansi.lines(output), highlight: changed)
    }
}

@MainActor
final class JobStore: ObservableObject {
    static let keep = 20
    static var logDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/termight/jobs")
    }

    /// Newest first.
    @Published private(set) var jobs: [Job] = []
    @Published private(set) var runningCount = 0

    init() {
        // Logs from a previous launch belong to jobs that no longer exist.
        try? FileManager.default.removeItem(at: Self.logDir)
    }

    func add(_ job: Job) {
        jobs.insert(job, at: 0)
        // Drop the oldest finished jobs past the limit; never drop a running one.
        while jobs.count > Self.keep, let i = jobs.lastIndex(where: { !$0.running }) {
            try? FileManager.default.removeItem(at: jobs[i].logURL)
            jobs.remove(at: i)
        }
        refresh()
    }

    /// Call when a job finishes so the menu bar count and list update.
    func refresh() {
        runningCount = jobs.filter(\.running).count
        objectWillChange.send()
    }

    func cancelAll() {
        jobs.filter(\.running).forEach { $0.cancel() }
    }
}

/// Menu bar icon: the terminal symbol, plus a count while jobs are running.
struct MenuBarLabel: View {
    @ObservedObject var store: JobStore

    var body: some View {
        if store.runningCount > 0 {
            HStack(spacing: 3) {
                Image("MenuBarIcon")
                Text("\(store.runningCount)")
            }
        } else {
            Image("MenuBarIcon")
        }
    }
}

/// One job in the menu bar list. Running jobs get a submenu with Cancel.
struct JobMenuItem: View {
    @ObservedObject var job: Job

    private var title: String {
        let cmd = job.command.count > 40 ? String(job.command.prefix(39)) + "…" : job.command
        return "\(job.glyph)  \(cmd)  ·  \(job.elapsedText())"
    }

    var body: some View {
        if job.running {
            Menu(title) {
                Button("Show Output") { AppState.shared.launcher.show(job: job) }
                Button("Cancel") { job.cancel() }
            }
        } else {
            Button(title) { AppState.shared.launcher.show(job: job) }
        }
    }
}
