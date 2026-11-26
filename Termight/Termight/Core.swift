// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 David Nordqvist
//
// This file is part of Termight. Termight is free software: you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License, version 3, as published by the Free Software Foundation. It comes
// with no warranty. See the LICENSE file for the full text.

import Foundation

/// Thin bridge to the Rust core bundled at Contents/MacOS/termight-core.
enum Runner {
    struct Missing: Error, CustomLocalizedStringResourceConvertible {
        var localizedStringResource: LocalizedStringResource { "termight-core binary missing from app bundle" }
    }

    /// One unfilled snippet placeholder.
    struct SnippetField: Equatable {
        enum Kind: Equatable {
            case text, number, secret
            case choice([String])
        }

        var name: String
        var defaultValue: String?
        var kind: Kind = .text

        /// As written in the snippet: `{host}`, `{#port}`, `{env|dev|prod}`, `{!token}`.
        var label: String {
            switch kind {
            case .text: "{\(name)}"
            case .number: "{#\(name)}"
            case .secret: "{!\(name)}"
            case .choice(let options): "{\(name)|\(options.joined(separator: "|"))}"
            }
        }

        /// For the prompt's chip: a choice without its options.
        var shortLabel: String {
            if case .choice = kind { return "{\(name)}" }
            return label
        }

        /// One line of `--check` output: name, `=default` or empty, kind, choices.
        init(field line: Substring) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            name = parts[0]
            if parts.count > 1, parts[1].hasPrefix("=") { defaultValue = String(parts[1].dropFirst()) }
            switch parts.count > 2 ? parts[2] : "text" {
            case "number": kind = .number
            case "secret": kind = .secret
            case "choice": kind = .choice(Array(parts.dropFirst(3)))
            default: kind = .text
            }
        }

        init(name: String, defaultValue: String? = nil, kind: Kind = .text) {
            self.name = name
            self.defaultValue = defaultValue
            self.kind = kind
        }
    }

    enum Check: Equatable {
        case valid(String)
        case interactive(String)  // runnable, but needs a real terminal
        case needs([SnippetField])  // snippet with {placeholders} still to fill
        case invalid(String)
    }

    static var executable: URL? { Bundle.main.url(forAuxiliaryExecutable: "termight-core") }

    /// Settings every core call needs.
    static var baseEnvironment: [String: String] {
        ["TERMIGHT_RC": Prefs.d.bool(forKey: Prefs.loadShellRC) ? "1" : "0"]
    }

    /// The app's environment with `extra` on top, for a core process.
    static func processEnvironment(_ extra: [String: String]) -> [String: String] {
        ProcessInfo.processInfo.environment.merging(extra) { $1 }
    }

    /// A core process with the base settings and `extra`; nil if the core is missing.
    private static func core(_ arguments: [String], _ extra: [String: String] = [:]) -> CoreRun? {
        try? CoreRun(arguments: arguments, environment: baseEnvironment.merging(extra) { $1 })
    }

    /// Run to completion from the home folder (Spotlight, Shortcuts, menu bar
    /// commands). Returns the status line followed by trimmed output.
    /// `strictValues`: with a snippet, text beyond its placeholders is refused
    /// instead of appended, because a shortcut may pass text nobody typed as a
    /// command. With `strictValues`, a snippet's `{!secrets}` are read from
    /// the Keychain. Without it they are not: extra text on the line could
    /// read them (`snippet ; echo $TERMIGHT_SECRET_x`).
    static func run(_ command: String, strictValues: Bool = false,
                    environment extra: [String: String] = [:]) async throws -> String {
        let flags = strictValues ? ["--strict-values"] : []
        let secrets = strictValues ? await secretsNeeded(by: command) : [:]
        let env = baseEnvironment.merging(extra) { $1 }.merging(secrets) { $1 }
        return try await CoreRun(arguments: flags + ["--", command], environment: env).result().output
    }

    /// The Keychain values for the secrets a snippet line refers to. A secret
    /// that isn't there is left out, and the core says which one is missing.
    static func secretsNeeded(by line: String) async -> [String: String] {
        guard case .needs(let fields) = await check(line, cwd: NSHomeDirectory()) else { return [:] }
        let names = fields.filter { $0.kind == .secret }.map(\.name)
        return names.isEmpty ? [:] : Secrets.environment(for: names).env
    }

    /// Environment for files selected in Finder: `TERMIGHT_FILES` and `TERMIGHT_FILE_<n>`.
    static func filesEnvironment(_ files: [String]) -> [String: String] {
        guard !files.isEmpty else { return [:] }
        var env = ["TERMIGHT_FILES": String(files.count)]
        for (i, f) in files.enumerated() { env["TERMIGHT_FILE_\(i + 1)"] = f }
        return env
    }

    static func check(_ line: String, cwd: String, environment extra: [String: String] = [:]) async -> Check {
        guard let run = core(["--check", "--cwd", cwd, "--", line], extra) else { return .invalid("termight-core missing") }
        let r = await run.result()
        let info = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        switch r.status {
        case 0: return .valid(info)
        case 2: return .interactive(info)
        case 3:
            return .needs(info.split(separator: "\n").map(SnippetField.init(field:)))
        default: return .invalid(info)
        }
    }

    /// `line` as a script to run somewhere else (Terminal): a snippet name
    /// expanded, with its values exported as variables the command refers to.
    /// A line that is not a snippet comes back unchanged. A snippet the core
    /// refuses (say, a placeholder inside `$(( ))`) is a failure carrying the
    /// core's reason: never fall back to the typed line, which would run the
    /// snippet's name and values as a command.
    static func expand(_ line: String, environment extra: [String: String] = [:]) async -> Result<String, ExpandFailure> {
        guard let run = core(["--expand", "--", line], extra)
        else { return .failure(ExpandFailure(reason: "termight-core missing")) }
        let r = await run.result()
        let out = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.status == 0, !out.isEmpty else {
            return .failure(ExpandFailure(reason: out.isEmpty ? "could not prepare the command" : out))
        }
        return .success(r.output.trimmingCharacters(in: .newlines))
    }

    struct ExpandFailure: Error { let reason: String }

    /// Is `name` a real command (on PATH, a builtin, an alias), snippets aside?
    static func isCommand(_ name: String) async -> Bool {
        guard let run = core(["--which", "--", name]) else { return false }
        return await run.result().status == 0
    }

    /// Tab completion: the word being completed and its candidates.
    static func complete(_ line: String, cwd: String) async -> (token: String, candidates: [String]) {
        guard let run = core(["--complete", "--cwd", cwd, "--", line]) else { return ("", []) }
        var lines = await run.result().output.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        guard !lines.isEmpty else { return ("", []) }
        return (lines[0], Array(lines.dropFirst()))
    }
}

/// One termight-core process with its output collected at the end.
/// `cancel()` sends SIGTERM, which the core turns into a process-group kill.
final class CoreRun: @unchecked Sendable {
    private let process = Process()
    private let pipe = Pipe()

    init(arguments: [String], environment: [String: String] = [:]) throws {
        guard let exe = Runner.executable else { throw Runner.Missing() }
        process.executableURL = exe
        process.arguments = arguments
        process.environment = Runner.processEnvironment(environment)
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
    }

    func result() async -> (status: Int32, output: String) {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async { [process, pipe] in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                cont.resume(returning: (process.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }

    func cancel() {
        if process.isRunning { process.terminate() }
    }
}

/// A launcher run: output is delivered live through `onOutput` (background
/// thread), and `result()` returns the core's final status and directory.
final class StreamRun: @unchecked Sendable {
    struct Meta {
        var status = "✗ no status from termight-core"
        var cwd: String?
        var code: Int32?
    }

    private let process = Process()
    private let out = Pipe()
    private let meta = Pipe()
    private let outputDone = DispatchSemaphore(value: 0)
    private var pending = Data()  // bytes of a UTF-8 character split across reads

    /// `color`: run on a pseudo-terminal and keep color codes (see Ansi).
    init(command: String, cwd: String, environment: [String: String], color: Bool,
         onOutput: @escaping @Sendable (String) -> Void) throws {
        guard let exe = Runner.executable else { throw Runner.Missing() }
        process.executableURL = exe
        process.arguments = ["--stream"] + (color ? ["--color"] : []) + ["--cwd", cwd, "--", command]
        process.environment = Runner.processEnvironment(environment)
        process.standardOutput = out
        process.standardError = meta
        process.standardInput = FileHandle.nullDevice

        out.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                if !pending.isEmpty { onOutput(String(decoding: pending, as: UTF8.self)) }
                outputDone.signal()
                return
            }
            pending.append(data)
            if let text = takeDecodable() { onOutput(text) }
        }
        try process.run()
    }

    /// Longest decodable UTF-8 prefix of `pending`; keeps up to 3 trailing bytes
    /// of an incomplete character for the next read.
    private func takeDecodable() -> String? {
        for cut in stride(from: pending.count, through: max(pending.count - 3, 1), by: -1) {
            if let s = String(data: pending.prefix(cut), encoding: .utf8) {
                pending = Data(pending.suffix(from: pending.startIndex + cut))
                return s
            }
        }
        // Not valid UTF-8 even allowing for a split character: decode lossily.
        let s = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        return s
    }

    func result() async -> Meta {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async { [self] in
                let data = meta.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                _ = outputDone.wait(timeout: .now() + 2)  // let the last output chunk land first
                var m = Meta()
                for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                    let kv = line.split(separator: "\t", maxSplits: 1).map(String.init)
                    guard kv.count == 2 else { continue }
                    switch kv[0] {
                    case "status": m.status = kv[1]
                    case "cwd": m.cwd = kv[1]
                    case "code": m.code = Int32(kv[1])
                    default: break
                    }
                }
                cont.resume(returning: m)
            }
        }
    }

    func cancel() {
        if process.isRunning { process.terminate() }
    }
}
