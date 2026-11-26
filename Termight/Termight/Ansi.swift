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
    static func lines(_ s: String) -> [Line] {
        var lines: [Line] = []
        var line: Line = []
        var text = ""
        var style = Style()
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
        return lines
    }

    /// The same text with no styles: what Copy puts on the clipboard.
    static func plain(_ s: String) -> String {
        lines(s).map(plainLine).joined(separator: "\n")
    }

    static func plainLine(_ line: Line) -> String { line.map(\.text).joined() }

    /// Styled text for the output view; `highlight` marks lines (by index)
    /// that changed since the last run of a watched command.
    static func render(_ lines: [Line], highlight: Set<Int> = []) -> AttributedString {
        var out = AttributedString()
        for (n, line) in lines.enumerated() {
            if n > 0 { out.append(AttributedString("\n")) }
            for run in line {
                var piece = AttributedString(run.text)
                piece.mergeAttributes(attributes(run.style))
                if highlight.contains(n) { piece.backgroundColor = Color.yellow.opacity(0.28) }
                out.append(piece)
            }
            if line.isEmpty, highlight.contains(n) {
                var mark = AttributedString(" ")
                mark.backgroundColor = Color.yellow.opacity(0.28)
                out.append(mark)
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
    private static func color(_ n: Int) -> Color {
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
