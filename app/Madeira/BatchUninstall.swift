//
//  BatchUninstall.swift (batch-uninstall, Nov 17 2026): the Steam page's Select mode.
//
//  Select puts the installed games (the ones Madeira's own downloads installed)
//  in select mode; Uninstall (N) asks once, then removes them ONE AT A TIME
//  through the single uninstall path (SteamOwnedLibrary.beginUninstall, its
//  delete guard and all). A game that is running, downloading or being moved is
//  skipped and named in the result sheet at the end.
//
//  Off switch: env.MADEIRA_BATCH_UNINSTALL = 0 in madeira.cfg hides Select.
//
//  Two rules from the crash reports:
//   1. No drive read on the main thread. Sizes come from the library entries
//      already in memory or from SteamInstallFiles.sizeOnDisk run in a detached
//      task; rows show nothing from disk while rendering.
//   2. The batch keeps going in the background: it holds a continued-processing
//      task (MoveBackground.uninstall) for its whole run, and its state lives in
//      this singleton, not in a view, so going inactive or closing the page
//      changes nothing. If iOS ends that task the batch stops after the game
//      being removed (onExpire).
//
//  Also here: BatchResult and its sheet, which the batch move (BatchMove.swift, its own branch) uses too.
//

import SwiftUI

/// What a batch did, for the sheet that ends it ("Removed", "Move Finished", "Move Stopped").
struct BatchResult: Identifiable, Equatable {
    struct Note: Identifiable, Equatable { let id = UUID(); let name: String; let reason: String }
    let id = UUID()
    var title: String
    var headline: [String]                 // "4 removed", "1 skipped"
    var skipped: [Note] = []
    var failed: [Note] = []
    var stopped: String?                   // "<drive> isn't connected. Connect it, then tap Move Remaining Games."
    var notDone: [String] = []             // names not moved after a stop or Cancel
    var notDoneTitle = ""                  // the section's title ("Not removed"); empty: "Not moved"
    var notDoneText = ""                   // "Not moved. Nothing was lost."
    var footer: String?                    // the drive's free space
    var again: (title: String, ids: [UUID])?   // "Move Remaining Games (2)" and what it moves

    static func == (a: BatchResult, b: BatchResult) -> Bool { a.id == b.id }
}

struct BatchResultSheet: View {
    let result: BatchResult
    /// Tapped "Move Remaining Games": the ids to move again.
    var again: (([UUID]) -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(result.headline, id: \.self) { Text($0) }
                    if let stopped = result.stopped { Text(stopped).foregroundStyle(.red) }
                }
                if !result.skipped.isEmpty {
                    Section(L("Skipped")) { ForEach(result.skipped) { note($0) } }
                }
                if !result.failed.isEmpty {
                    Section(L("Failed")) { ForEach(result.failed) { note($0) } }
                }
                if !result.notDone.isEmpty {
                    Section(result.notDoneTitle.isEmpty ? L("Not moved") : result.notDoneTitle) {
                        ForEach(result.notDone, id: \.self) { name in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name)
                                if !result.notDoneText.isEmpty { Text(result.notDoneText).font(.footnote).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
                if let footer = result.footer { Section { Text(footer).font(.footnote).foregroundStyle(.secondary) } }
            }
            .navigationTitle(result.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Done")) { dismiss() }.fontWeight(.semibold) } }
            .safeAreaInset(edge: .bottom) {
                if let again = result.again, let run = self.again {
                    Button { dismiss(); run(again.ids) } label: { Text(again.title).frame(maxWidth: .infinity, minHeight: 44) }
                        .buttonStyle(.borderedProminent).padding(.horizontal, 16).padding(.bottom, 8)
                }
            }
        }
    }

    private func note(_ item: BatchResult.Note) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name)
            Text(item.reason).font(.footnote).foregroundStyle(.secondary)
        }
    }
}

@MainActor final class BatchUninstall: ObservableObject {
    static let shared = BatchUninstall()
    /// `env.MADEIRA_BATCH_UNINSTALL = 0` hides Select on the Steam page.
    static var enabled: Bool { MadeiraConfig.flag("MADEIRA_BATCH_UNINSTALL") }

    private enum Outcome { case removed, skipped(String), failed(String), stopped }

    @Published private(set) var selecting = false
    @Published private(set) var selected = Set<Int>()
    /// Install sizes (bytes) by App ID, filled in off the main thread.
    @Published private(set) var sizes: [Int: Int64] = [:]
    @Published private(set) var running = false
    @Published private(set) var position = 0
    @Published private(set) var total = 0
    @Published private(set) var currentName = ""
    @Published private(set) var cancelling = false
    /// Shown as a sheet once the run ends.
    @Published var result: BatchResult?

    private var runTask: Task<Void, Never>?
    private var sizeTask: Task<Void, Never>?

    /// Games Madeira's downloads own: the only ones Uninstall removes.
    nonisolated static func eligible(_ game: DockGame) -> Bool { SteamInstallPaths.isManaged(library: game.library) }

    func begin() {
        guard Self.enabled, !running else { return }
        selecting = true
        selected = []
        loadSizes()
        LogStore.shared.log("[batch-uninstall] select mode on")
    }

    func finishSelecting() {
        guard selecting else { return }
        selecting = false
        selected = []
        sizeTask?.cancel()
        LogStore.shared.log("[batch-uninstall] select mode off")
    }

    func toggle(_ id: Int) {
        guard selecting, !running else { return }
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    func selectAll(_ ids: [Int]) {
        guard selecting, !running else { return }
        selected = selected.count == ids.count ? [] : Set(ids)
    }

    /// Bytes the selection frees, and whether every size is known.
    func freed() -> (bytes: Int64, complete: Bool) {
        var bytes: Int64 = 0, complete = true
        for id in selected { if let size = sizes[id] { bytes += size } else { complete = false } }
        return (bytes, complete)
    }

    /// "28 GB freed" (or "at least"), or "Calculating size…" while nothing is known yet.
    var freedText: String {
        let freed = freed()
        if freed.bytes == 0 && !freed.complete { return L("Calculating size…") }
        let text = ByteCountFormatter.string(fromByteCount: freed.bytes, countStyle: .file)
        return freed.complete ? String(format: L("%@ freed"), text) : String(format: L("At least %@ freed"), text)
    }

    /// The confirmation's first sentence: "Frees 28 GB. " (empty while no size is known).
    var freesSentence: String {
        let freed = freed()
        guard freed.bytes > 0 else { return "" }
        let text = ByteCountFormatter.string(fromByteCount: freed.bytes, countStyle: .file)
        return String(format: freed.complete ? L("Frees %@. ") : L("Frees at least %@. "), text)
    }

    /// Sizes from memory first (the library entry's folderBytes), then the install
    /// records read by a detached task. Nothing here touches a drive on the main thread.
    private func loadSizes() {
        sizeTask?.cancel()
        let games = SteamGamesModel.shared.games.filter(Self.eligible)
        var known = sizes
        for entry in LibraryModel.shared.entries {
            if let id = entry.steamAppID, let bytes = entry.folderBytes, bytes > 0 { known[id] = bytes }
        }
        sizes = known
        let work = games.filter { known[$0.id] == nil }.map { (id: $0.id, library: $0.library) }
        guard !work.isEmpty else { return }
        sizeTask = Task { @MainActor in
            let found = await Task.detached(priority: .utility) { () -> [Int: Int64] in
                let drive = LibraryModel.drive          // resolves symlinks: a disk read, so off the main thread
                var result: [Int: Int64] = [:]
                for item in work {
                    if Task.isCancelled { break }
                    if let size = SteamInstallFiles.sizeOnDisk(appID: item.id, steamApps: drive.appendingPathComponent(item.library, isDirectory: true)) {
                        result[item.id] = size
                    }
                }
                return result
            }.value
            for (id, size) in found { self.sizes[id] = size }
        }
    }

    func cancel() {
        guard running else { return }
        cancelling = true
        runTask?.cancel()
        LogStore.shared.log("[batch-uninstall] cancel asked; the game being removed finishes first")
    }

    /// Removes the selected games one at a time.
    func uninstallSelected() {
        guard Self.enabled, !running, !selected.isEmpty else { return }
        let list = SteamGamesModel.shared.games
            .filter { selected.contains($0.id) && Self.eligible($0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !list.isEmpty else { return }
        running = true; cancelling = false
        total = list.count; position = 0; currentName = ""
        selecting = false
        let background = MoveBackground.uninstall
        background.batchStarted(L("Removing games"), total: list.count) { [weak self] in self?.cancel() }
        LogStore.shared.log("[batch-uninstall] start games=\(list.count)")
        runTask = Task { @MainActor in
            var removed = 0, handled = 0
            var skipped: [BatchResult.Note] = [], failed: [BatchResult.Note] = []
            games: for (index, game) in list.enumerated() {
                if Task.isCancelled { break games }
                position = index + 1; currentName = game.name
                background.batchStep(done: index, title: String(format: L("Removing %d of %d"), index + 1, list.count))
                handled += 1
                switch await removeOne(game) {
                case .removed:
                    removed += 1
                    LogStore.shared.log("[batch-uninstall] \(index + 1)/\(list.count) app=\(game.id) removed")
                case .skipped(let why):
                    skipped.append(.init(name: game.name, reason: why))
                    LogStore.shared.log("[batch-uninstall] \(index + 1)/\(list.count) app=\(game.id) skipped: \(why)")
                case .failed(let why):
                    failed.append(.init(name: game.name, reason: why))
                    LogStore.shared.log("[batch-uninstall] \(index + 1)/\(list.count) app=\(game.id) failed: \(why)")
                case .stopped:
                    handled -= 1                       // Cancel came before this game started
                    break games
                }
            }
            let cancelled = Task.isCancelled
            let notStarted = list.count - handled
            var headline = [String(format: L("%d removed"), removed)]
            if !skipped.isEmpty { headline.append(String(format: L("%d skipped"), skipped.count)) }
            if !failed.isEmpty { headline.append(String(format: L("%d failed"), failed.count)) }
            if notStarted > 0 { headline.append(String(format: L("%d not started"), notStarted)) }
            var done = BatchResult(title: L("Removed"), headline: headline, skipped: skipped, failed: failed)
            if notStarted > 0 {
                done.notDone = list.suffix(notStarted).map(\.name)
                done.notDoneTitle = L("Not removed")
                done.notDoneText = L("Not removed. Nothing was lost.")
            }
            result = done
            LogStore.shared.log("[batch-uninstall] end removed=\(removed) skipped=\(skipped.count) failed=\(failed.count) not-started=\(notStarted) cancelled=\(cancelled)")
            background.batchEnded()
            running = false; cancelling = false; position = 0; total = 0; currentName = ""
            selected = []
            runTask = nil
        }
    }

    private func removeOne(_ game: DockGame) async -> Outcome {
        let steam = SteamOwnedLibrary.shared
        // Removed elsewhere since the batch started (its own page, Steam's client)?
        guard SteamGamesModel.shared.games.contains(where: { $0.id == game.id }) else { return .skipped(L("it is no longer installed")) }
        if wine_process_is_running() != 0 { return .skipped(L("A game is running. Close it, then try again.")) }
        if steam.downloads[game.id] != nil { return .skipped(L("Still downloading. Try again when it finishes.")) }
        if GameMover.shared.moving != nil { return .skipped(L("A game is being moved. Try again when it finishes.")) }
        // This game's own cloud check or sync (the launch-time one covers every game in turn):
        // wait for it, up to 30 s, because the single uninstall refuses while it runs.
        var waited = 0
        while steam.storageBusy(game.id), waited < 150, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000)
            waited += 1
        }
        if Task.isCancelled { return .stopped }
        guard let removal = steam.beginUninstall(game, report: false) else {
            return .skipped(steam.lastUninstallError ?? L("A game is running. Close it, then try again."))
        }
        if await removal.value { return .removed }
        return .failed(steam.lastUninstallError ?? L("it could not be removed"))
    }
}

/// Select mode's header and action bar, and the progress card.
struct BatchUninstallBar: View {
    @ObservedObject private var batch = BatchUninstall.shared
    /// The installed games Uninstall can remove (App IDs, in the page's order).
    let eligible: [Int]
    @Binding var confirm: Bool

    var body: some View {
        if batch.running {
            progress
        } else if batch.selecting {
            selecting
        }
    }

    private var selecting: some View {
        VStack(spacing: 6) {
            // Cancel left, "N Selected" as the title, Select All right (the Steam page draws its own header).
            HStack {
                Button(L("Cancel")) { batch.finishSelecting() }
                    .padItem("batch-select-cancel", cornerRadius: 12) { batch.finishSelecting() }
                Spacer()
                Text(batch.selected.isEmpty ? L("Select Games") : String(format: L("%d Selected"), batch.selected.count))
                    .font(.headline)
                Spacer()
                Button(batch.selected.count == eligible.count && !eligible.isEmpty ? L("Select None") : L("Select All")) {
                    batch.selectAll(eligible)
                }
                .padItem("batch-select-all", cornerRadius: 12) { batch.selectAll(eligible) }
            }
            .frame(minHeight: 44)
            // The action bar: red Uninstall (N), gray size freed, blue Done.
            HStack {
                Button(String(format: L("Uninstall (%d)"), batch.selected.count), role: .destructive) { confirm = true }
                    .foregroundStyle(batch.selected.isEmpty ? Color.secondary : Color.red)
                    .disabled(batch.selected.isEmpty)
                    .padItem("batch-uninstall-go", cornerRadius: 12) { if !batch.selected.isEmpty { confirm = true } }
                Spacer()
                if !batch.selected.isEmpty { Text(batch.freedText).font(.subheadline).foregroundStyle(.secondary) }
                Spacer()
                Button(L("Done")) { batch.finishSelecting() }
                    .fontWeight(.semibold)
                    .padItem("batch-select-done", cornerRadius: 12) { batch.finishSelecting() }
            }
            .frame(minHeight: 44)
        }
        .padding(.vertical, 6)
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(format: L("Removing %d of %d"), batch.position, batch.total)).font(.headline)
            if !batch.currentName.isEmpty { Text(batch.currentName).font(.footnote).foregroundStyle(.secondary) }
            ProgressView(value: Double(max(0, batch.position - 1)), total: Double(max(1, batch.total)))
            Button(batch.cancelling ? L("Stopping after this game…") : L("Cancel After This Game"), role: .destructive) { batch.cancel() }
                .disabled(batch.cancelling)
                .padItem("batch-uninstall-cancel", cornerRadius: 12) { batch.cancel() }
            Text(L("You can leave this screen. Removing keeps going in the background.")).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}
