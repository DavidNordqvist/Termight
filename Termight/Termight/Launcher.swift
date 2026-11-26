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
//   ↑ / ↓         history, showing each command's last output when it's kept
//   ⌃R            search history
//   ⇧⌘C ⌘R ⌘L     copy all output, rerun, open full log
//   ⌘F ⌘D ⌘K      find in the output, compare with the previous run, keep the output
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

    /// Restyles the shown output (the theme's colors changed).
    func restyle() { model.restyle() }

    /// Forget the saved position and size; the bar goes back to its default spot.
    func resetFrame() {
        for key in [Prefs.winX, Prefs.winTop, Prefs.winW, Prefs.winH] { Prefs.d.removeObject(forKey: key) }
        WindowTiling.forgetUntiledSize()  // the reset size is the bar's own now
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
        var size = savedSize
        var topLeft: NSPoint?
        if Prefs.d.object(forKey: Prefs.winX) != nil {
            let p = NSPoint(x: Prefs.d.double(forKey: Prefs.winX), y: Prefs.d.double(forKey: Prefs.winTop))
            let grab = NSRect(x: p.x, y: p.y - 40, width: min(size.width, 200), height: 40)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(grab) }) { topLeft = p }
        }
        if topLeft == nil {
            // Away from any edge now (its display is gone, or this is a reset):
            // a tiled bar takes back its earlier size.
            if let untiled = WindowTiling.untiledSize {
                size = untiled
                WindowTiling.forgetUntiledSize()
                // Saved, so the next open uses it too. The position isn't: the
                // default spot follows the pointer's screen, and the old one
                // works again if its display comes back.
                Prefs.d.set(size.width, forKey: Prefs.winW)
                Prefs.d.set(size.height, forKey: Prefs.winH)
            }
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
                   // Resizable so macOS's own window tiling can size it too.
                   styleMask: [.borderless, .nonactivatingPanel, .resizable],
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
        WindowTiling.forgetUntiledSize()  // resized by hand: no longer tiled
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
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            let start = WindowTiling.DragStart(frame: window.frame, pointer: NSEvent.mouseLocation)
            window.performDrag(with: event)
            WindowTiling.dragEnded(window, from: start)
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

/// macOS shows its tiling preview while the bar is dragged to a screen edge,
/// but only tiles ordinary titled windows, not a borderless panel like the
/// bar. So when a drag ends where the preview appears, the bar takes that
/// frame itself: left or right edge, half the screen; a corner, a quarter; the
/// top edge, the whole screen. It follows System Settings: nothing when
/// "Drag windows to screen edges to tile" is off, and margins when "Tiled
/// windows have margins" is on.
@MainActor
enum WindowTiling {
    /// How close to an edge the pointer must be, and how far along it a corner reaches.
    static let edge: CGFloat = 4
    static let corner: CGFloat = 60
    static let margin: CGFloat = 8

    private static var settings: UserDefaults? { UserDefaults(suiteName: "com.apple.WindowManager") }
    static var enabled: Bool { settings?.object(forKey: "EnableTilingByEdgeDrag") as? Bool ?? true }
    static var margins: Bool { settings?.object(forKey: "EnableTiledWindowMargins") as? Bool ?? true }

    /// Where a drag began: the window's frame and the pointer.
    struct DragStart {
        let frame: NSRect
        let pointer: NSPoint
    }

    /// The size the bar had before it was tiled, kept (across launches too)
    /// so pulling it off the edge gives that size back, as macOS does.
    static var untiledSize: NSSize? {
        let w = Prefs.d.double(forKey: Prefs.untiledW), h = Prefs.d.double(forKey: Prefs.untiledH)
        return w > 0 && h > 0 ? NSSize(width: w, height: h) : nil
    }

    static func forgetUntiledSize() {
        Prefs.d.removeObject(forKey: Prefs.untiledW)
        Prefs.d.removeObject(forKey: Prefs.untiledH)
    }

    private static func rememberUntiledSize(_ size: NSSize) {
        guard untiledSize == nil else { return }  // tiled again: keep the original size
        Prefs.d.set(size.width, forKey: Prefs.untiledW)
        Prefs.d.set(size.height, forKey: Prefs.untiledH)
    }

    /// Waits for the mouse button to come up (the drag may run on after
    /// performDrag returns), then tiles at an edge, or gives a tiled bar its
    /// earlier size back when it's pulled off. A click that didn't move the
    /// bar does neither.
    static func dragEnded(_ window: NSWindow, from start: DragStart) {
        let finish = {
            let end = NSEvent.mouseLocation
            let moved = hypot(end.x - start.pointer.x, end.y - start.pointer.y) > 3
                || window.frame.origin != start.frame.origin
            guard moved else { return }
            if enabled, tile(window, at: end, sizeBefore: start.frame.size) { return }
            untile(window, under: end, from: start)
        }
        if NSEvent.pressedMouseButtons & 1 == 0 {
            finish()
            return
        }
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            timer.invalidate()
            MainActor.assumeIsolated { finish() }
        }
    }

    /// Tiles if `point` is at a screen's outer edge; true if it did.
    @discardableResult
    static func tile(_ window: NSWindow, at point: NSPoint, sizeBefore: NSSize) -> Bool {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) else { return false }
        let others = NSScreen.screens.filter { $0 !== screen }.map(\.frame)
        guard let target = frame(for: point, screen: screen.frame, visible: screen.visibleFrame, others: others)
        else { return false }
        rememberUntiledSize(sizeBefore)
        window.setFrame(target, display: true, animate: true)
        // macOS may still move the window to its preview afterwards without
        // resizing it; put the tiled frame back if that happened.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let f = window.frame
            guard abs(f.width - target.width) > 2 || abs(f.height - target.height) > 2
                    || abs(f.minX - target.minX) > 2 || abs(f.minY - target.minY) > 2 else { return }
            window.setFrame(target, display: true, animate: true)
        }
        return true
    }

    /// A tiled bar dragged away from the edges takes its earlier size, placed
    /// so the pointer holds the same spot on it.
    private static func untile(_ window: NSWindow, under point: NSPoint, from start: DragStart) {
        guard let size = untiledSize else { return }
        forgetUntiledSize()
        let f = window.frame
        let fx = (start.pointer.x - start.frame.minX) / max(start.frame.width, 1)
        let fromTop = start.frame.maxY - start.pointer.y
        var target = NSRect(x: point.x - fx * size.width, y: point.y + min(fromTop, size.height - 10) - size.height,
                            width: size.width, height: size.height)
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            target.origin.x = min(max(target.minX, visible.minX), visible.maxX - target.width)
            target.origin.y = min(max(target.minY, visible.minY), visible.maxY - target.height)
        }
        if f != target { window.setFrame(target, display: true, animate: true) }
    }

    /// The tiled frame for a drag released at `point`, or nil away from the
    /// edges. An edge shared with another display (`others`) is not one: the
    /// pointer is just crossing over.
    static func frame(for point: NSPoint, screen: NSRect, visible: NSRect, others: [NSRect] = []) -> NSRect? {
        let beyond = { (p: NSPoint) in others.contains { NSMouseInRect(p, $0, false) } }
        let reach = edge + 4
        let left = point.x <= screen.minX + edge && !beyond(NSPoint(x: screen.minX - reach, y: point.y))
        let right = point.x >= screen.maxX - edge - 1 && !beyond(NSPoint(x: screen.maxX + reach, y: point.y))
        let top = point.y >= screen.maxY - edge - 1 && !beyond(NSPoint(x: point.x, y: screen.maxY + reach))
        let nearTop = point.y >= screen.maxY - corner, nearBottom = point.y <= screen.minY + corner
        let nearLeft = point.x <= screen.minX + corner, nearRight = point.x >= screen.maxX - corner
        let v = visible
        let halfW = v.width / 2, halfH = v.height / 2
        var f: NSRect
        switch true {
        case (left && nearTop) || (top && nearLeft): f = NSRect(x: v.minX, y: v.midY, width: halfW, height: halfH)
        case (right && nearTop) || (top && nearRight): f = NSRect(x: v.midX, y: v.midY, width: halfW, height: halfH)
        case left && nearBottom: f = NSRect(x: v.minX, y: v.minY, width: halfW, height: halfH)
        case right && nearBottom: f = NSRect(x: v.midX, y: v.minY, width: halfW, height: halfH)
        case left: f = NSRect(x: v.minX, y: v.minY, width: halfW, height: v.height)
        case right: f = NSRect(x: v.midX, y: v.minY, width: halfW, height: v.height)
        case top: f = v
        default: return nil
        }
        return margins ? f.insetBy(dx: margin / 2, dy: margin / 2) : f
    }
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
    @Published private(set) var job: Job? {
        didSet {
            job?.loadSavedOutput()
            job?.ensureRendered()
            if job !== oldValue {
                comparison = nil
                if finding { updateFind() }
            }
        }
    }

    /// ⌘D: the shown job against an earlier run of the same command.
    struct Comparison {
        var with: Job
        var changed: Set<Int>
        var removed: Int
    }

    @Published private(set) var comparison: Comparison?
    /// ⌘F: finding text in the shown output; the matching lines and the current one.
    @Published private(set) var finding = false
    @Published private(set) var findLines: [Int] = []
    @Published private(set) var findIndex = 0
    private var textBeforeFind = ""
    /// Commands in the ⌃R list that matched in their kept output, not their text.
    @Published private(set) var outputMatches: Set<String> = []

    /// The text to pick out in the shown output while searching or finding.
    var markTerm: String? {
        guard searching || finding else { return nil }
        let q = finding ? text : text.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? nil : q
    }
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
    /// What was shown before ↑↓ or ⌃R started showing past commands' output.
    private var shownBeforeBrowsing: (job: Job?, message: Message?)?

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
        if finding { return "Find in output…" }
        if searching { return "Search history and output…" }
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
        finding = false
        findLines = []
        shownBeforeBrowsing = nil
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
            if !searching { shownBeforeBrowsing = nil }  // typing keeps what's shown
        }
        programmaticText = nil
        if finding {
            updateFind()
            return
        }
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
        if finding {
            moveFind(1)
            return
        }
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
        shownBeforeBrowsing = nil
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
        if finding {
            exitFind()
        } else if searching {
            exitSearch(restore: true)
        } else if prompt != nil {
            prompt = nil
            setText("")
        } else if shownBeforeBrowsing != nil {
            // Browsing history: Esc goes back, and never cancels a job it shows.
            historyIndex = nil
            setText("")
            endBrowsing(restore: true)
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

    /// ⌘K: keep the shown output so newer runs never push it out.
    func toggleKeep() {
        guard let j = job else { return }
        guard !j.running else { showFlash("Keep it once it finishes"); return }
        if AppState.shared.jobs.toggleKept(j) {
            showFlash(j.kept ? "Kept" : "No longer kept")
        } else {
            showFlash("Up to \(JobStore.maxKept) outputs can be kept")
        }
    }

    /// ⌘D: mark what changed since the previous kept run of the same command.
    func toggleCompare() {
        guard let j = job else { return }
        if comparison != nil {
            comparison = nil
            return
        }
        guard !j.running else { showFlash("Compare once it finishes"); return }
        let all = AppState.shared.jobs.jobs
        guard let i = all.firstIndex(where: { $0 === j }),
              let older = all[(i + 1)...].first(where: { $0.command == j.command && !$0.running })
        else {
            showFlash("No earlier run of this command is kept")
            return
        }
        older.loadSavedOutput()
        let r = LineDiff.compare(Ansi.plainLines(older.output), Ansi.plainLines(j.output))
        comparison = Comparison(with: older, changed: r.changed, removed: r.removed)
    }

    // MARK: Find in output (⌘F)

    func toggleFind() {
        if finding {
            exitFind()
            return
        }
        guard job != nil, !searching, prompt == nil else { return }
        textBeforeFind = text
        finding = true
        completions = []
        setText("")
        updateFind()
    }

    private func updateFind() {
        guard let j = job, !text.isEmpty else {
            findLines = []
            return
        }
        let q = text
        findLines = Ansi.plainLines(j.output).enumerated().compactMap { i, line in
            line.localizedCaseInsensitiveContains(q) ? i : nil
        }
        findIndex = 0
    }

    private func moveFind(_ delta: Int) {
        guard !findLines.isEmpty else { NSSound.beep(); return }
        findIndex = (findIndex + delta + findLines.count) % findLines.count
    }

    private func exitFind() {
        finding = false
        findLines = []
        setText(textBeforeFind)
    }

    /// A line under the output's header: where find is, or what a comparison shows.
    var outputNote: String? {
        if finding {
            if text.isEmpty { return "Type to find · Return or ↓ next · ↑ previous · Esc ends" }
            if findLines.isEmpty { return "No matches" }
            return "Match \(findIndex + 1) of \(findLines.count) · Return or ↓ next · ↑ previous · Esc ends"
        }
        if let c = comparison {
            let when = c.with.finishedAt.map { $0.formatted(.relative(presentation: .named)) } ?? "earlier"
            let changed = c.changed.count == 1 ? "1 line" : "\(c.changed.count) lines"
            return "Compared with the run \(when): \(changed) new or changed, \(c.removed) removed · ⌘D hides"
        }
        return nil
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
            previewMatch()
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

    /// Commands whose text matches, newest first, then commands whose kept
    /// output matches ("which run printed that?").
    private func updateMatches() {
        let q = text.trimmingCharacters(in: .whitespaces)
        var found: [String] = []
        for cmd in history.reversed() where q.isEmpty || cmd.localizedCaseInsensitiveContains(q) {
            found.append(cmd)
            if found.count == 8 { break }
        }
        matches = found
        outputMatches = []
        matchIndex = 0
        previewMatch()
        searchOutput(for: q, after: found)
    }

    private var outputSearch: Task<Void, Never>?

    /// Adds commands whose kept output contains `q`. The search runs off the
    /// main thread (up to 100 outputs, ~10 MB), so typing never waits for it;
    /// a newer keystroke cancels it.
    private func searchOutput(for q: String, after found: [String]) {
        outputSearch?.cancel()
        guard !q.isEmpty else { return }
        var seen = Set(found)
        var candidates: [(command: String, text: String)] = []
        for j in AppState.shared.jobs.jobs where !j.running && seen.insert(j.command).inserted {
            j.loadSavedOutput()  // reads the log; styling waits until it's shown
            candidates.append((j.command, j.plainOutput))
        }
        outputSearch = Task {
            let hits = await Task.detached(priority: .userInitiated) {
                candidates.filter { $0.text.localizedCaseInsensitiveContains(q) }.map(\.command)
            }.value
            guard !Task.isCancelled, searching, text.trimmingCharacters(in: .whitespaces) == q else { return }
            let extra = Array(hits.prefix(max(12 - matches.count, 0)))
            guard !extra.isEmpty else { return }
            matches += extra
            outputMatches = Set(extra)
            if matches.count == extra.count { previewMatch() }  // nothing matched by name: show the first
        }
    }

    func moveMatch(_ delta: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = min(max(matchIndex + delta, 0), matches.count - 1)
        previewMatch()
    }

    private func previewMatch() {
        if matches.indices.contains(matchIndex) {
            preview(matches[matchIndex], containing: text.trimmingCharacters(in: .whitespaces))
        } else {
            preview(nil)
        }
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
        endBrowsing(restore: restore)
    }

    // MARK: History and completion

    func arrow(_ delta: Int) {
        if finding {
            moveFind(delta)
        } else if searching {
            moveMatch(delta)  // ↑ moves up the list, showing that command's output
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
        preview(historyIndex.map { history[$0] })
    }

    /// The theme changed: style the shown output again with its colors.
    func restyle() { job?.ensureRendered() }

    // MARK: Past output

    /// Shows the newest kept output of `command` (this or an earlier launch)
    /// while stepping through history, without running anything. nil puts back
    /// what was shown before.
    private func preview(_ command: String?, containing term: String = "") {
        if shownBeforeBrowsing == nil { shownBeforeBrowsing = (job, message) }
        guard let command else {
            endBrowsing(restore: true)
            return
        }
        let jobs = AppState.shared.jobs.jobs
        // The newest run of it, or with a search term, the newest whose output has it.
        let withTerm = term.isEmpty ? nil : jobs.first { j in
            guard j.command == command else { return false }
            j.loadSavedOutput()
            return j.plainOutput.localizedCaseInsensitiveContains(term)
        }
        if let j = withTerm ?? jobs.first(where: { $0.command == command }) {
            job = j
            message = nil
        } else {
            job = nil
            message = Message(title: "No saved output for this command",
                              detail: "Return runs it again. Output is kept for the last \(JobStore.keep) commands.")
        }
    }

    private func endBrowsing(restore: Bool) {
        guard let before = shownBeforeBrowsing else { return }
        shownBeforeBrowsing = nil
        if restore {
            job = before.job
            message = before.message
        }
    }

    func tab() {
        if finding { return }
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
    @AppStorage(Prefs.windowStyle) private var windowStyle = "system"
    @AppStorage(Prefs.windowColor) private var windowColor = WindowLook.defaultColor
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(Prefs.windowText) private var textMode = "auto"
    @AppStorage(Prefs.windowTextColor) private var textColor = WindowLook.defaultTextColor
    @AppStorage(Prefs.windowTheme) private var themeID = "system"

    /// The theme's accent (pin, selected rows), or the system's.
    private var accent: Color { WindowTheme.find(themeID)?.accent.map(WindowLook.color) ?? .accentColor }

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
            if let job = model.job {
                Divider()
                JobOutputView(job: job, model: model)
            } else if let m = model.message {
                Divider()
                messageView(m)
            } else if model.completions.isEmpty && model.choices.isEmpty && !model.searching {
                keyHints
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WindowDragArea())
        .background(LauncherBackground())
        // On a custom color, text goes dark or light to stay readable.
        .environment(\.colorScheme, windowStyle == "custom"
                     ? (WindowLook.isLight(windowColor) ? .light : .dark) : colorScheme)
        // A chosen text color: the typed line and output without colors of its
        // own. Secondary text is the same color, fainter.
        .modifier(TextColor(color: textMode == "custom" ? WindowLook.color(textColor) : nil))
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
            Button("") { model.toggleFind() }.keyboardShortcut("f", modifiers: .command)
            Button("") { model.toggleCompare() }.keyboardShortcut("d", modifiers: .command)
            Button("") { model.toggleKeep() }.keyboardShortcut("k", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private var inputRow: some View {
        HStack(spacing: 10) {
            Group {
                if model.finding {
                    Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .medium))
                } else if model.searching {
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
                    .foregroundStyle(model.pinned ? accent : .secondary)
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
                    .background(i == model.choiceIndex ? accent.opacity(0.22) : .clear,
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
        } else if !model.searching && !model.finding {
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
                HStack {
                    Text(cmd)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    if model.outputMatches.contains(cmd) {
                        Text("in output").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(i == model.matchIndex ? accent.opacity(0.22) : .clear,
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
            Text(model.matches.count == 1 ? "1 match" : "\(model.matches.count) matches")
                .font(.caption).foregroundStyle(.secondary)
        } else if model.prompt != nil || model.finding {
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
                    Text(job.status + (job.finishedAgo.map { " · " + $0 } ?? "") + (job.kept ? " · kept" : ""))
                        .foregroundStyle(job.succeeded ? .green : .orange)
                }
                actions
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 6)

            if let note = model.outputNote, model.job === job {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 4)
            }

            if model.finding && model.job === job {
                findView
            } else if !job.output.isEmpty || job.trimmedFront {
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
            iconButton("magnifyingglass", help: "Find in the output (⌘F)") { model.toggleFind() }
            iconButton("arrow.left.arrow.right", help: "Compare with the previous run (⌘D)") { model.toggleCompare() }
            iconButton(job.kept ? "bookmark.fill" : "bookmark",
                       help: job.kept ? "Stop keeping this output (⌘K)" : "Keep this output (⌘K)") { model.toggleKeep() }
        }
    }

    /// The output as shown: compared lines tinted, a search term picked out.
    private var displayed: AttributedString {
        guard model.job === job else { return job.rendered }
        return job.marked(model.markTerm, highlight: model.comparison?.changed)
    }

    /// ⌘F: one view per line, so the current match can be scrolled to.
    private var findView: some View {
        let lines = Ansi.lines(job.output)
        let current = model.findLines.indices.contains(model.findIndex) ? model.findLines[model.findIndex] : nil
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        Text(Ansi.renderLine(line, highlight: i == current, mark: model.markTerm))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }
                .font(.system(size: 12.5, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            }
            .frame(maxHeight: .infinity)
            .onChange(of: current) { _, line in
                if let line { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(line, anchor: .center) } }
            }
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
            Text(displayed)
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

/// The bar's background, from Settings → General → Window: the system's look
/// or a color of your choice, at an opacity, with or without blur.
///
/// Opacity sets how much of what's behind the bar shows through: it thins the
/// frost as well as the color, so the slider always visibly does something.
/// With a color, the frost follows the bar's color scheme (which follows the
/// text), so dark text gets a light frost and the reverse.
struct LauncherBackground: View {
    @AppStorage(Prefs.windowStyle) private var style = "system"
    @AppStorage(Prefs.windowColor) private var color = WindowLook.defaultColor
    @AppStorage(Prefs.windowOpacity) private var opacity = 1.0
    @AppStorage(Prefs.windowBlur) private var blur = true

    var body: some View {
        ZStack {
            if blur { Frost(opacity: opacity) }
            if style == "custom" {
                Rectangle().fill(WindowLook.color(color).opacity(opacity))
            } else if !blur {
                Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(opacity))
            }
        }
    }
}

/// Frost that thins with opacity: the usual material at 100%, only a faint
/// one at the lowest setting.
struct Frost: View {
    let opacity: Double

    var body: some View {
        let t = min(max((opacity - WindowLook.minOpacity) / (1 - WindowLook.minOpacity), 0), 1)
        if t >= 0.999 {
            Rectangle().fill(.regularMaterial)
        } else {
            ZStack {
                Rectangle().fill(.ultraThinMaterial.opacity(0.4 + 0.6 * t))
                Rectangle().fill(.regularMaterial.opacity(t))
            }
        }
    }
}

/// Sets the default text color when one is chosen; otherwise leaves the system's.
struct TextColor: ViewModifier {
    let color: Color?

    func body(content: Content) -> some View {
        if let color { content.foregroundStyle(color) } else { content }
    }
}

/// A window color stored as "r g b" (0–1, sRGB), so it survives in UserDefaults.
enum WindowLook {
    static let defaultColor = "0.11 0.12 0.15"
    /// Contrast body text needs (WCAG AA).
    static let readable = 4.5

    /// The text color on a custom `color`: the chosen one, or Automatic's
    /// black or white, whichever reads better.
    static func text(on color: String, custom: String?) -> String {
        custom ?? (isLight(color) ? "0 0 0" : "1 1 1")
    }

    /// Whether `text` keeps readable contrast on `color` at `opacity` over both
    /// extremes, a black and a white desktop, so over any desktop in between.
    /// Settings warns when it doesn't; nothing is forced.
    static func readableOverAnyDesktop(color: String, opacity: Double, text: String) -> Bool {
        let (r, g, b) = components(color)
        return [0.0, 1.0].allSatisfy { desk in
            let mix = { (c: Double) in c * opacity + desk * (1 - opacity) }
            return contrast(String(format: "%f %f %f", mix(r), mix(g), mix(b)), text) >= readable
        }
    }

    /// Roughly the System look's own color in the current appearance, for the
    /// readability estimate.
    static var systemColor: String {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "0.15 0.15 0.16" : "0.93 0.93 0.93"
    }
    static let defaultTextColor = "0.90 0.90 0.88"
    static let minOpacity = 0.3

    static func components(_ s: String) -> (Double, Double, Double) {
        let v = s.split(separator: " ").compactMap { Double($0) }.filter(\.isFinite).map { min(max($0, 0), 1) }
        return v.count == 3 ? (v[0], v[1], v[2]) : (0.11, 0.12, 0.15)
    }

    static func color(_ s: String) -> Color {
        let (r, g, b) = components(s)
        return Color(.sRGB, red: r, green: g, blue: b)
    }

    static func encode(_ c: Color) -> String {
        let ns = NSColor(c).usingColorSpace(.sRGB) ?? .black
        return String(format: "%.3f %.3f %.3f", ns.redComponent, ns.greenComponent, ns.blueComponent)
    }

    /// Relative luminance (WCAG), 0 for black to 1 for white.
    static func luminance(_ s: String) -> Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (r, g, b) = components(s)
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    /// Dark text reads better on it than light text. Black and white text have
    /// equal contrast at a luminance of about 0.179, so that is the cut.
    static func isLight(_ s: String) -> Bool { luminance(s) > 0.179 }

    /// WCAG contrast ratio between two colors, 1 to 21.
    static func contrast(_ a: String, _ b: String) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

/// A named look for the bar: background, text, accent and, for some, the
/// colors of command output. Picking one writes the window settings it
/// stands for; "Custom" leaves them to the detailed controls.
struct WindowTheme: Identifiable {
    let id: String
    let name: String
    /// nil: the System look.
    let background: String?
    /// nil: Automatic text.
    let text: String?
    let accent: String?
    /// The 16 basic terminal colors as "r g b", or nil for the system's.
    let palette: [String]?

    static let all: [WindowTheme] = [
        WindowTheme(id: "system", name: "System", background: nil, text: nil, accent: nil, palette: nil),
        WindowTheme(id: "amber", name: "Amber", background: "0.110 0.102 0.086", text: "1.000 0.749 0.302",
                    accent: "1.000 0.749 0.302", palette: nil),
        WindowTheme(id: "phosphor", name: "Phosphor", background: "0.059 0.102 0.071", text: "0.369 0.941 0.541",
                    accent: "0.369 0.941 0.541", palette: nil),
        // Bright green on pure black, and every output color a shade of green.
        WindowTheme(id: "matrix", name: "Matrix", background: "0.000 0.000 0.000", text: "0.000 1.000 0.255",
                    accent: "0.000 1.000 0.255", palette: [
                        "0.000 0.400 0.100", "0.000 0.700 0.180", "0.000 1.000 0.255", "0.600 1.000 0.500",
                        "0.000 0.600 0.200", "0.200 0.850 0.350", "0.400 1.000 0.550", "0.700 1.000 0.750",
                        "0.000 0.620 0.170", "0.150 0.900 0.300", "0.300 1.000 0.400", "0.800 1.000 0.700",
                        "0.100 0.750 0.300", "0.350 0.950 0.500", "0.550 1.000 0.700", "0.850 1.000 0.880",
                    ]),
        // Dark inks on cream: every output color reads at 4.5:1 or better.
        WindowTheme(id: "paper", name: "Paper", background: "0.965 0.945 0.890", text: "0.169 0.149 0.125",
                    accent: "0.560 0.280 0.050", palette: [
                        "0.150 0.130 0.110", "0.680 0.100 0.100", "0.100 0.420 0.150", "0.520 0.340 0.000",
                        "0.100 0.280 0.660", "0.520 0.140 0.520", "0.000 0.400 0.460", "0.330 0.310 0.280",
                        "0.400 0.370 0.330", "0.780 0.150 0.120", "0.120 0.460 0.170", "0.560 0.380 0.000",
                        "0.150 0.330 0.720", "0.580 0.180 0.580", "0.000 0.440 0.500", "0.250 0.230 0.200",
                    ]),
        WindowTheme(id: "midnight", name: "Midnight", background: "0.078 0.137 0.247", text: "0.859 0.906 1.000",
                    accent: "0.357 0.608 1.000", palette: nil),
        // The seasons. Winter and Spring are light, so their output colors are
        // dark inks; Summer and Fall are dark, with bright ones.
        WindowTheme(id: "winter", name: "Winter", background: "0.918 0.949 0.973", text: "0.106 0.165 0.255",
                    accent: "0.180 0.400 0.650", palette: [
                        "0.106 0.165 0.255", "0.690 0.130 0.200", "0.090 0.420 0.330", "0.480 0.360 0.050",
                        "0.120 0.300 0.620", "0.430 0.200 0.600", "0.000 0.380 0.500", "0.300 0.340 0.400",
                        "0.380 0.420 0.480", "0.760 0.180 0.250", "0.120 0.460 0.360", "0.540 0.400 0.060",
                        "0.160 0.340 0.680", "0.480 0.240 0.660", "0.000 0.420 0.540", "0.200 0.240 0.300",
                    ]),
        WindowTheme(id: "spring", name: "Spring", background: "0.953 0.973 0.937", text: "0.137 0.212 0.122",
                    accent: "0.700 0.200 0.420", palette: [
                        "0.137 0.212 0.122", "0.720 0.150 0.250", "0.150 0.430 0.150", "0.500 0.380 0.000",
                        "0.150 0.320 0.620", "0.640 0.180 0.450", "0.050 0.400 0.400", "0.320 0.360 0.300",
                        "0.400 0.440 0.380", "0.780 0.200 0.300", "0.180 0.470 0.180", "0.550 0.410 0.000",
                        "0.180 0.360 0.680", "0.700 0.220 0.500", "0.060 0.440 0.440", "0.220 0.260 0.200",
                    ]),
        WindowTheme(id: "summer", name: "Summer", background: "0.043 0.227 0.290", text: "1.000 0.910 0.640",
                    accent: "1.000 0.478 0.349", palette: [
                        "0.250 0.500 0.550", "1.000 0.478 0.349", "0.400 0.950 0.600", "1.000 0.850 0.300",
                        "0.450 0.800 1.000", "1.000 0.550 0.800", "0.300 0.950 0.950", "0.950 0.950 0.900",
                        "0.550 0.750 0.780", "1.000 0.600 0.500", "0.550 1.000 0.700", "1.000 0.920 0.500",
                        "0.600 0.880 1.000", "1.000 0.700 0.880", "0.550 1.000 1.000", "1.000 1.000 1.000",
                    ]),
        WindowTheme(id: "fall", name: "Fall", background: "0.165 0.102 0.063", text: "0.953 0.851 0.694",
                    accent: "0.910 0.467 0.180", palette: [
                        "0.470 0.350 0.260", "0.900 0.400 0.300", "0.650 0.750 0.300", "0.950 0.750 0.250",
                        "0.550 0.650 0.900", "0.900 0.450 0.550", "0.450 0.750 0.650", "0.900 0.850 0.780",
                        "0.650 0.560 0.480", "1.000 0.500 0.380", "0.750 0.850 0.400", "1.000 0.820 0.350",
                        "0.650 0.750 1.000", "1.000 0.580 0.650", "0.550 0.850 0.750", "1.000 0.960 0.900",
                    ]),
        // Neon on near-black violet: hot pink, electric cyan and acid yellow.
        WindowTheme(id: "cyberpunk", name: "Cyberpunk", background: "0.051 0.008 0.129", text: "0.176 0.886 0.902",
                    accent: "1.000 0.165 0.427", palette: [
                        "0.400 0.300 0.550", "1.000 0.165 0.427", "0.224 1.000 0.533", "0.976 0.973 0.443",
                        "0.400 0.500 1.000", "1.000 0.165 0.831", "0.176 0.886 0.902", "0.910 0.902 1.000",
                        "0.600 0.520 0.780", "1.000 0.400 0.600", "0.500 1.000 0.700", "1.000 1.000 0.650",
                        "0.600 0.680 1.000", "1.000 0.450 0.900", "0.550 0.960 1.000", "1.000 1.000 1.000",
                    ]),
    ]

    static func find(_ id: String) -> WindowTheme? { all.first { $0.id == id } }

    /// Every theme's colors against its own background: text and accent at
    /// 4.5:1 or more, each palette entry at 4.5:1 except entry 0 ("black",
    /// meant to look dim on a dark theme) at 2.5:1, and 16 entries. Returns
    /// what falls short; debug builds stop on it at launch.
    static func contrastProblems() -> [String] {
        var out: [String] = []
        for t in all {
            guard let bg = t.background else { continue }
            let check = { (what: String, color: String, minimum: Double) in
                let ratio = WindowLook.contrast(color, bg)
                if ratio < minimum { out.append(String(format: "%@ %@: %.1f:1 (needs %.1f)", t.name, what, ratio, minimum)) }
            }
            if let text = t.text { check("text", text, WindowLook.readable) }
            if let accent = t.accent { check("accent", accent, WindowLook.readable) }
            if let p = t.palette {
                if p.count != 16 { out.append("\(t.name) palette has \(p.count) entries, not 16") }
                for (i, c) in p.enumerated() { check("palette \(i)", c, i == 0 ? 2.5 : WindowLook.readable) }
            }
        }
        return out
    }

    /// Makes `id` the current theme: writes its settings (not for "custom")
    /// and sets the output palette.
    @MainActor static func select(_ id: String) {
        Prefs.d.set(id, forKey: Prefs.windowTheme)
        if let t = find(id) {
            Prefs.d.set(t.background == nil ? "system" : "custom", forKey: Prefs.windowStyle)
            if let bg = t.background { Prefs.d.set(bg, forKey: Prefs.windowColor) }
            Prefs.d.set(t.text == nil ? "auto" : "custom", forKey: Prefs.windowText)
            if let text = t.text { Prefs.d.set(text, forKey: Prefs.windowTextColor) }
        }
        apply()
    }

    /// Sets the output palette from the saved theme; at launch and on change.
    @MainActor static func apply() {
        assert(contrastProblems().isEmpty, "Theme contrast: \(contrastProblems().joined(separator: "; "))")
        let palette = find(Prefs.d.string(forKey: Prefs.windowTheme) ?? "system")?.palette
        Ansi.setPalette(palette?.map(WindowLook.color))
        AppState.shared.launcher.restyle()
    }
}
