// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 David Nordqvist
//
// This file is part of Termight. Termight is free software: you can
// redistribute it and/or modify it under the terms of the GNU General Public
// License, version 3, as published by the Free Software Foundation. It comes
// with no warranty. See the LICENSE file for the full text.

import AppIntents
import CoreSpotlight
import Foundation
import SwiftUI
import UserNotifications

// Menu bar app (optional Dock icon). Three front doors, one engine:
//   1. Hotkey launcher panel (Launcher.swift): type a command, Return runs it.
//   2. Menu bar icon (below): open the launcher, rerun recent commands, settings.
//   3. Spotlight and Shortcuts actions (App Intents, below), off until allowed in Settings.
// All hand the command to the Rust core at Contents/MacOS/termight-core (Core.swift).
@main
struct TermightApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(Prefs.showMenuBarIcon) private var showMenuBarIcon = true

    init() { Prefs.register() }

    var body: some Scene {
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarMenu()
        } label: {
            MenuBarLabel(store: AppState.shared.jobs)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { AppState.shared.openSettings() }
                    .keyboardShortcut(",")
            }
        }
    }
}

struct MenuBarMenu: View {
    @ObservedObject private var state = AppState.shared
    @ObservedObject private var jobs = AppState.shared.jobs

    var body: some View {
        Button("Open Termight  \(HotKeyPreset.current == .off ? "" : HotKeyPreset.current.label)") {
            AppState.shared.launcher.show()
        }
        let _ = state.historyVersion  // refresh when history changes
        let recent = state.recentCommands(limit: 8)
        if !recent.isEmpty {
            Menu("Run Again") {
                ForEach(recent, id: \.self) { cmd in
                    Button(cmd) { AppState.shared.launcher.show(prefill: cmd) }
                }
            }
        }
        if !jobs.jobs.isEmpty {
            Divider()
            Section(jobs.runningCount > 0 ? "Jobs · \(jobs.runningCount) running" : "Recent jobs") {
                ForEach(jobs.jobs.prefix(10)) { JobMenuItem(job: $0) }
            }
            if jobs.runningCount > 1 {
                Button("Cancel All Running") { jobs.cancelAll() }
            }
        }
        Divider()
        UpdateMenuItem()
        Button("Settings…") { AppState.shared.openSettings() }
            .keyboardShortcut(",")
        Button("Quit Termight") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = AppState.shared  // builds the launcher, registers the hotkey, applies Dock setting
        UNUserNotificationCenter.current().delegate = self
        if Prefs.d.bool(forKey: Prefs.notifyOnFinish) { Notifier.requestPermission() }
        SnippetIndex.reindex(SnippetStore.load())
        Updater.shared.start()
        WindowTheme.apply()
        FinderService.shared.register()
        StatusCommands.shared.start()
    }

    /// Quitting must not leave commands running with nothing to show or stop them.
    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.jobs.cancelAll()
    }

    /// A snippet chosen from Spotlight's results opens the launcher with it filled in.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let id = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              id.hasPrefix(SnippetIndex.prefix)
        else { return false }
        // Only a snippet that exists: the identifier arrives from outside the app.
        let name = String(id.dropFirst(SnippetIndex.prefix.count))
        guard SnippetStore.load().contains(where: { $0.name == name }) else { return false }
        AppState.shared.launcher.show(prefill: name)
        return true
    }

    /// Clicking a "command finished" notification shows its output.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let isUpdate = response.notification.request.content.userInfo[Updater.notificationKey] != nil
        DispatchQueue.main.async {
            // An update banner offers the update; any other opens the launcher.
            if isUpdate, case .available(let r) = Updater.shared.state {
                Updater.shared.offer(r)
            } else if !isUpdate {
                AppState.shared.launcher.show()
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Opening Termight again (Dock click, Finder, Spotlight app result) shows Settings,
    /// so it stays reachable even with the menu bar icon and Dock icon both hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        AppState.shared.openSettings()
        return false
    }
}

/// Spotlight and Shortcuts run these with no confirmation, and a shortcut can run
/// with nobody looking (an automation, one imported from elsewhere). So they do
/// nothing until the user turns on "Allow Spotlight and Shortcuts to run
/// commands" in Settings.
enum IntentGate {
    static let message = "Turn on “Allow Spotlight and Shortcuts to run commands” in Termight’s Settings → Commands first."
    static var allowed: Bool { Prefs.d.bool(forKey: Prefs.allowShortcuts) }
}

struct RunCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Command"
    static let description = IntentDescription("Run a shell command without opening Terminal. Off until allowed in Termight's settings.")
    static let openAppWhenRun = false

    // Single-line field: Return submits. Smart quotes/dashes off so `"` and
    // `--` reach the shell unchanged.
    @Parameter(
        title: "Command",
        inputOptions: String.IntentInputOptions(
            multiline: false, autocorrect: false, smartQuotes: false, smartDashes: false))
    var command: String

    static var parameterSummary: some ParameterSummary { Summary("Run \(\.$command)") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard IntentGate.allowed else {
            return .result(value: "", dialog: IntentDialog(stringLiteral: IntentGate.message))
        }
        let out = try await Runner.run(command)
        return .result(value: out, dialog: IntentDialog(stringLiteral: out))
    }
}

// MARK: - Snippets in Shortcuts and Spotlight

struct SnippetEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Snippet"
    static let defaultQuery = SnippetQuery()

    var id: String  // the snippet name
    var command: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id)", subtitle: "\(command)")
    }
}

struct SnippetQuery: EntityStringQuery {
    private func all() -> [SnippetEntity] {
        SnippetStore.load().filter(\.isValid).map { SnippetEntity(id: $0.name, command: $0.command) }
    }

    func entities(for identifiers: [String]) async throws -> [SnippetEntity] {
        all().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [SnippetEntity] {
        all().filter { $0.id.localizedCaseInsensitiveContains(string) || $0.command.localizedCaseInsensitiveContains(string) }
    }

    func suggestedEntities() async throws -> [SnippetEntity] { all() }
}

struct RunSnippetIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Snippet"
    static let description = IntentDescription("Run one of your saved Termight snippets. Off until allowed in Termight's settings.")
    static let openAppWhenRun = false

    @Parameter(title: "Snippet") var snippet: SnippetEntity

    @Parameter(title: "Values", description: "Fill the snippet's {placeholders} in order, separated by spaces.",
               inputOptions: String.IntentInputOptions(multiline: false, autocorrect: false, smartQuotes: false, smartDashes: false))
    var values: String?

    static var parameterSummary: some ParameterSummary { Summary("Run \(\.$snippet) with \(\.$values)") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard IntentGate.allowed else {
            return .result(value: "", dialog: IntentDialog(stringLiteral: IntentGate.message))
        }
        let line = [snippet.id, values ?? ""].joined(separator: " ")
        // The core expands the name and fills placeholders. Strict: Values may come
        // from a shortcut's variable, so anything beyond the placeholders is refused, not run.
        let out = try await Runner.run(line, strictValues: true)
        return .result(value: out, dialog: IntentDialog(stringLiteral: out))
    }
}

struct TermightShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunCommandIntent(),
            phrases: ["Run command with \(.applicationName)", "\(.applicationName)"],
            shortTitle: "Run Command",
            systemImageName: "terminal")
        AppShortcut(
            intent: RunSnippetIntent(),
            phrases: ["Run \(\.$snippet) with \(.applicationName)", "\(.applicationName) \(\.$snippet)"],
            shortTitle: "Run Snippet",
            systemImageName: "text.badge.checkmark")
    }
}
