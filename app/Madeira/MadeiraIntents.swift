// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import AppIntents
import Foundation

/// (app-intents) A "Launch Game" action for Shortcuts, Spotlight, Siri and the Action Button: pick a game from the
/// Madeira library once, and one tap starts it. It goes through the same path as a Home Screen link
/// (ShortcutRouter, madeira://play?exe=...): Madeira opens, waits for its library, gets JIT, then starts the
/// game like Play on its page. Off by default: until env.MADEIRA_APP_INTENTS = 1 the action does nothing (iOS still lists it;
/// actions cannot be hidden at run time). Our own design.
enum MadeiraIntents {
    static var enabled: Bool { MadeiraConfig.flag("MADEIRA_APP_INTENTS", fallback: false) }
}

/// A library game as Shortcuts sees it. The id is the game's Windows path, which ShortcutRouter starts.
struct MadeiraGameEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Game"
    static let defaultQuery = MadeiraGameQuery()
    let id: String
    let title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
}

struct MadeiraGameQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [MadeiraGameEntity] {
        await Self.all().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [MadeiraGameEntity] { await Self.all() }
    @MainActor private static func all() -> [MadeiraGameEntity] {
        LibraryModel.shared.entries.filter { $0.desktop != true }
            .map { MadeiraGameEntity(id: $0.windowsPath, title: $0.title) }
    }
}

struct LaunchGameIntent: AppIntent {
    static let title: LocalizedStringResource = "Launch Game"
    static let description = IntentDescription("Starts a game from your Madeira library.")
    static let openAppWhenRun = true

    @Parameter(title: "Game") var game: MadeiraGameEntity

    @MainActor func perform() async throws -> some IntentResult {
        guard MadeiraIntents.enabled else {
            LogStore.shared.log("[app-intents] Launch Game ignored: env.MADEIRA_APP_INTENTS is off")
            // Say so in the app (the same alert a broken Home Screen link uses), so a tap never looks lost.
            LibraryModel.shared.error = L("The Launch Game shortcut is off. Turn it on with env.MADEIRA_APP_INTENTS = 1 in madeira.cfg.")
            return .result()
        }
        LogStore.shared.log("[app-intents] Launch Game: \(game.title)")
        if let url = URL(string: ShortcutRouter.link(for: game.id)) { ShortcutRouter.shared.handle(url) }
        return .result()
    }
}

struct MadeiraShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: LaunchGameIntent(),
                    phrases: ["Launch a game in \(.applicationName)", "Play a game in \(.applicationName)"],
                    shortTitle: "Launch Game", systemImageName: "gamecontroller.fill")
    }
}
