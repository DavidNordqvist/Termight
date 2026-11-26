// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 David Nordqvist
//
// This file is part of Termight. Termight is free software: you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License, version 3, as published by the Free Software Foundation. It comes
// with no warranty. See the LICENSE file for the full text.

import AppKit
import Carbon.HIToolbox
import SwiftUI

// Hotkey launcher: a Spotlight-style panel where everything typed is a shell command.
//   Return        run (or hand off to Terminal if the command needs a real terminal)
//   ⇧Return       run here even if the check says no
//   ⌘Return       open in Terminal
//   ⌥Return       watch: run it again every few seconds, changed lines highlighted
//   Tab           complete the command or path
//   ↑ / ↓         history
//   ⌃R            search history
//   ⇧⌘C ⌘R ⌘L     copy all output, rerun, open full log
//   ⌘P            pin: stay open and on top when you click elsewhere
//   Esc           cancel a running command / leave search; again to close
// Drag an empty area to move it, drag an edge or corner to resize; both are remembered.
// Commands run as jobs: start another while one runs; the menu bar lists them.

@MainActor
final class Launcher: NSObject, NSWindowDelegate {
    static let defaultSize = NSSize(width: 712, height: 420)
    static let minSize = NSSize(width: 420, height: 160)

    private let model = LauncherModel()
    private let panel: LauncherPanel
    private let hotKey = HotKey()
    private var applyingFrame = false  // our own setFrame calls must not be saved as user moves

    override init() {
        panel = LauncherPanel()
        super.init()
        let host = NSHostingView(rootView: LauncherView(model: model))
        host.sizingOptions = []  // the window decides its size, not the content
        panel.contentView = ResizableContainer(content: host, minSize: Self.minSize)
        panel.delegate = self
        panel.shouldHideOnResignKey = { [weak self] in !(self?.model.pinned ?? false) }
        model.onHide = { [weak self] in
            guard let self, !self.model.pinned else { return }
            self.hide()
        }
        model.isVisible = { [weak self] in self?.panel.isVisible ?? false }
        hotKey.action = { [weak self] in self?.toggle() }
    }

    /// Re-registers the global hotkey. Returns false if another app owns it.
    @discardableResult
    func setHotKey(_ preset: HotKeyPreset) -> Bool {
        guard let mods = preset.carbonModifiers else {
            hotKey.unregister()
            return true
        }
        let ok = hotKey.register(keyCode: UInt32(kVK_Space), modifiers: mods)
        if !ok { NSLog("Termight: could not register \(preset.label) (another app may own it)") }
        return ok
    }

    /// Hotkey: show; hide if it has focus; if pinned and in the background, focus it.
    func toggle() {
        if !panel.isVisible {
            show()
        } else if panel.isKeyWindow || !model.pinned {
            hide()
        } else {
            panel.makeKeyAndOrderFront(nil)
            model.refocus()
        }
    }

    /// `prefill` puts text in the input; `job` shows that job's output;
    /// `files` (from Finder) are passed to the next command; `cwd` sets the folder.
    func show(prefill: String? = nil, job: Job? = nil, files: [String] = [], cwd: String? = nil) {
        model.prepareForShow(prefill: prefill, job: job, files: files, cwd: cwd)
        if !panel.isVisible { place() }
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() { panel.orderOut(nil) }

    /// Forget the saved position and size; the bar goes back to its default spot.
    func resetFrame() {
        for key in [Prefs.winX, Prefs.winTop, Prefs.winW, Prefs.winH] { Prefs.d.removeObject(forKey: key) }
        place()
    }

    // MARK: Frame

    private var savedSize: NSSize {
        let w = Prefs.d.double(forKey: Prefs.winW), h = Prefs.d.double(forKey: Prefs.winH)
        return NSSize(width: w >= Self.minSize.width ? w : Self.defaultSize.width,
                      height: h >= Self.minSize.height ? h : Self.defaultSize.height)
    }

    /// Restores the saved size, with the top-left corner where the user last
    /// left it, or at the default spot (centred, ~18% down the screen under the
    /// mouse) if there is none or it is no longer on a screen.
    private func place() {
        let size = savedSize
        var topLeft: NSPoint?
        if Prefs.d.object(forKey: Prefs.winX) != nil {
            let p = NSPoint(x: Prefs.d.double(forKey: Prefs.winX), y: Prefs.d.double(forKey: Prefs.winTop))
            let grab = NSRect(x: p.x, y: p.y - 40, width: min(size.width, 200), height: 40)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(grab) }) { topLeft = p }
        }
        if topLeft == nil {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            if let f = screen?.visibleFrame {
                topLeft = NSPoint(x: f.midX - size.width / 2, y: f.maxY - f.height * 0.18)
            }
        }
        guard let topLeft else { return }
        applyingFrame = true
        panel.setFrame(NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height), display: true)
        applyingFrame = false
    }

    private func saveFrame() {
        guard !applyingFrame, panel.isVisible else { return }
        let f = panel.frame
        Prefs.d.set(f.minX, forKey: Prefs.winX)
        Prefs.d.set(f.maxY, forKey: Prefs.winTop)
        Prefs.d.set(f.width, forKey: Prefs.winW)
        Prefs.d.set(f.height, forKey: Prefs.winH)
    }

    /// How many characters fit across the output, for commands that format to
    /// the terminal's width (ls, git log).
    static var columns: Int {
        let w = Prefs.d.double(forKey: Prefs.winW)
        let width = w >= minSize.width ? w : defaultSize.width
        let char = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular).advancement(forGlyph: 0).width
        let per = char > 0 ? char : 7.5
        return max(Int((width - 40) / per), 40)
    }

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidResize(_ notification: Notification) { saveFrame() }
}

/// Borderless, non-activating panel: takes keyboard focus without pulling the
/// frontmost app out of focus and floats above other windows. Moving and
/// resizing are done by WindowDragArea and ResizableContainer, because a
/// borderless window's own resize edges are ~1 pt wide and SwiftUI content
/// swallows background drags. Closes when it loses focus unless pinned.
final class LauncherPanel: NSPanel {
    var shouldHideOnResignKey: () -> Bool = { true }

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Launcher.defaultSize),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        if shouldHideOnResignKey() { orderOut(nil) }
    }
}

/// Window content plus eight invisible resize handles laid over its edges and corners.
final class ResizableContainer: NSView {
    static let edge: CGFloat = 8      // thickness of the edge grab strips
    static let corner: CGFloat = 20   // size of the corner grab squares

    private var handles: [ResizeHandle] = []

    init(content: NSView, minSize: NSSize) {
        super.init(frame: NSRect(origin: .zero, size: Launcher.defaultSize))
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        // Corners last so they sit above the edge strips.
        let all: [ResizeHandle.Edges] = [.left, .right, .top, .bottom,
                                         [.left, .top], [.right, .top], [.left, .bottom], [.right, .bottom]]
        for edges in all {
            let h = ResizeHandle(edges: edges, minSize: minSize)
            handles.append(h)
            addSubview(h)
        }
        layoutHandles()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutHandles()
    }

    private func layoutHandles() {
        let e = Self.edge, c = Self.corner, w = bounds.width, h = bounds.height
        for handle in handles {
            let x: CGFloat, width: CGFloat, y: CGFloat, height: CGFloat
            let horizontal = handle.edges.contains(.left) || handle.edges.contains(.right)
            let vertical = handle.edges.contains(.top) || handle.edges.contains(.bottom)
            if horizontal && vertical {
                (width, height) = (c, c)
                x = handle.edges.contains(.left) ? 0 : w - c
                y = handle.edges.contains(.bottom) ? 0 : h - c
            } else if horizontal {
                (width, height) = (e, max(h - 2 * c, 0))
                x = handle.edges.contains(.left) ? 0 : w - e
                y = c
            } else {
                (width, height) = (max(w - 2 * c, 0), e)
                x = c
                y = handle.edges.contains(.bottom) ? 0 : h - e
            }
            handle.frame = NSRect(x: x, y: y, width: width, height: height)
        }
    }
}

/// One invisible grab area. Dragging it resizes the window from that edge or
/// corner, keeping the opposite side fixed.
final class ResizeHandle: NSView {
    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1), right = Edges(rawValue: 2)
        static let top = Edges(rawValue: 4), bottom = Edges(rawValue: 8)
    }

    let edges: Edges
    private let minSize: NSSize
    private var startFrame = NSRect.zero
    private var startMouse = NSPoint.zero

    init(edges: Edges, minSize: NSSize) {
        self.edges = edges
        self.minSize = minSize
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var cursor: NSCursor {
        let position: NSCursor.FrameResizePosition
        switch edges {
        case .left: position = .left
        case .right: position = .right
        case .top: position = .top
        case .bottom: position = .bottom
        case [.left, .top]: position = .topLeft
        case [.right, .top]: position = .topRight
        case [.left, .bottom]: position = .bottomLeft
        default: position = .bottomRight
        }
        return NSCursor.frameResize(position: position, directions: .all)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: cursor) }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        startFrame = window.frame
        startMouse = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - startMouse.x, dy = now.y - startMouse.y
        var f = startFrame
        let maxSize = window.screen?.visibleFrame.size ?? NSSize(width: 4000, height: 4000)
        if edges.contains(.right) { f.size.width = startFrame.width + dx }
        if edges.contains(.left) { f.size.width = startFrame.width - dx }
        if edges.contains(.top) { f.size.height = startFrame.height + dy }
        if edges.contains(.bottom) { f.size.height = startFrame.height - dy }
        f.size.width = min(max(f.width, minSize.width), max(maxSize.width, minSize.width))
        f.size.height = min(max(f.height, minSize.height), max(maxSize.height, minSize.height))
        // Keep the side opposite the dragged one where it was.
        if edges.contains(.left) { f.origin.x = startFrame.maxX - f.width }
        if edges.contains(.bottom) { f.origin.y = startFrame.maxY - f.height }
        window.setFrame(f, display: true)
    }
}

/// Background that moves the window when dragged. Sits behind the SwiftUI
/// content, so it gets the clicks that land on empty areas.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

/// Collects streamed output off the main thread and hands it over in ~50 ms batches,
/// so a chatty command doesn't re-render the panel thousands of times a second.
final class ChunkBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    private var scheduled = false
    private let deliver: @MainActor (String) -> Void

    init(deliver: @escaping @MainActor (String) -> Void) { self.deliver = deliver }

    func append(_ chunk: String) {
        lock.lock()
        defer { lock.unlock() }
        text += chunk
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
            let s = take()
            MainActor.assumeIsolated { deliver(s) }
        }
    }

    func take() -> String {
        lock.lock()
        defer { lock.unlock() }
        let s = text
        text = ""
        scheduled = false
        return s
    }
}

@MainActor
final class LauncherModel: ObservableObject {
    enum Submit { case normal, force, terminal, watch }

    /// Asking for a snippet's `{placeholder}` values one at a time.
    struct Prompt {
        var line: String  // what was typed, e.g. "deploy" or "deploy staging"
        var fields: [Runner.SnippetField]  // every placeholder the typed words didn't reach, in order
        var mode: Submit
        /// Secrets found in the Keychain or typed here, for the core.
        var env: [String: String]
        var values: [String] = []  // typed values (secrets go to `env` instead)
        var answered = 0
        var current: Runner.SnippetField { fields[answered] }
        var progress: String { "\(answered + 1)/\(fields.count)" }
    }

    /// A note shown in place of output (e.g. why a command didn't run).
    struct Message: Equatable {
        var title: String
        var detail: String
    }

    @Published var text = ""
    /// What the core says about the typed line; nil while the input is empty.
    @Published private(set) var check: Runner.Check?
    @Published private(set) var job: Job?
    @Published private(set) var message: Message?
    @Published private(set) var completions: [String] = []
    @Published private(set) var cwd: String
    @Published private(set) var focusToken = 0
    @Published private(set) var flash: String?

    @Published private(set) var searching = false
    @Published private(set) var matches: [String] = []
    @Published private(set) var matchIndex = 0

    @Published private(set) var prompt: Prompt?
    /// The highlighted choice while a `{name|a|b}` value is asked for.
    @Published private(set) var choiceIndex = 0
    /// Files from Finder for the next command (`{files}`, or added at its end).
    @Published private(set) var files: [String] = []

    /// Pinned: the bar stays open and on top when it loses focus.
    @Published var pinned = Prefs.d.bool(forKey: Prefs.pinned) {
        didSet { Prefs.d.set(pinned, forKey: Prefs.pinned) }
    }

    func refocus() { focusToken += 1 }

    var onHide: () -> Void = {}
    var isVisible: () -> Bool = { false }

    private var checkTask: Task<Void, Never>?
    private var routing = false
    private var unseenResult = false
    /// Start time of the job whose `cd` last set `cwd`: an older job can't override a newer one.
    private var cwdSetByJobStartedAt = Date.distantPast
    private var history: [String] = []
    private var historyIndex: Int?
    private var programmaticText: String?  // text we set ourselves (history, completion)
    private var savedText = ""  // input before ⌃R, restored on Esc

    init() {
        let saved = Prefs.d.string(forKey: Prefs.lastCwd) ?? ""
        var isDir: ObjCBool = false
        cwd = FileManager.default.fileExists(atPath: saved, isDirectory: &isDir) && isDir.boolValue
            ? saved : NSHomeDirectory()
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The current folder with the home folder shown as ~.
    var cwdLabel: String {
        let home = NSHomeDirectory()
        if cwd == home { return "~" }
        return cwd.hasPrefix(home + "/") ? "~" + cwd.dropFirst(home.count) : cwd
    }

    var placeholder: String {
        if searching { return "Search history…" }
        if let p = prompt {
            switch p.current.kind {
            case .secret: return "Secret for \(p.current.name), saved to the Keychain…"
            case .number: return "Whole number for \(p.current.name)…"
            case .choice: return "Choose \(p.current.name)… (↑↓)"
            case .text: return "Value for \(p.current.name)…"
            }
        }
        if !files.isEmpty { return "Command or snippet for \(files.count == 1 ? "1 file" : "\(files.count) files")…" }
        return "Type a command…"
    }

    /// The current choice prompt's options, narrowed by what is typed.
    var choices: [String] {
        guard let p = prompt, case .choice(let options) = p.current.kind else { return [] }
        let q = text.trimmingCharacters(in: .whitespaces)
        let found = q.isEmpty ? options : options.filter { $0.localizedCaseInsensitiveContains(q) }
        return found.isEmpty ? options : found
    }

    func prepareForShow(prefill: String? = nil, job shown: Job? = nil, files: [String] = [], cwd: String? = nil) {
        if let shown {
            job = shown
            message = nil
        } else if !(job?.running ?? false) && !unseenResult {
            // Fresh bar unless a command is still running or finished while hidden.
            job = nil
            message = nil
        }
        unseenResult = false
        exitSearch(restore: false)
        prompt = nil
        self.files = files
        if let first = files.first {
            // Run where the files are, as Finder shows them.
            setCwd((first as NSString).deletingLastPathComponent)
        }
        if let cwd { setCwd(cwd) }
        if let prefill { text = prefill } else { text = "" }
        completions = []
        history = History.load()
        historyIndex = nil
        focusToken += 1
    }

    func textChanged() {
        if text != programmaticText {
            historyIndex = nil
            completions = []
            choiceIndex = 0  // typing narrows the choices: start at the top
        }
        programmaticText = nil
        if searching {
            updateMatches()
            return
        }
        checkTask?.cancel()
        let line = trimmed
        guard !line.isEmpty, prompt == nil else { check = nil; return }
        let dir = cwd
        let env = Runner.filesEnvironment(files)
        checkTask = Task {
            try? await Task.sleep(for: .milliseconds(60))  // debounce fast typing
            guard !Task.isCancelled else { return }
            let r = await Runner.check(line, cwd: dir, environment: env)
            guard !Task.isCancelled, line == trimmed else { return }
            check = r
        }
    }

    // MARK: Submit

    func submit(_ mode: Submit) {
        if searching {
            acceptSearch(run: true)
            return
        }
        if prompt != nil {
            advancePrompt()
            return
        }
        guard !trimmed.isEmpty else { return }
        // A leading space is kept: it tells the core to leave the line out of history.
        route((text.hasPrefix(" ") ? " " : "") + trimmed, mode)
    }

    /// Checks `line` and sends it where it belongs: a prompt for missing snippet
    /// values, Terminal, a "not a command" note, or a job. `secrets`: values
    /// already found or typed; `files`: Finder files (default: the bar's).
    private func route(_ line: String, _ mode: Submit, secrets: [String: String] = [:], files: [String]? = nil) {
        // One at a time: a second Return before the check answers must not start the command twice.
        guard !routing else { return }
        routing = true
        let dir = cwd
        let files = files ?? self.files
        let env = secrets.merging(Runner.filesEnvironment(files)) { $1 }
        Task {
            defer { routing = false }
            var r = await Runner.check(line, cwd: dir, environment: env)
            var env = env
            var secrets = secrets
            if case .needs(let fields) = r {
                // Secrets come from the Keychain; only the ones not there are asked for.
                let names = fields.filter { $0.kind == .secret }.map(\.name)
                let found = Secrets.environment(for: names).env
                if !found.isEmpty {
                    secrets.merge(found) { $1 }
                    env.merge(found) { $1 }
                    r = await Runner.check(line, cwd: dir, environment: env)
                }
            }
            switch (r, mode) {
            case (.needs(let fields), _):
                // Before Terminal too: a half-filled snippet can't run anywhere.
                prompt = Prompt(line: line, fields: fields, mode: mode, env: secrets)
                showField(fields[0])
            case (_, .terminal):
                await handOff(line, env: env)
            case (.interactive, .normal) where Prefs.d.bool(forKey: Prefs.openInteractiveInTerminal):
                await handOff(line, env: env)
            case (.interactive, .watch):
                job = nil
                message = Message(title: "✗ This command needs a real terminal, so it can't be watched here",
                                  detail: "⌘Return opens it in Terminal")
            case (.invalid(let why), .normal), (.invalid(let why), .watch):
                if Prefs.d.bool(forKey: Prefs.requireValid) {
                    job = nil
                    message = Message(title: "✗ \(why)", detail: "⇧Return runs it anyway · ⌘Return opens it in Terminal")
                } else {
                    start(line, env: env, files: files, watch: mode == .watch)
                }
            case (.interactive, _):
                // Forced to run here (⇧Return): no pseudo-terminal, so a pager or
                // prompt sees no terminal and ends instead of waiting for the timeout.
                start(line, env: env, files: files, watch: false, color: false)
            default:
                start(line, env: env, files: files, watch: mode == .watch)
            }
        }
    }

    private func handOff(_ line: String, env: [String: String]) async {
        let dir = cwd
        // The core expands snippets, so Terminal gets exactly what the launcher would run.
        // If it refuses the snippet, show why and open nothing.
        switch await Runner.expand(line, environment: env) {
        case .failure(let failure):
            job = nil
            message = Message(title: "✗ \(failure.reason)", detail: "Nothing was opened in Terminal")
        case .success(let script):
            remember(line)
            text = ""
            files = []
            onHide()
            TerminalHandoff.open(script, typed: line, cwd: dir)
        }
    }

    private func remember(_ line: String) {
        guard !line.hasPrefix(" ") else { return }  // typed with a leading space: not kept
        history.removeAll { $0 == line }
        history.append(line)
        historyIndex = nil
        AppState.shared.historyVersion += 1
    }

    /// Runs `line` as a new job and shows it. Earlier jobs keep running.
    func start(_ line: String, env: [String: String] = [:], files: [String] = [], watch: Bool = false,
               color: Bool = true) {
        message = nil
        text = ""
        completions = []
        self.files = []
        remember(line)
        let every = watch ? Double(max(Prefs.d.integer(forKey: Prefs.watchInterval), 1)) : nil
        let j = Job(command: line, environment: env, files: files, watchEvery: every, color: color)
        AppState.shared.jobs.add(j)
        job = j
        j.start(cwd: cwd, columns: Launcher.columns) { [weak self] j, meta in self?.finished(j, meta) }
    }

    private func setCwd(_ dir: String) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { return }
        cwd = dir
        Prefs.d.set(dir, forKey: Prefs.lastCwd)
    }

    private func finished(_ j: Job, _ meta: StreamRun.Meta) {
        AppState.shared.jobs.refresh()
        AppState.shared.historyVersion += 1
        // A job that ended in a different folder than it started ran `cd`: follow it,
        // unless a job started after it has already moved the folder.
        if let dir = meta.cwd, dir != j.startCwd, j.startedAt >= cwdSetByJobStartedAt {
            cwdSetByJobStartedAt = j.startedAt
            if dir != cwd {
                cwd = dir
                Prefs.d.set(dir, forKey: Prefs.lastCwd)
            }
        }
        let onScreen = isVisible() && job === j
        if !onScreen && j.watchEvery == nil {  // a watch ends because you stopped it
            if job === j { unseenResult = true }
            Notifier.commandFinished(j.command, status: j.status)
        }
    }

    /// Esc: leave search or a prompt, then stop the shown job, then close.
    func escape() {
        if searching {
            exitSearch(restore: true)
        } else if prompt != nil {
            prompt = nil
            setText("")
        } else if let j = job, j.running {
            j.cancel()
        } else if !completions.isEmpty {
            completions = []
        } else if !files.isEmpty {
            files = []
        } else if pinned {
            // Pinned bars don't close on Esc: clear what's shown instead.
            job = nil
            message = nil
        } else {
            onHide()
        }
    }

    // MARK: Snippet placeholders

    private func advancePrompt() {
        guard var p = prompt else { return }
        let field = p.current
        switch field.kind {
        case .secret:
            guard !text.isEmpty else { NSSound.beep(); return }
            do {
                try Secrets.set(field.name, text)
            } catch {
                showFlash("Not saved to the Keychain")
            }
            p.env[Secrets.envPrefix + field.name] = text
        case .number:
            let digits = text.hasPrefix("-") ? String(text.dropFirst()) : text
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                NSSound.beep()
                showFlash("Whole numbers only")
                return
            }
            p.values.append(text)
        case .choice(let options):
            // The highlighted choice, unless what's typed is one exactly.
            let pick = options.contains(text) ? text : choices.indices.contains(choiceIndex) ? choices[choiceIndex] : text
            p.values.append(pick)
        case .text:
            p.values.append(text)
        }
        p.answered += 1
        if p.answered < p.fields.count {
            prompt = p
            showField(p.current)
            return
        }
        prompt = nil
        setText("")
        // Values go after what was typed, as shell words; the core fills the remaining
        // placeholders in order. Routed like a typed line, so a snippet that needs a
        // real terminal (ssh {host}) still opens in Terminal. Secrets never join the line.
        routing = false
        route(([p.line] + p.values.map(Self.shellQuote)).joined(separator: " "), p.mode, secrets: p.env)
    }

    /// Puts a field's default in the input; a choice's default is highlighted instead.
    private func showField(_ field: Runner.SnippetField) {
        if case .choice(let options) = field.kind {
            setText("")
            choiceIndex = field.defaultValue.flatMap { options.firstIndex(of: $0) } ?? 0
        } else {
            setText(field.defaultValue ?? "")
        }
    }

    /// One shell word for the core's own word splitter (snippet.rs, take_words).
    /// The core never passes this text to a shell: values travel as variables.
    private static func shellQuote(_ s: String) -> String {
        let safe = !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || "-_./:=@%+,".contains($0) }
        return safe ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Output actions

    /// ⇧⌘C: copy the shown job's whole output. Plain ⌘C stays the system copy,
    /// so a selection in the output or the input copies as usual.
    func copyOutput() {
        guard let j = job else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(j.plainOutput, forType: .string)
        showFlash("Copied")
    }

    /// ⌘R: run the shown job's command again (secrets are looked up again).
    func rerun() {
        guard let j = job, !searching, prompt == nil else { return }
        routing = false
        route(j.command, j.watchEvery != nil ? .watch : .force, files: j.files)
    }

    /// ⌘L: open the shown job's full log.
    func openLog() {
        guard let j = job else { return }
        if FileManager.default.fileExists(atPath: j.logURL.path) {
            NSWorkspace.shared.open(j.logURL)
        } else {
            showFlash(j.running ? "Log is written when it finishes" : "No log")
        }
    }

    private func showFlash(_ s: String) {
        flash = s
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if flash == s { flash = nil }
        }
    }

    // MARK: History search (⌃R)

    func toggleSearch() {
        if searching {
            // ⌃R again steps to the next older match, like the shell.
            if !matches.isEmpty { matchIndex = (matchIndex + 1) % matches.count }
            return
        }
        guard prompt == nil else { return }
        savedText = text
        searching = true
        history = History.load()
        completions = []
        setText("")
        updateMatches()
    }

    private func updateMatches() {
        let q = text.trimmingCharacters(in: .whitespaces)
        var found: [String] = []
        for cmd in history.reversed() where q.isEmpty || cmd.localizedCaseInsensitiveContains(q) {
            found.append(cmd)
            if found.count == 8 { break }
        }
        matches = found
        matchIndex = 0
    }

    func moveMatch(_ delta: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = min(max(matchIndex + delta, 0), matches.count - 1)
    }

    /// Return runs the selected match; Tab puts it in the input to edit.
    func acceptSearch(run: Bool) {
        guard searching else { return }
        let pick = matches.indices.contains(matchIndex) ? matches[matchIndex] : nil
        exitSearch(restore: pick == nil)
        guard let pick else { return }
        if run {
            setText(pick)
            submit(.normal)
        } else {
            setText(pick)
        }
    }

    private func exitSearch(restore: Bool) {
        guard searching else { return }
        searching = false
        matches = []
        if restore { setText(savedText) }
    }

    // MARK: History and completion

    func arrow(_ delta: Int) {
        if searching {
            moveMatch(delta)  // ↑ moves up the list
        } else if !choices.isEmpty {
            choiceIndex = min(max(choiceIndex + delta, 0), choices.count - 1)
        } else {
            historyStep(delta)
        }
    }

    func historyStep(_ delta: Int) {
        guard !history.isEmpty, prompt == nil else { return }
        let start = historyIndex ?? history.count
        let next = min(max(start + delta, 0), history.count)
        historyIndex = next == history.count ? nil : next
        setText(historyIndex.map { history[$0] } ?? "")
    }

    func tab() {
        if searching { acceptSearch(run: false) } else if prompt == nil { tabComplete() }
    }

    private func tabComplete() {
        let line = text
        let dir = cwd
        Task {
            let r = await Runner.complete(line, cwd: dir)
            guard line == text else { return }
            guard !r.candidates.isEmpty, line.hasSuffix(r.token) else {
                NSSound.beep()
                return
            }
            let base = String(line.dropLast(r.token.count))
            if r.candidates.count == 1 {
                let c = r.candidates[0]
                setText(base + c + (c.hasSuffix("/") ? "" : " "))
                completions = []
            } else {
                let common = Self.commonPrefix(r.candidates)
                if common.count > r.token.count { setText(base + common) }
                completions = Array(r.candidates.prefix(60))
            }
        }
    }

    private func setText(_ s: String) {
        programmaticText = s
        text = s
    }

    private static func commonPrefix(_ items: [String]) -> String {
        guard var prefix = items.first else { return "" }
        for s in items.dropFirst() {
            while !s.hasPrefix(prefix) { prefix.removeLast() }
        }
        return prefix
    }
}

struct LauncherView: View {
    static let cornerRadius: CGFloat = 16

    @ObservedObject var model: LauncherModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            inputRow
            if model.searching {
                Divider()
                searchResults
            } else if !model.choices.isEmpty {
                Divider()
                choiceList
            } else if !model.completions.isEmpty {
                Divider()
                completionList
            }
            if let job = model.job, !model.searching {
                Divider()
                JobOutputView(job: job, model: model)
            } else if let m = model.message, !model.searching {
                Divider()
                messageView(m)
            } else if model.completions.isEmpty && model.choices.isEmpty && !model.searching {
                keyHints
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WindowDragArea())
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .onAppear { focused = true }
        .onChange(of: model.focusToken) { focused = true }
        .background(shortcuts)
    }

    /// Invisible buttons carrying the panel's ⌘/⌃ shortcuts.
    private var shortcuts: some View {
        Group {
            Button("") { model.copyOutput() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(model.job == nil)
            Button("") { model.rerun() }.keyboardShortcut("r", modifiers: .command)
            Button("") { model.openLog() }.keyboardShortcut("l", modifiers: .command)
            Button("") { model.toggleSearch() }.keyboardShortcut("r", modifiers: .control)
            Button("") { model.pinned.toggle() }.keyboardShortcut("p", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private var inputRow: some View {
        HStack(spacing: 10) {
            Group {
                if model.searching {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 18, weight: .medium))
                } else {
                    Image("MenuBarIcon").resizable().frame(width: 24, height: 24)
                }
            }
            .foregroundStyle(.secondary)
            leftChip
            input
                .textFieldStyle(.plain)
                .font(.system(size: 22, design: .monospaced))
                .autocorrectionDisabled()
                .focused($focused)
                .onChange(of: model.text) { model.textChanged() }
                .onKeyPress(keys: [.return], phases: .down) { press in
                    if press.modifiers.contains(.command) { model.submit(.terminal) }
                    else if press.modifiers.contains(.option) { model.submit(.watch) }
                    else if press.modifiers.contains(.shift) { model.submit(.force) }
                    else { model.submit(.normal) }
                    return .handled
                }
                .onKeyPress(.tab) { model.tab(); return .handled }
                .onKeyPress(.upArrow) { model.arrow(-1); return .handled }
                .onKeyPress(.downArrow) { model.arrow(1); return .handled }
                .onExitCommand { model.escape() }
            indicator
            Button { model.pinned.toggle() } label: {
                Image(systemName: model.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(model.pinned ? Color.accentColor : .secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help(model.pinned ? "Unpin (⌘P): close when you click elsewhere" : "Pin (⌘P): stay open and on top")
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
    }

    /// A secret is typed into a field that hides it.
    @ViewBuilder private var input: some View {
        if model.prompt?.current.kind == .secret {
            SecureField(model.placeholder, text: $model.text)
        } else {
            TextField(model.placeholder, text: $model.text)
        }
    }

    private var choiceList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(model.choices.enumerated()), id: \.offset) { i, option in
                Text(option)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(i == model.choiceIndex ? Color.accentColor.opacity(0.22) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
            }
            Text("⏎ choose   ↑↓ move   type to narrow   esc cancel")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .font(.system(size: 13, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var leftChip: some View {
        if let p = model.prompt {
            Text("\(p.current.shortLabel) \(p.progress)")
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.blue)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .help("Snippet needs a value for \(p.current.label). Return accepts, Esc cancels.")
        } else if !model.searching {
            Text(model.cwdLabel)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: 200, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                .help(model.cwd)
            if !model.files.isEmpty {
                Label(model.files.count == 1 ? (model.files[0] as NSString).lastPathComponent : "\(model.files.count) files",
                      systemImage: "doc.on.doc")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.blue)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                    .help(model.files.joined(separator: "\n") + "\n\nThey fill a snippet's {files}, or go at the end of a command. Esc removes them.")
            }
        }
    }

    private var searchResults: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.matches.isEmpty {
                Text("No matching commands").foregroundStyle(.secondary).padding(.vertical, 4)
            }
            ForEach(Array(model.matches.enumerated()), id: \.offset) { i, cmd in
                Text(cmd)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(i == model.matchIndex ? Color.accentColor.opacity(0.22) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
            }
            Text("⏎ run   ⇥ edit   ↑↓ choose   ⌃R next   esc back")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .font(.system(size: 13, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var completionList: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], alignment: .leading, spacing: 4) {
                ForEach(model.completions, id: \.self) { c in
                    Text(c).lineLimit(1).truncationMode(.middle)
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .frame(maxHeight: 110)
    }

    private func messageView(_ m: LauncherModel.Message) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(m.title).foregroundStyle(.orange)
            Text(m.detail).foregroundStyle(.secondary)
        }
        .font(.system(size: 12.5, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var keyHints: some View {
        Text("⏎ run   ⇧⏎ force   ⌘⏎ Terminal   ⌥⏎ watch   ⇥ complete   ⌃R search   ⌘P pin   esc close")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
    }

    @ViewBuilder private var indicator: some View {
        if model.searching {
            Text("\(model.matches.count) matches").font(.caption).foregroundStyle(.secondary)
        } else if model.prompt != nil {
            EmptyView()
        } else {
            switch model.check {
            case nil:
                EmptyView()
            case .valid(let info):
                dot(.green, label: info.hasPrefix("snippet") ? info : nil, help: info)
            case .interactive(let info):
                dot(.blue, label: "opens in Terminal", help: info)
            case .needs(let fields):
                dot(.blue, label: "asks for " + fields.map(\.label).joined(separator: " "),
                    help: "Return asks for each value (secrets come from the Keychain when they are there)")
            case .invalid(let info):
                dot(.orange, label: info, help: info)
            }
        }
    }

    private func dot(_ color: Color, label: String?, help: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            if let label {
                Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .frame(maxWidth: 220, alignment: .leading)
            }
        }
        .help(help)
    }
}

/// Header (command, timer or status, action buttons) and streamed output for one job.
struct JobOutputView: View {
    @ObservedObject var job: Job
    @ObservedObject var model: LauncherModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("$ \(job.command)").lineLimit(1).truncationMode(.tail)
                Spacer()
                if let f = model.flash {
                    Text(f).foregroundStyle(.green)
                } else if let every = job.watchEvery, job.running {
                    Text("every \(Int(every))s · run \(job.runs)\(job.status.isEmpty ? "" : " · " + job.status) · Esc stops")
                        .foregroundStyle(job.status.hasPrefix("✗") ? .orange : .secondary)
                } else if job.running {
                    TimelineView(.periodic(from: job.startedAt, by: 1)) { ctx in
                        Text("\(job.elapsedText(now: ctx.date)) · Esc cancels")
                    }
                } else {
                    Text(job.status).foregroundStyle(job.succeeded ? .green : .orange)
                }
                actions
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if !job.output.isEmpty || job.trimmedFront {
                ScrollView { outputText }
                    .defaultScrollAnchor(.top, for: .alignment)
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    .defaultScrollAnchor(.bottom, for: .sizeChanges)
                    .frame(maxHeight: .infinity)
            } else {
                Spacer().frame(height: 6)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            iconButton("doc.on.doc", help: "Copy all output (⇧⌘C)") { model.copyOutput() }
            iconButton("arrow.clockwise", help: "Run again (⌘R)") { model.rerun() }
            iconButton("doc.text.magnifyingglass", help: "Open full log (⌘L)") { model.openLog() }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 22, height: 20)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private var outputText: some View {
        VStack(alignment: .leading, spacing: 4) {
            if job.trimmedFront {
                Text("… earlier lines are in the full log (⌘L)").foregroundStyle(.tertiary)
            }
            Text(job.rendered)
        }
        .font(.system(size: 12.5, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }
}

/// Global hotkey via Carbon. Needs no Accessibility permission.
/// The event handler is installed once; register/unregister can be called any time.
final class HotKey {
    var action: (() -> Void)? {
        didSet { HotKey.current = action }
    }
    private static var current: (() -> Void)?
    private static var handlerInstalled = false
    private var ref: EventHotKeyRef?

    init() {
        guard !HotKey.handlerInstalled else { return }
        HotKey.handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.current?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    func register(keyCode: UInt32, modifiers: UInt32) -> Bool {
        unregister()
        let id = EventHotKeyID(signature: OSType(0x544D_4754), id: 1)  // 'TMGT'
        return RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    deinit { unregister() }
}
