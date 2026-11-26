// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 David Nordqvist
//
// This file is part of Termight. Termight is free software: you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License, version 3, as published by the Free Software Foundation. It comes
// with no warranty. See the LICENSE file for the full text.

import AppKit
import SwiftUI

/// Output with color codes, as the core streams it with `--color`: SGR
/// sequences (`ESC [ … m`) and lone carriage returns (a progress bar redrawing
/// its line). Everything else was already removed by the core.
enum Ansi {
    struct Style: Equatable {
        var fg: Int?  // 0–255, or -1 - 0xRRGGBB for 24-bit color
        var bg: Int?
        var bold = false
        var dim = false
        var italic = false
        var underline = false
        var inverse = false
    }

    struct Run {
        var text: String
        var style: Style
    }

    typealias Line = [Run]

    /// The text split into lines of styled runs. A `\r` not followed by `\n`
    /// starts its line over, as in a terminal.
    static func lines(_ s: some StringProtocol) -> [Line] {
        lines(s, start: Style()).lines
    }

    /// The same, starting in `start` (the style a previous chunk ended in);
    /// also returns the style at the end, for the next chunk.
    static func lines(_ s: some StringProtocol, start: Style) -> (lines: [Line], end: Style) {
        var lines: [Line] = []
        var line: Line = []
        var text = ""
        var style = start
        let scalars = Array(s.unicodeScalars)
        var i = 0

        func flush() {
            if !text.isEmpty {
                line.append(Run(text: text, style: style))
                text = ""
            }
        }

        while i < scalars.count {
            let c = scalars[i]
            switch c {
            case "\u{1B}":
                // ESC [ params m
                var j = i + 1
                guard j < scalars.count, scalars[j] == "[" else { i += 1; continue }
                j += 1
                var params = ""
                while j < scalars.count, scalars[j] != "m", params.count < 64 {
                    params.unicodeScalars.append(scalars[j])
                    j += 1
                }
                flush()
                apply(params, to: &style)
                i = j + 1
                continue
            case "\r":
                if i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 1; continue }
                text = ""
                line = []
            case "\n":
                flush()
                lines.append(line)
                line = []
            default:
                text.unicodeScalars.append(c)
            }
            i += 1
        }
        flush()
        if !line.isEmpty { lines.append(line) }
        return (lines, style)
    }

    /// Each line without styles: what comparisons and find work on.
    static func plainLines(_ s: some StringProtocol) -> [String] {
        lines(s).map(plainLine)
    }

    /// The tint for lines that changed (watch, ⌘D) and the current find match.
    static let changedTint = Color.yellow.opacity(0.28)

    /// The same text with no styles: what Copy puts on the clipboard.
    static func plain(_ s: String) -> String {
        lines(s).map(plainLine).joined(separator: "\n")
    }

    static func plainLine(_ line: Line) -> String { line.map(\.text).joined() }

    /// Styled text for the output view; `highlight` marks lines (by index)
    /// that changed since the last run of a watched command.
    static func render(_ lines: [Line], highlight: Set<Int> = [], mark: String? = nil) -> AttributedString {
        var out = AttributedString()
        for (n, line) in lines.enumerated() {
            if n > 0 { out.append(AttributedString("\n")) }
            out.append(renderLine(line, highlight: highlight.contains(n), mark: mark))
        }
        return out
    }

    /// One line; `highlight` tints it (a changed line), `mark` picks out every
    /// occurrence of a search term, ignoring case.
    static func renderLine(_ line: Line, highlight: Bool = false, mark: String? = nil) -> AttributedString {
        var out = AttributedString()
        for run in line {
            var piece = AttributedString(run.text)
            piece.mergeAttributes(attributes(run.style))
            if highlight { piece.backgroundColor = changedTint }
            out.append(piece)
        }
        if line.isEmpty, highlight {
            var blank = AttributedString(" ")
            blank.backgroundColor = changedTint
            out.append(blank)
        }
        if let mark, !mark.isEmpty {
            var from = out.startIndex
            while from < out.endIndex, let r = out[from...].range(of: mark, options: .caseInsensitive) {
                out[r].backgroundColor = Color.orange.opacity(0.55)
                from = r.upperBound
            }
        }
        return out
    }

    private static func attributes(_ s: Style) -> AttributeContainer {
        var a = AttributeContainer()
        var fg = s.fg.map(color)
        var bg = s.bg.map(color)
        if s.inverse {
            (fg, bg) = (bg ?? Color(nsColor: .textBackgroundColor), fg ?? .primary)
        }
        if s.dim { fg = (fg ?? .primary).opacity(0.6) }
        if let fg { a.foregroundColor = fg }
        if let bg { a.backgroundColor = bg.opacity(s.inverse ? 1 : 0.35) }
        if s.bold && s.italic {
            a.inlinePresentationIntent = [.stronglyEmphasized, .emphasized]
        } else if s.bold {
            a.inlinePresentationIntent = .stronglyEmphasized
        } else if s.italic {
            a.inlinePresentationIntent = .emphasized
        }
        if s.underline { a.underlineStyle = .single }
        return a
    }

    private static func apply(_ params: String, to s: inout Style) {
        let codes = params.isEmpty ? [0] : params.split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0.split(separator: ":").first ?? "") ?? 0 }
        var i = 0
        func extended() -> Int? {
            // 38;5;n or 38;2;r;g;b
            guard i + 1 < codes.count else { return nil }
            if codes[i + 1] == 5, i + 2 < codes.count {
                defer { i += 2 }
                return min(max(codes[i + 2], 0), 255)
            }
            if codes[i + 1] == 2, i + 4 < codes.count {
                defer { i += 4 }
                let rgb = (min(max(codes[i + 2], 0), 255) << 16) | (min(max(codes[i + 3], 0), 255) << 8)
                    | min(max(codes[i + 4], 0), 255)
                return -1 - rgb
            }
            return nil
        }
        while i < codes.count {
            let c = codes[i]
            switch c {
            case 0: s = Style()
            case 1: s.bold = true
            case 2: s.dim = true
            case 3: s.italic = true
            case 4: s.underline = true
            case 7: s.inverse = true
            case 22: s.bold = false; s.dim = false
            case 23: s.italic = false
            case 24: s.underline = false
            case 27: s.inverse = false
            case 30...37: s.fg = c - 30
            case 38: if let v = extended() { s.fg = v }
            case 39: s.fg = nil
            case 40...47: s.bg = c - 40
            case 48: if let v = extended() { s.bg = v }
            case 49: s.bg = nil
            case 90...97: s.fg = c - 90 + 8
            case 100...107: s.bg = c - 100 + 8
            default: break
            }
            i += 1
        }
    }

    /// Terminal colors in system colors, so they read in light and dark mode.
    /// The 16 basic terminal colors to use instead of the system ones (a
    /// theme's), and a counter bumped on each change so styled output knows
    /// to restyle. Set on the main thread by WindowTheme.apply.
    private(set) static var palette: [Color]?
    private(set) static var paletteVersion = 0

    static func setPalette(_ colors: [Color]?) {
        palette = colors
        paletteVersion &+= 1
    }

    private static func color(_ n: Int) -> Color {
        if let palette, (0..<16).contains(n), palette.count == 16 { return palette[n] }
        if n < 0 {
            let rgb = -1 - n
            return Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                         blue: Double(rgb & 0xFF) / 255)
        }
        switch n {
        case 0, 8: return .secondary
        case 1, 9: return Color(nsColor: .systemRed)
        case 2, 10: return Color(nsColor: .systemGreen)
        case 3, 11: return Color(nsColor: .systemOrange)
        case 4, 12: return Color(nsColor: .systemBlue)
        case 5, 13: return Color(nsColor: .systemPurple)
        case 6, 14: return Color(nsColor: .systemTeal)
        case 7, 15: return .primary
        case 16...231:
            let v = [0, 95, 135, 175, 215, 255]
            let k = n - 16
            return Color(red: Double(v[k / 36]) / 255, green: Double(v[k / 6 % 6]) / 255, blue: Double(v[k % 6]) / 255)
        default:
            let g = Double(8 + 10 * (n - 232)) / 255
            return Color(red: g, green: g, blue: g)
        }
    }
}

/// Which lines of a new output are new or changed compared with an old one,
/// by longest common subsequence, so one inserted line marks only itself.
enum LineDiff {
    static func compare(_ old: [String], _ new: [String]) -> (changed: Set<Int>, removed: Int) {
        let n = old.count, m = new.count
        // Very long outputs: line by line instead (the table would be too big).
        guard n * m <= 4_000_000 else {
            let changed = Set(new.indices.filter { $0 >= n || new[$0] != old[$0] })
            return (changed, max(n - m, 0))
        }
        var table = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var i = 0, j = 0, same = Set<Int>()
        while i < n && j < m {
            if old[i] == new[j] {
                same.insert(j)
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        let changed = Set(new.indices).subtracting(same)
        return (changed, n - same.count)
    }
}
