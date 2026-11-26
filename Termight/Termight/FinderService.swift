// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 David Nordqvist
//
// This file is part of Termight. Termight is free software: you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License, version 3, as published by the Free Software Foundation. It comes
// with no warranty. See the LICENSE file for the full text.

import AppKit

/// Finder → right-click → Quick Actions (Services): "Run in Termight" opens the
/// bar with the selected files ready for a snippet's `{files}`, and "New
/// Termight Command Here" opens it in the selected folder. Both only open the
/// bar: nothing runs until you press Return. Declared under NSServices in
/// Info.plist.
@MainActor
final class FinderService: NSObject {
    static let shared = FinderService()

    func register() {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    @objc(runOnFiles:userData:error:)
    func runOnFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        let paths = fileURLs(pboard).map(\.path)
        guard !paths.isEmpty else { return }
        AppState.shared.launcher.show(files: paths)
    }

    @objc(openFolder:userData:error:)
    func openFolder(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        guard let url = fileURLs(pboard).first else { return }
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        AppState.shared.launcher.show(cwd: isDir ? url.path : url.deletingLastPathComponent().path)
    }

    private func fileURLs(_ pboard: NSPasteboard) -> [URL] {
        pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}
