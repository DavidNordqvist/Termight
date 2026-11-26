// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 David Nordqvist
//
// This file is part of Termight. Termight is free software: you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License, version 3, as published by the Free Software Foundation. It comes
// with no warranty. See the LICENSE file for the full text.

import AppKit
import Foundation
import Security
import SwiftUI
import UserNotifications

/// A published release that can replace this copy of Termight.
struct Release: Equatable, Sendable {
    let version: String  // "0.1.1"
    let notes: String
    let page: URL
    let dmg: URL
    let size: Int
}

struct UpdateFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Finding, checking and installing an update, with no UI. An update is
/// accepted only if Apple notarized it and it is signed with a Developer ID
/// from the same team that signed the running copy.
enum UpdateInstaller {
    static let feed = URL(string: "https://api.github.com/repos/DavidNordqvist/Termight/releases/latest")!
    static let bundleID = "ca.nordqvist.termight"
    static let maxSize = 200 * 1024 * 1024

    // MARK: Versions

    /// Dotted numbers only ("0.1.10"); nil for anything else.
    static func numbers(_ v: String) -> [Int]? {
        let parts = v.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var out: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 6, p.allSatisfy({ ("0"..."9").contains($0) }), let n = Int(p) else { return nil }
            out.append(n)
        }
        return out
    }

    static func isNewer(_ v: String, than current: String) -> Bool {
        guard let a = numbers(v), let b = numbers(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: Feed

    /// The release described by GitHub's "latest release" JSON. `localTest`
    /// lets the download be a file URL (a feed pointed at a local file).
    static func parse(_ data: Data, localTest: Bool = false) throws -> Release {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let size: Int
        }
        struct Feed: Decodable {
            let tag_name: String
            let html_url: URL
            let body: String?
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]
        }
        guard let f = try? JSONDecoder().decode(Feed.self, from: data) else {
            throw UpdateFailure("The release information could not be read.")
        }
        let version = f.tag_name.hasPrefix("v") ? String(f.tag_name.dropFirst()) : f.tag_name
        guard numbers(version) != nil else { throw UpdateFailure("The latest release has an unknown tag (\(f.tag_name)).") }
        guard f.draft != true, f.prerelease != true else { throw UpdateFailure("The latest release is not final.") }
        let name = "Termight-\(version).dmg"
        guard let asset = f.assets.first(where: { $0.name == name }) else {
            throw UpdateFailure("Release \(f.tag_name) has no \(name) to download.")
        }
        let scheme = asset.browser_download_url.scheme
        guard scheme == "https" || (localTest && asset.browser_download_url.isFileURL) else {
            throw UpdateFailure("The download link is not secure.")
        }
        guard asset.size > 0, asset.size <= maxSize else { throw UpdateFailure("The download has an unexpected size.") }
        return Release(version: version, notes: f.body ?? "", page: f.html_url, dmg: asset.browser_download_url, size: asset.size)
    }

    static func fetch(feed: URL, current: String) async throws -> Release {
        var req = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Termight/\(current)", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw UpdateFailure("Couldn't reach GitHub: \(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 404 { throw UpdateFailure("No published release was found.") }
            guard http.statusCode == 200 else { throw UpdateFailure("GitHub answered with status \(http.statusCode).") }
        }
        return try parse(data, localTest: feed.isFileURL)
    }

    // MARK: Signature

    /// The team that signed the running copy; nil for an ad-hoc or unsigned build.
    static func signingTeam() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String, isTeamID(team)
        else { return nil }
        return team
    }

    static func isTeamID(_ s: String) -> Bool {
        s.count == 10 && s.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }

    /// Throws unless `app` is a whole, notarized Termight newer than `current`,
    /// signed with a Developer ID certificate of `team`.
    static func verify(_ app: URL, team: String, version: String, current: String) throws {
        guard isTeamID(team) else { throw UpdateFailure("This copy's signing team is unknown.") }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateFailure("The download does not contain a readable app.")
        }
        // Developer ID application certificate (leaf OID ...6.1.13, issued by the
        // Developer ID CA ...6.2.6), from the same team, for this app.
        let text = """
            identifier "\(bundleID)" and anchor apple generic \
            and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
            and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
            and certificate leaf[subject.OU] = "\(team)"
            """
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateFailure("The signature requirement could not be built.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        var error: Unmanaged<CFError>?
        guard SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &error) == errSecSuccess else {
            let why = error?.takeRetainedValue().localizedDescription ?? "unknown reason"
            throw UpdateFailure("The download is not signed by Termight's developer (\(why)).")
        }
        // Notarized: ask Gatekeeper, as Finder would on first open.
        let assess = try run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
        guard assess.status == 0 else { throw UpdateFailure("Apple has not notarized the download.") }

        let plist = app.appending(path: "Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist),
              info["CFBundleIdentifier"] as? String == bundleID,
              let found = info["CFBundleShortVersionString"] as? String
        else { throw UpdateFailure("The download is not Termight.") }
        guard found == version else { throw UpdateFailure("The download is version \(found), not \(version).") }
        guard isNewer(found, than: current) else { throw UpdateFailure("The download is not newer than \(current).") }
    }

    // MARK: Install

    /// Downloads, mounts and checks the release, then copies its app into a
    /// private folder. Returns the copy, checked again, ready to swap in.
    static func prepare(_ r: Release, team: String, current: String) async throws -> URL {
        let work = FileManager.default.temporaryDirectory.appending(path: "termight-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            let dmg = work.appending(path: "Termight.dmg")
            let (downloaded, response) = try await URLSession.shared.download(from: r.dmg)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw UpdateFailure("The download failed with status \(http.statusCode).")
            }
            try FileManager.default.moveItem(at: downloaded, to: dmg)
            let size = (try? FileManager.default.attributesOfItem(atPath: dmg.path)[.size] as? Int) ?? -1
            guard size == r.size else { throw UpdateFailure("The download is incomplete.") }

            let mount = work.appending(path: "mount")
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false)
            let attach = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                                      "-mountpoint", mount.path, dmg.path])
            guard attach.status == 0 else { throw UpdateFailure("The disk image could not be opened.") }
            defer { _ = try? run("/usr/bin/hdiutil", ["detach", "-force", mount.path]) }

            let source = mount.appending(path: "Termight.app")
            try verify(source, team: team, version: r.version, current: current)
            let staged = work.appending(path: "Termight.app")
            let copy = try run("/usr/bin/ditto", [source.path, staged.path])
            guard copy.status == 0 else { throw UpdateFailure("The new app could not be copied.") }
            // What gets installed is the copy, so check the copy.
            try verify(staged, team: team, version: r.version, current: current)
            try? FileManager.default.removeItem(at: dmg)
            return staged
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    /// Can this process replace the app at `target`? (Not from a disk image,
    /// a translocated copy or a folder the user can't write to.)
    static func canReplace(_ target: URL) -> Bool {
        let fm = FileManager.default
        return target.pathExtension == "app"
            && fm.isWritableFile(atPath: target.deletingLastPathComponent().path)
            && fm.isWritableFile(atPath: target.path)
    }

    /// Starts a helper that waits for process `pid` to end, swaps `staged`
    /// in for `target` (putting the old app back if that fails) and opens it.
    static func install(staged: URL, over target: URL, pid: Int32, relaunch: Bool = true) throws {
        guard canReplace(target) else {
            throw UpdateFailure("Termight can't replace itself in \(target.deletingLastPathComponent().path). "
                                + "Move it to Applications, or install the update from the release page.")
        }
        let script = """
            pid=$1 new=$2 dest=$3 work=$4
            i=0
            while kill -0 "$pid" 2>/dev/null; do
              i=$((i + 1)); [ "$i" -gt 600 ] && exit 1
              sleep 0.1
            done
            old="$work/Termight-old.app"
            if mv "$dest" "$old"; then
              if mv "$new" "$dest"; then rm -rf "$work"; else rm -rf "$dest"; mv "$old" "$dest"; fi
            fi
            [ "$5" = 1 ] && /usr/bin/open "$dest"
            exit 0
            """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", String(pid), staged.path, target.path,
                       staged.deletingLastPathComponent().path, relaunch ? "1" : "0"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }

    @discardableResult
    static func run(_ exe: String, _ args: [String]) throws -> (status: Int32, output: String) {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

/// Update checks for the app: automatic once a day (if allowed) and on request,
/// with an alert to install and relaunch.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle, checking, upToDate, installing
        case available(Release)
        case failed(String)
    }

    @Published private(set) var state = State.idle
    private var timer: Timer?

    let team = UpdateInstaller.signingTeam()
    var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    /// Updates need a team signature to compare against; ad-hoc builds can't update.
    var supported: Bool { team != nil }

    var lastChecked: Date? { Prefs.d.object(forKey: Prefs.lastUpdateCheck) as? Date }

    /// Prefs.updateFeedURL points checks somewhere else (testing); not in the UI.
    private var feed: URL {
        if let s = Prefs.d.string(forKey: Prefs.updateFeedURL), let u = URL(string: s) { return u }
        return UpdateInstaller.feed
    }

    func start() {
        reportUnfinishedInstall()
        guard supported else { return }
        // Soon after launch, then hourly; each tick checks only if a day has passed.
        Task {
            try? await Task.sleep(for: .seconds(15))
            await checkIfDue()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in await Updater.shared.checkIfDue() }
        }
    }

    private func checkIfDue() async {
        guard Prefs.d.bool(forKey: Prefs.checkForUpdates) else { return }
        if let last = lastChecked, Date().timeIntervalSince(last) < 24 * 3600 { return }
        await check(userInitiated: false)
    }

    func check(userInitiated: Bool) async {
        if case .checking = state { return }
        if case .installing = state { return }
        guard let _ = team else {
            state = .failed("This copy isn't signed by a developer team, so updates can't be verified.")
            if userInitiated { alert("Can't check for updates", state.message) }
            return
        }
        state = .checking
        do {
            let r = try await UpdateInstaller.fetch(feed: feed, current: current)
            Prefs.d.set(Date(), forKey: Prefs.lastUpdateCheck)
            if UpdateInstaller.isNewer(r.version, than: current) {
                state = .available(r)
                if userInitiated { offer(r) } else { notify(r) }
            } else {
                state = .upToDate
                if userInitiated { alert("Termight is up to date", "Version \(current) is the latest.") }
            }
        } catch {
            state = .failed(error.localizedDescription)
            if userInitiated { alert("Can't check for updates", error.localizedDescription) }
        }
    }

    /// Asks whether to install `r` now.
    func offer(_ r: Release) {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "Termight \(r.version) is available"
        let notes = r.notes.count > 800 ? String(r.notes.prefix(800)) + "…" : r.notes
        a.informativeText = "You have \(current). Installing quits Termight and opens the new version."
            + (notes.isEmpty ? "" : "\n\n" + notes)
        a.addButton(withTitle: "Install and Relaunch")
        a.addButton(withTitle: "Release Notes")
        a.addButton(withTitle: "Later")
        switch a.runModal() {
        case .alertFirstButtonReturn: Task { await install(r) }
        case .alertSecondButtonReturn: NSWorkspace.shared.open(r.page)
        default: break
        }
    }

    func install(_ r: Release) async {
        guard let team else { return }
        let running = AppState.shared.jobs.runningCount
        if running > 0 {
            let a = NSAlert()
            a.messageText = running == 1 ? "A command is still running" : "\(running) commands are still running"
            a.informativeText = "Updating quits Termight, which stops them."
            a.addButton(withTitle: "Stop and Update")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        state = .installing
        let current = self.current
        do {
            let staged = try await Task.detached {
                try await UpdateInstaller.prepare(r, team: team, current: current)
            }.value
            try UpdateInstaller.install(staged: staged, over: Bundle.main.bundleURL, pid: getpid())
            Prefs.d.set(r.version, forKey: Prefs.pendingUpdate)
            NSApp.terminate(nil)
        } catch {
            state = .failed(error.localizedDescription)
            NSApp.activate()
            let a = NSAlert()
            a.messageText = "Couldn't install Termight \(r.version)"
            a.informativeText = error.localizedDescription
            a.addButton(withTitle: "Open Release Page")
            a.addButton(withTitle: "OK")
            if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(r.page) }
        }
    }

    /// The helper swaps the app after Termight quits, so a failure there is
    /// only visible at the next launch: still the old version.
    private func reportUnfinishedInstall() {
        guard let pending = Prefs.d.string(forKey: Prefs.pendingUpdate) else { return }
        Prefs.d.removeObject(forKey: Prefs.pendingUpdate)
        if UpdateInstaller.isNewer(pending, than: current) {
            state = .failed("Version \(pending) was downloaded but could not be installed.")
        }
    }

    /// A banner for an update found in the background, once per version.
    private func notify(_ r: Release) {
        guard Prefs.d.string(forKey: Prefs.notifiedUpdate) != r.version else { return }
        Prefs.d.set(r.version, forKey: Prefs.notifiedUpdate)
        let content = UNMutableNotificationContent()
        content.title = "Termight \(r.version) is available"
        content.body = "Click to install, or use Update in the menu bar."
        content.userInfo = [Self.notificationKey: r.version]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "update-\(r.version)", content: content, trigger: nil))
    }

    nonisolated static let notificationKey = "termightUpdate"

    private func alert(_ title: String, _ text: String) {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

extension Updater.State {
    var message: String {
        switch self {
        case .idle: ""
        case .checking: "Checking…"
        case .upToDate: "Up to date."
        case .installing: "Downloading and checking the update…"
        case .available(let r): "Version \(r.version) is available."
        case .failed(let why): why
        }
    }
}

/// "Check for Updates…" in the menu bar, or "Update to x.y.z…" once one is found.
struct UpdateMenuItem: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        if updater.supported {
            switch updater.state {
            case .available(let r):
                Button("Update to \(r.version)…") { updater.offer(r) }
            case .checking, .installing:
                Button(updater.state.message) {}.disabled(true)
            default:
                Button("Check for Updates…") { Task { await updater.check(userInitiated: true) } }
            }
        }
    }
}
