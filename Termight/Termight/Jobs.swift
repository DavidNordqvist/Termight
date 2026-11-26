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
    let id: UUID
    let command: String
    let startedAt: Date
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
    @Published private(set) var output = "" {
        didSet {
            plainCache = nil
            version &+= 1
        }
    }
    private var plainCache: String?
    /// Kept (⌘K): never dropped to make room for newer output.
    @Published var kept = false
    /// `output`, styled for the screen. Built when first needed (a saved
    /// job's output isn't styled until it's shown), then extended one batch
    /// at a time: only lines that arrived are styled.
    @Published private(set) var rendered = AttributedString()
    private var renderState: RenderState?
    /// Bumped when `output` changes; keys the marked-output cache.
    private var version = 0
    private var markedCache: (key: Int, version: Int, value: AttributedString)?
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
        id = UUID()
        startedAt = Date()
        self.command = command
        self.color = color && Prefs.d.bool(forKey: Prefs.colorOutput)
        self.environment = environment
        self.files = files
        self.watchEvery = watchEvery
        logURL = JobStore.logDir.appendingPathComponent("\(id.uuidString).log")
    }

    /// A finished job kept from an earlier launch. Its output is read from its
    /// log the first time it's shown.
    init(saved: JobStore.Saved) {
        id = saved.id
        startedAt = saved.startedAt
        command = saved.command
        color = false
        environment = [:]
        files = []
        watchEvery = nil
        logURL = JobStore.logDir.appendingPathComponent("\(saved.id.uuidString).log")
        startCwd = saved.cwd
        status = saved.status
        running = false
        finishedAt = saved.finishedAt
        kept = saved.kept ?? false
        needsSavedOutput = true
    }

    private var needsSavedOutput = false

    /// For a job from an earlier launch: its output, from the end of its log.
    func loadSavedOutput() {
        guard needsSavedOutput else { return }
        needsSavedOutput = false
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(Self.maxOutputBytes) ? size - UInt64(Self.maxOutputBytes) : 0
        try? handle.seek(toOffset: start)
        var text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        // The log starts with "$ command" and the status line.
        let header = "$ \(command)\n\(status)\n"
        if start == 0, text.hasPrefix(header) { text.removeFirst(header.count) }
        if start > 0 { trimmedFront = true }
        append(text, render: false)
    }

    /// Styles the output if it hasn't been yet (a saved job about to be shown).
    func ensureRendered() {
        if renderState == nil || renderedPalette != Ansi.paletteVersion { updateRendered(full: true) }
    }

    /// The terminal palette `rendered` was styled with (a theme can change it).
    private var renderedPalette = -1

    /// The output as shown with a search term picked out and/or lines tinted
    /// (⌘D). Cached until the output, the term or the lines change.
    func marked(_ mark: String?, highlight: Set<Int>?) -> AttributedString {
        guard mark != nil || highlight != nil else {
            ensureRendered()
            return rendered
        }
        var hasher = Hasher()
        hasher.combine(mark)
        hasher.combine(highlight)
        let key = hasher.finalize()
        if let c = markedCache, c.key == key, c.version == version &+ Ansi.paletteVersion { return c.value }
        let value = Ansi.render(Ansi.lines(output), highlight: highlight ?? [], mark: mark)
        markedCache = (key, version &+ Ansi.paletteVersion, value)
        return value
    }

    /// "3 h ago" for a job that finished a while back; nil for a recent one.
    var finishedAgo: String? {
        guard let finishedAt, Date().timeIntervalSince(finishedAt) >= 60 else { return nil }
        return finishedAt.formatted(.relative(presentation: .named))
    }

    var succeeded: Bool { status.hasPrefix("✓") }
    var watching: Bool { watchEvery != nil && running }

    /// The output without color codes, as Copy puts it on the clipboard.
    var plainOutput: String {
        if let plainCache { return plainCache }
        // Kept output from a log is already plain: skip the parse (⌃R reads up to 100 of them).
        let p = output.utf8.contains(where: { $0 == 0x1B || $0 == 0x0D }) ? Ansi.plain(output) : output
        plainCache = p
        return p
    }

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
            let before = Ansi.plainLines(output)
            // The styled state belongs to the old output: drop it, so nothing
            // is styled until the full restyle below.
            renderState = nil
            output = ""
            trimmedFront = false
            append(incoming, render: false)
            incoming = ""
            changed = LineDiff.compare(before, Ansi.plainLines(output)).changed
            updateRendered(full: true)
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
        var trimmed = output.utf8.count > Self.maxOutputBytes
        if trimmed {
            output = String(output.suffix(Self.maxOutputBytes / 2))
            trimmedFront = true
        }
        // Past the line limit, cut back to four fifths of it, so the full
        // re-style a cut needs happens once per many lines, not every batch.
        let limit = max(Prefs.d.integer(forKey: Prefs.maxLines), 20)
        if Self.startOfLast(limit, linesIn: output) != nil {
            if let keep = Self.startOfLast(limit - limit / 5, linesIn: output) {
                output = String(output[keep...])
                trimmedFront = true
                trimmed = true
            }
        }
        // Lines cut from the front shift everything: style it all again.
        if render || renderState != nil { updateRendered(full: trimmed) }
    }

    /// Where the last `n` lines of `s` start, counting newlines back from the
    /// end on bytes (much faster than Characters); nil if it has fewer.
    private static func startOfLast(_ n: Int, linesIn s: String) -> String.Index? {
        let bytes = s.utf8
        var newlines = 0
        var i = bytes.endIndex
        while i > bytes.startIndex {
            i = bytes.index(before: i)
            guard bytes[i] == 0x0A else { continue }
            newlines += 1
            if newlines > n { return bytes.index(after: i) }
        }
        return nil
    }

    /// What's been styled so far: every complete line up to `committedEnd`
    /// (a UTF-8 offset into `output`) and the style the last one ended in.
    private struct RenderState {
        var committedEnd = 0
        var committed = AttributedString()
        var lineCount = 0
        var endStyle = Ansi.Style()
    }

    /// Styles the lines that arrived since the last call and the unfinished
    /// last line. A `\r` only rewrites the unfinished line, which is always
    /// styled afresh, so complete lines never need it again.
    private func updateRendered(full: Bool) {
        var st = full || renderState == nil ? RenderState() : renderState!
        let bytes = output.utf8
        // A state for longer output than there is now is stale: start over.
        if st.committedEnd > bytes.count { st = RenderState() }
        let from = bytes.index(bytes.startIndex, offsetBy: st.committedEnd)
        let fresh = output[from...]
        if let nl = fresh.utf8.lastIndex(of: 0x0A) {
            let complete = fresh[...nl]
            let (lines, end) = Ansi.lines(complete, start: st.endStyle)
            for line in lines {
                if st.lineCount > 0 { st.committed.append(AttributedString("\n")) }
                st.committed.append(Ansi.renderLine(line, highlight: changed.contains(st.lineCount)))
                st.lineCount += 1
            }
            st.endStyle = end
            st.committedEnd = bytes.distance(from: bytes.startIndex, to: bytes.index(after: nl))
        }
        let rest = output[bytes.index(bytes.startIndex, offsetBy: min(st.committedEnd, bytes.count))...]
        var shown = st.committed
        if let partial = Ansi.lines(rest, start: st.endStyle).lines.first, !partial.isEmpty {
            if st.lineCount > 0 { shown.append(AttributedString("\n")) }
            shown.append(Ansi.renderLine(partial, highlight: changed.contains(st.lineCount)))
        }
        renderState = st
        renderedPalette = Ansi.paletteVersion
        rendered = shown
    }
}

@MainActor
final class JobStore: ObservableObject {
    /// Finished jobs kept (with their output), not counting ones kept with ⌘K.
    static let keep = 100
    /// Outputs kept with ⌘K, at most.
    static let maxKept = 5
    /// The jobs folder's size limit. Each log is at most 1 MB (the core cuts
    /// longer output), so this holds about ten full ones; small logs fit many more.
    static let budget = 10 * 1024 * 1024
    static var logDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/termight/jobs")
    }

    /// Newest first.
    @Published private(set) var jobs: [Job] = []
    @Published private(set) var runningCount = 0

    /// A finished job as remembered between launches (jobs/index.json).
    struct Saved: Codable {
        var id: UUID
        var command: String
        var status: String
        var startedAt: Date
        var finishedAt: Date
        var cwd: String
        var kept: Bool?
    }

    private static var indexURL: URL { logDir.appendingPathComponent("index.json") }

    init() {
        restore()
    }

    /// The finished jobs from earlier launches, so their output can be shown
    /// again. Logs nothing points to (a job that never finished, a line typed
    /// with a leading space) are removed.
    private func restore() {
        let fm = FileManager.default
        let saved = (try? Data(contentsOf: Self.indexURL)).flatMap { try? JSONDecoder().decode([Saved].self, from: $0) } ?? []
        let kept = saved.filter { fm.fileExists(atPath: Self.logDir.appendingPathComponent("\($0.id.uuidString).log").path) }
            .prefix(Self.keep + Self.maxKept)
        jobs = kept.map(Job.init(saved:))
        prune()
        let keepNames = Set(kept.map { "\($0.id.uuidString).log" } + ["index.json"])
        for name in (try? fm.contentsOfDirectory(atPath: Self.logDir.path)) ?? [] where !keepNames.contains(name) {
            try? fm.removeItem(at: Self.logDir.appendingPathComponent(name))
        }
    }

    /// Remembers the finished jobs for the next launch. A line typed with a
    /// leading space is left out, as it is from the history.
    private func save() {
        let saved = jobs.compactMap { j -> Saved? in
            guard !j.running, !j.command.hasPrefix(" "), let end = j.finishedAt else { return nil }
            return Saved(id: j.id, command: j.command, status: j.status, startedAt: j.startedAt, finishedAt: end,
                         cwd: j.startCwd, kept: j.kept)
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: Self.logDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(saved).write(to: Self.indexURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.indexURL.path)
        } catch {
            NSLog("Termight: could not save the job list: \(error)")
        }
    }

    /// Clear History: finished jobs and their output go too.
    func clearFinished() {
        for j in jobs where !j.running { try? FileManager.default.removeItem(at: j.logURL) }
        jobs.removeAll { !$0.running }
        refresh()
    }

    func add(_ job: Job) {
        jobs.insert(job, at: 0)
        refresh()
    }

    /// ⌘K: keep a finished job's output, or stop keeping it. False when the
    /// most kept outputs are already kept.
    func toggleKept(_ job: Job) -> Bool {
        if !job.kept && jobs.filter(\.kept).count >= Self.maxKept { return false }
        job.kept.toggle()
        refresh()
        return true
    }

    /// Keeps the jobs folder small: drops the oldest finished jobs past `keep`,
    /// then more of the oldest until the logs fit in `budget`. Running jobs and
    /// kept ones (at most `maxKept`, 1 MB each) are never dropped.
    private func prune() {
        let fm = FileManager.default
        var unkept = 0
        var total = 0
        var drop = Set<UUID>()
        for j in jobs where !j.running {  // newest first
            let size = (try? fm.attributesOfItem(atPath: j.logURL.path)[.size] as? Int) ?? 0
            total += size
            if j.kept { continue }
            unkept += 1
            if unkept > Self.keep || total > Self.budget {
                drop.insert(j.id)
                total -= size
            }
        }
        guard !drop.isEmpty else { return }
        for j in jobs where drop.contains(j.id) { try? fm.removeItem(at: j.logURL) }
        jobs.removeAll { drop.contains($0.id) }
    }

    /// Call when a job finishes so the menu bar count and list update.
    func refresh() {
        prune()
        runningCount = jobs.filter(\.running).count
        objectWillChange.send()
        save()
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
