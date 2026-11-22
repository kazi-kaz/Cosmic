//
//  BatchMove.swift (batch-move, Nov 17 2026): Settings › External drives › Move Games… and
//  Move All Games to <drive>…
//
//  Moves the chosen games to one drive (or back to This iPhone) ONE AT A TIME through
//  GameMover.move, the same path as Game details › Install Location › Move to. Before it
//  starts it adds up the sizes and compares them with the drive's free space; it asks once;
//  "Moving Games" shows each game's state with Cancel After This Game; a game that is running,
//  downloading or busy is skipped and named in the result; if the drive goes away it stops
//  and offers Move Remaining Games.
//
//  Off switch: env.MADEIRA_BATCH_MOVE = 0 in madeira.cfg hides the Move Games section.
//  env.MADEIRA_BATCH_MOVE_FULL_LIST = 0 brings back the old list (library entries only). By default the list is every
//  installed Steam game (SteamGamesModel, minus tools such as Steamworks Common Redistributables) plus the non-Steam
//  entries, and a game is hidden only when it is already in the chosen place.
//
//  Two rules from the crash reports:
//   1. No drive read on the main thread in this file: sizes come from the library entries in
//      memory or SteamInstallFiles.sizeOnDisk in a detached task, free space is read in a
//      detached task, and the picker's rows read no disk (a placeholder shows until a size
//      arrives). GameMover.move itself still resolves its paths on the main actor, as before.
//   2. The batch keeps going in the background: it holds MoveBackground's continued-processing
//      task across all its games (batchStarted / batchStep / batchEnded), and its state is in
//      this singleton, not in a view; leaving or dismissing a page changes nothing.
//

import SwiftUI

@MainActor final class BatchMove: ObservableObject {
    static let shared = BatchMove()
    /// `env.MADEIRA_BATCH_MOVE = 0` hides the Move Games section.
    static var enabled: Bool { MadeiraConfig.flag("MADEIRA_BATCH_MOVE") }
    /// GameMover refuses a game when the target has less than this many bytes free beyond its size.
    static let marginPerGame: Int64 = 256 * 1_048_576

    struct Candidate: Identifiable, Equatable {
        let id: UUID            // the library entry
        let title: String
        let appID: Int?         // Steam App ID, nil for a game you added
        let place: String       // "This iPhone" or the drive's name
    }

    /// What the confirmation shows: the games, where to, and whether the drive has room.
    struct Plan: Equatable {
        let target: String
        let games: [Candidate]
        let bytes: Int64        // known sizes added up
        let allSizesKnown: Bool
        let free: Int64?
        var needed: Int64 { bytes + Int64(games.count) * BatchMove.marginPerGame }
        var fits: Bool { free.map { needed <= $0 } ?? true }
    }

    struct Row: Identifiable {
        enum State: Equatable { case waiting, moving, moved, skipped(String), failed(String) }
        let id: UUID
        let title: String
        var state: State = .waiting
    }

    /// The one sheet this feature shows: the picker, the progress page, or the result.
    enum Page: Identifiable {
        case picker, progress, result(BatchResult)
        var id: String {
            switch self {
            case .picker: return "picker"
            case .progress: return "progress"
            case .result(let result): return "result-\(result.id)"
            }
        }
    }

    private enum Outcome { case moved, skipped(String), failed(String), driveGone(String) }

    @Published var page: Page?
    @Published private(set) var preparing = false
    @Published var plan: Plan?
    /// Shown when the drive does not have room (instead of the confirmation).
    @Published var noRoom: String?
    @Published private(set) var sizes: [UUID: Int64] = [:]
    /// Free bytes by drive name, read off the main thread when the picker shows.
    @Published private(set) var freeByTarget: [String: Int64] = [:]
    @Published private(set) var running = false
    @Published private(set) var position = 0
    @Published private(set) var total = 0
    @Published private(set) var currentName = ""
    @Published private(set) var cancelling = false
    @Published private(set) var rows: [Row] = []

    /// The drive the last batch was asked to move to (Move Remaining Games moves to it again).
    private(set) var lastTarget = ""
    private var runTask: Task<Void, Never>?
    private var sizeTask: Task<Void, Never>?

    // MARK: Candidates (memory only)

    /// A game installed by a store's own launcher record (Epic, GOG, itch.io, EA): moving its
    /// folder would leave that record pointing at the old place, so these stay out of a batch.
    private static func storeManaged(_ entry: LibraryEntry) -> Bool {
        if let id = entry.epicAppName, EpicLibrary.shared.installed[id] != nil { return true }
        if let id = entry.gogProductID, GOGLibrary.shared.installed[id] != nil { return true }
        if let id = entry.itchGameID, ItchLibrary.shared.installed[id] != nil { return true }
        if let id = entry.eaOfferID, EALibrary.shared.installed[id] != nil { return true }
        return false
    }

    /// `env.MADEIRA_BATCH_MOVE_FULL_LIST = 0` brings back the old list (library entries only).
    static var fullList: Bool { MadeiraConfig.flag("MADEIRA_BATCH_MOVE_FULL_LIST") }

    struct Counts: Equatable { var steam = 0, other = 0, tools = 0, onTarget = 0 }

    /// Entries made in memory for installed Steam games that have no library entry yet (one per App ID, so a
    /// row keeps the same id from one redraw to the next). GameMover.move saves it, as playing the game would.
    private var synthesized: [Int: LibraryEntry] = [:]
    private var lastListed = ""

    /// A Steam tool, not a game: Steamworks Common Redistributables, Steam Linux Runtime, Proton.
    static func isTool(appID: Int, name: String) -> Bool {
        if [228980, 1070560, 1391110, 1628350, 1493710].contains(appID) { return true }
        let lower = name.lowercased()
        return lower.contains("steamworks common redistributables") || lower.contains("steamworks shared")
            || lower.hasPrefix("steam linux runtime") || lower == "proton" || lower.hasPrefix("proton ")
            || lower.hasPrefix("proton-") || lower.hasPrefix("proton experimental") || lower.hasPrefix("steam controller configs")
    }

    /// True when two Steam libraries are the same place for a move: equal, or one inside the other on the same drive
    /// (External/<drive>/steamapps and External/<drive>/SteamLibrary/steamapps). Copying between them gains nothing.
    static func sameLibrary(_ a: String, _ b: String) -> Bool {
        if a.caseInsensitiveCompare(b) == .orderedSame { return true }
        guard let one = ExternalDrives.driveName(library: a), let two = ExternalDrives.driveName(library: b), one == two else { return false }
        func top(_ library: String) -> String { library.hasSuffix("/steamapps") ? String(library.dropLast("/steamapps".count)) : library }
        let x = top(a).lowercased(), y = top(b).lowercased()
        return x.hasPrefix(y + "/") || y.hasPrefix(x + "/")
    }

    /// The library entry of a candidate: the saved one, or the one made in memory for an installed Steam game without one.
    func entry(for id: UUID) -> LibraryEntry? {
        if let saved = LibraryModel.shared.entries.first(where: { $0.id == id }) { return saved }
        guard let made = synthesized.values.first(where: { $0.id == id }) else { return nil }
        // The game got a saved entry since (played, details page closed): use that one, not a second entry.
        return LibraryModel.shared.entries.first { $0.steamAppID != nil && $0.steamAppID == made.steamAppID } ?? made
    }

    /// An id as the list shows it now: a made-in-memory id becomes the saved entry's id once one exists.
    func current(_ id: UUID) -> UUID { entry(for: id)?.id ?? id }

    /// The games to list for `target`, and what was left out and why.
    func listing(to target: String) -> (list: [Candidate], counts: Counts) {
        guard Self.fullList else { return (legacyCandidates(to: target), Counts()) }
        let steam = SteamOwnedLibrary.shared
        let targetLibrary = ExternalDrives.shared.steamTargets.first { $0.name == target }?.library
        let entries = LibraryModel.shared.entries
        var byApp: [Int: LibraryEntry] = [:]
        for entry in entries { if let appID = entry.steamAppID, byApp[appID] == nil { byApp[appID] = entry } }
        var result: [Candidate] = []
        var counts = Counts()
        for game in SteamGamesModel.shared.games where game.installed {
            if Self.isTool(appID: game.id, name: game.name) { counts.tools += 1; continue }
            guard SteamInstallPaths.isManaged(library: game.library), steam.downloads[game.id] == nil else { continue }
            // Already in the chosen place: the same library, one nested with it, or any library on the chosen drive.
            if GameMover.place(game.library) == target || (targetLibrary.map { Self.sameLibrary(game.library, $0) } ?? false) {
                counts.onTarget += 1; continue
            }
            let id: UUID
            if let saved = byApp[game.id] { id = saved.id }
            else if let made = synthesized[game.id] { id = made.id }
            else {
                var made = LibraryEntry(title: game.name, relativePath: game.library + "/common/" + game.installDir, bits: 0)
                made.steamAppID = game.id
                synthesized[game.id] = made
                id = made.id
            }
            counts.steam += 1
            result.append(Candidate(id: id, title: byApp[game.id]?.title ?? game.name, appID: game.id, place: GameMover.place(game.library)))
        }
        for entry in entries where entry.desktop != true && entry.steamAppID == nil {
            let place = GameMover.place(entry.relativePath)
            if place == target { counts.onTarget += 1; continue }
            guard !Self.storeManaged(entry) else { continue }
            counts.other += 1
            result.append(Candidate(id: entry.id, title: entry.title, appID: nil, place: place))
        }
        return (result.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }, counts)
    }

    func candidates(to target: String) -> [Candidate] { listing(to: target).list }

    /// One log line per target and result, written when the picker opens or a batch is prepared (never from a view body).
    private func logListing(_ target: String, _ counts: Counts) {
        let library = ExternalDrives.shared.steamTargets.first { $0.name == target }?.library ?? "-"
        let line = "[batch-move] listed \(counts.steam + counts.other) games: steam=\(counts.steam) other=\(counts.other) skipped-tools=\(counts.tools) on-target=\(counts.onTarget) target=\(target) library=\(library) places=\(ExternalDrives.shared.steamTargets.map(\.name).joined(separator: "|")) games-in=\(SteamGamesModel.shared.games.filter(\.installed).map { GameMover.place($0.library) }.sorted().joined(separator: ","))"
        guard line != lastListed else { return }
        lastListed = line
        LogStore.shared.log(line)
    }

    /// The old list: only games that have a library entry.
    private func legacyCandidates(to target: String) -> [Candidate] {
        let steam = SteamOwnedLibrary.shared
        let installed = Dictionary(SteamGamesModel.shared.games.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [Candidate] = []
        for entry in LibraryModel.shared.entries where entry.desktop != true {
            let place = GameMover.place(entry.relativePath)
            guard place != target else { continue }
            if let appID = entry.steamAppID {
                guard let game = installed[appID], game.installed, SteamInstallPaths.isManaged(library: game.library),
                      steam.downloads[appID] == nil else { continue }
                result.append(Candidate(id: entry.id, title: entry.title, appID: appID, place: GameMover.place(game.library)))
            } else {
                guard !Self.storeManaged(entry) else { continue }
                result.append(Candidate(id: entry.id, title: entry.title, appID: nil, place: place))
            }
        }
        return result.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Sizes for the picker's rows (folderBytes from memory, the rest read by a detached task) and
    /// the free space of each place a game can go. Rows show "…" until a size arrives.
    func loadPickerFacts(target: String) {
        sizeTask?.cancel()
        let (list, counts) = listing(to: target)
        if Self.fullList { logListing(target, counts) }
        let work = sizeWork(for: list)
        let places = ExternalDrives.shared.steamTargets.map { (name: $0.name, library: $0.library) }
        sizeTask = Task { @MainActor in
            let reader = Task.detached(priority: .utility) { () -> ([UUID: Int64], [String: Int64]) in
                let drive = LibraryModel.drive          // resolves symlinks: a disk read, so off the main thread
                let sized = Self.readSizes(work, drive: drive)
                var free: [String: Int64] = [:]
                for place in places {
                    if let bytes = drive.appendingPathComponent(place.library, isDirectory: true).freeSpace { free[place.name] = bytes }
                }
                return (sized, free)
            }
            // A detached task does not inherit cancellation: pass it on, so an older read stops when a newer one starts.
            let found = await withTaskCancellationHandler { await reader.value } onCancel: { reader.cancel() }
            for (id, size) in found.0 { self.sizes[id] = size }
            for (name, bytes) in found.1 { self.freeByTarget[name] = bytes }
        }
    }

    /// What still has to be read from disk to size `list`: a Steam game's install record, or a folder's files. Sizes
    /// already known (folderBytes, memory) are filled in here, no disk involved.
    private struct SizeWork: Sendable {
        var steam: [(id: UUID, appID: Int, library: String)] = []
        var folders: [(id: UUID, path: String)] = []
    }

    private func sizeWork(for list: [Candidate]) -> SizeWork {
        var known = sizes
        var work = SizeWork()
        let installed = Dictionary(SteamGamesModel.shared.games.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for item in list where known[item.id] == nil {
            let found = self.entry(for: item.id)
            if let bytes = found?.folderBytes, bytes > 0 { known[item.id] = bytes; continue }
            if let appID = item.appID {
                if let game = installed[appID] { work.steam.append((item.id, appID, game.library)) }
            } else if let found, Self.fullList {
                let folder = GameMover.gameFolder(found.relativePath)       // a string only
                // Same depth rule as GameMover.move: never a whole drive or a top-level container.
                let deep = folder.split(separator: "/").count >= (folder.hasPrefix("External/") ? 3 : 1)
                if !folder.isEmpty, deep, !["games", "external"].contains(folder.lowercased()) { work.folders.append((item.id, folder)) }
            }
        }
        if known != sizes { sizes = known }
        return work
    }

    /// Reads the sizes in `work`. Disk reads: call it off the main thread.
    nonisolated private static func readSizes(_ work: SizeWork, drive: URL) -> [UUID: Int64] {
        var found: [UUID: Int64] = [:]
        for item in work.steam {
            if Task.isCancelled { return found }
            if let size = SteamInstallFiles.sizeOnDisk(appID: item.appID, steamApps: drive.appendingPathComponent(item.library, isDirectory: true)) {
                found[item.id] = size
            }
        }
        for item in work.folders {
            if Task.isCancelled { return found }
            let root = drive.appendingPathComponent(item.path, isDirectory: true).resolvingSymlinksInPath()
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else { continue }
            var total: Int64 = 0, files = 0
            for case let file as URL in walker {
                if Task.isCancelled { return found }
                files += 1
                if files > 200_000 { total = 0; break }       // too big to add up here: the size stays unknown
                let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey])
                if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
            }
            if total > 0 { found[item.id] = total }
        }
        return found
    }

    // MARK: Plan (sizes and free space, off the main thread)

    /// Works out the plan for `ids` (nil: every candidate) and shows the confirmation, or
    /// says there is no room.
    func prepare(target: String, ids: Set<UUID>?) {
        guard Self.enabled, !running, !preparing else { return }
        let (all, counts) = listing(to: target)
        if Self.fullList { logListing(target, counts) }
        let wanted = ids.map { Set($0.map(current)) }
        let games = all.filter { wanted?.contains($0.id) ?? true }
        guard !games.isEmpty else { noRoom = L("Nothing to move: every game is already there."); return }
        lastTarget = target
        preparing = true
        // Sizes already in memory (folderBytes) are filled in now; the detached task below reads the rest.
        let missing = sizeWork(for: games)
        let library = ExternalDrives.shared.steamTargets.first { $0.name == target }?.library
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { () -> ([UUID: Int64], Int64?) in
                let drive = LibraryModel.drive
                let found = Self.readSizes(missing, drive: drive)
                let free = library.flatMap { drive.appendingPathComponent($0, isDirectory: true).freeSpace }
                return (found, free)
            }.value
            for (id, size) in result.0 { sizes[id] = size }
            var bytes: Int64 = 0, complete = true
            for item in games { if let size = sizes[item.id] { bytes += size } else { complete = false } }
            let next = Plan(target: target, games: games, bytes: bytes, allSizesKnown: complete, free: result.1)
            // The picker or result sheet that asked is still closing: a dialog shown now can be dropped.
            try? await Task.sleep(nanoseconds: 400_000_000)
            preparing = false
            if next.fits {
                plan = next
                LogStore.shared.log("[batch-move] confirmation shown: target=\(target) games=\(games.count) bytes=\(next.bytes) free=\(next.free ?? -1) sizes-known=\(next.allSizesKnown)")
            } else {
                let need = ByteCountFormatter.string(fromByteCount: next.needed, countStyle: .file)
                let have = ByteCountFormatter.string(fromByteCount: next.free ?? 0, countStyle: .file)
                noRoom = String(format: L("%@ has %@ free and these games need about %@. Choose fewer games."), target, have, need)
                LogStore.shared.log("[batch-move] not started: target=\(target) need=\(next.needed) free=\(next.free ?? -1) games=\(games.count)")
            }
        }
    }

    // MARK: Run

    func cancel() {
        guard running else { return }
        cancelling = true
        runTask?.cancel()
        LogStore.shared.log("[batch-move] cancel asked; the game being moved finishes first")
    }

    func start(_ confirmed: Plan) {
        guard Self.enabled, !running else { return }
        plan = nil
        running = true; cancelling = false
        total = confirmed.games.count; position = 0; currentName = ""
        rows = confirmed.games.map { Row(id: $0.id, title: $0.title) }
        // After the confirmation has closed.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if self.running, self.page == nil { self.page = .progress }
        }
        let target = confirmed.target
        let background = MoveBackground.shared
        background.batchStarted(L("Moving games"), total: confirmed.games.count) { [weak self] in self?.cancel() }
        LogStore.shared.log("[batch-move] start target=\(target) games=\(confirmed.games.count) bytes=\(confirmed.bytes) free=\(confirmed.free ?? -1)")
        runTask = Task { @MainActor in
            var moved = 0
            var skipped: [BatchResult.Note] = [], failed: [BatchResult.Note] = []
            var notDone: [Candidate] = []
            var stoppedBecause: String?
            games: for (index, item) in confirmed.games.enumerated() {
                if Task.isCancelled { notDone.append(contentsOf: confirmed.games[index...]); break games }
                if let gone = Self.targetGone(target) { stoppedBecause = gone; notDone.append(contentsOf: confirmed.games[index...]); break games }
                position = index + 1; currentName = item.title
                setRow(item.id, .moving)
                background.batchStep(done: index, title: String(format: L("Moving %d of %d"), index + 1, confirmed.games.count))
                switch await moveOne(item, to: target) {
                case .moved:
                    moved += 1; setRow(item.id, .moved)
                    LogStore.shared.log("[batch-move] \(index + 1)/\(confirmed.games.count) \(item.title) moved")
                case .skipped(let why):
                    skipped.append(.init(name: item.title, reason: why)); setRow(item.id, .skipped(why))
                    LogStore.shared.log("[batch-move] \(index + 1)/\(confirmed.games.count) \(item.title) skipped: \(why)")
                case .failed(let why):
                    failed.append(.init(name: item.title, reason: why)); setRow(item.id, .failed(why))
                    LogStore.shared.log("[batch-move] \(index + 1)/\(confirmed.games.count) \(item.title) failed: \(why)")
                case .driveGone(let drive):
                    // Not a failure of the game: nothing was moved. It and the rest wait for Move Remaining Games.
                    stoppedBecause = String(format: L("%@ isn't connected. Connect it, then tap Move Remaining Games."), drive)
                    setRow(item.id, .waiting)
                    LogStore.shared.log("[batch-move] \(index + 1)/\(confirmed.games.count) \(item.title) stopped: \(drive) is not available")
                    notDone.append(contentsOf: confirmed.games[index...])
                    break games
                }
            }
            let cancelled = Task.isCancelled
            // Free space left on the target, read off the main thread.
            let library = ExternalDrives.shared.steamTargets.first { $0.name == target }?.library
            let free = await Task.detached(priority: .utility) { () -> Int64? in
                library.flatMap { LibraryModel.drive.appendingPathComponent($0, isDirectory: true).freeSpace }
            }.value
            var headline = [String(format: L("%d moved"), moved)]
            if !skipped.isEmpty { headline.append(String(format: L("%d skipped"), skipped.count)) }
            if !failed.isEmpty { headline.append(String(format: L("%d failed"), failed.count)) }
            var finished = BatchResult(title: stoppedBecause == nil ? L("Move Finished") : L("Move Stopped"),
                                       headline: headline, skipped: skipped, failed: failed)
            finished.stopped = stoppedBecause
            if !notDone.isEmpty {
                finished.notDone = notDone.map(\.title)
                finished.notDoneText = L("Not moved. Nothing was lost.")
                finished.again = (String(format: L("Move Remaining Games (%d)"), notDone.count), notDone.map(\.id))
            }
            if let free {
                finished.footer = String(format: L("%@ has %@ free."), target, ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
            }
            LogStore.shared.log("[batch-move] end moved=\(moved) skipped=\(skipped.count) failed=\(failed.count) not-moved=\(notDone.count) cancelled=\(cancelled) stopped=\(stoppedBecause ?? "-")")
            background.batchEnded()
            running = false; cancelling = false; position = 0; total = 0; currentName = ""
            page = .result(finished)
            runTask = nil
        }
    }

    private func setRow(_ id: UUID, _ state: Row.State) {
        if let index = rows.firstIndex(where: { $0.id == id }) { rows[index].state = state }
    }

    /// Text when the target drive is no longer in the connected list (memory), else nil.
    private static func targetGone(_ target: String) -> String? {
        guard target != "This iPhone" else { return nil }
        let drives = ExternalDrives.shared
        guard let folder = drives.folders.first(where: { $0.name == target }), drives.mounted[folder.id] != nil else {
            return String(format: L("%@ isn't connected. Connect it, then tap Move Remaining Games."), target)
        }
        return nil
    }

    private func moveOne(_ item: Candidate, to target: String) async -> Outcome {
        let steam = SteamOwnedLibrary.shared
        guard let entry = entry(for: item.id) else { return .skipped(L("it is no longer in the library")) }
        if wine_process_is_running() != 0 { return .skipped(L("A game is running. Close it, then try again.")) }
        if let appID = item.appID {
            if steam.downloads[appID] != nil { return .skipped(L("Still downloading. Try again when it finishes.")) }
            // This game's own cloud check or sync: wait for it, up to 30 s (the move refuses while it runs).
            var waited = 0
            while steam.storageBusy(appID), waited < 150, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                waited += 1
            }
            if Task.isCancelled { return .skipped(L("Stopped before it started.")) }
        }
        let drives = ExternalDrives.shared
        let library = drives.steamTargets.first { $0.name == target }?.library
        let root = drives.gameTargets.first { $0.name == target }?.root
        do {
            _ = try await GameMover.shared.move(entry, toSteamLibrary: item.appID != nil ? library : nil,
                                                toRoot: item.appID != nil ? nil : root)
            return .moved
        } catch {
            let why = error.localizedDescription
            // Guards that say "not now" are skips.
            if why.hasPrefix("Wait ") || why.hasPrefix("Close ") || why.hasPrefix("Another ") { return .skipped(why) }
            // A drive that went away (the target, or this game's own drive; the error differs by when it
            // went) stops the batch instead of failing every game. The check reads the drive: off the main thread.
            let place = item.place
            let gone = await Task.detached(priority: .userInitiated) { () -> String? in
                for name in [target, place] where name != "This iPhone" && !ExternalDrives.isConnected(name) { return name }
                return nil
            }.value
            if let gone { return .driveGone(gone) }
            return .failed(why)
        }
    }
}

/// The Move Games section of Settings › External drives (M1).
struct BatchMoveSection: View {
    @ObservedObject private var batch = BatchMove.shared
    @ObservedObject private var drives = ExternalDrives.shared

    var body: some View {
        let connected = drives.folders.filter { drives.mounted[$0.id] != nil }
        if BatchMove.enabled, !connected.isEmpty || batch.running {
            Section {
                if batch.running {
                    Button { batch.page = .progress } label: {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text(String(format: L("Moving %d of %d"), batch.position, batch.total))
                        }
                    }
                } else {
                    Button(L("Move Games…")) { batch.page = .picker }
                        .disabled(batch.preparing)
                    ForEach(connected) { folder in
                        Button(String(format: L("Move All Games to %@…"), folder.name)) {
                            batch.prepare(target: folder.name, ids: nil)
                        }
                        .disabled(batch.preparing)
                    }
                    if batch.preparing {
                        HStack(spacing: 8) { ProgressView(); Text(L("Adding up sizes…")).foregroundStyle(.secondary) }
                    }
                }
            } header: { Text(L("Move Games")) } footer: {
                Text(L("Games move one after another. Keep the drive connected."))
            }
        }
    }
}

/// The confirmation, the alerts and the one sheet, on the External drives page.
struct BatchMoveDialogs: ViewModifier {
    @ObservedObject private var batch = BatchMove.shared
    @ObservedObject private var drives = ExternalDrives.shared

    func body(content: Content) -> some View {
        content
            .confirmationDialog(title, isPresented: Binding(get: { batch.plan != nil }, set: { if !$0 { batch.plan = nil } }),
                                titleVisibility: .visible, presenting: batch.plan) { plan in
                Button(plan.games.count == 1 ? L("Move 1 Game") : String(format: L("Move %d Games"), plan.games.count)) { batch.start(plan) }
                Button(L("Cancel"), role: .cancel) { LogStore.shared.log("[batch-move] confirmation cancelled: target=\(plan.target) games=\(plan.games.count)") }
            } message: { plan in
                Text(message(plan))
            }
            .alert(L("External drives"), isPresented: Binding(get: { drives.steamNote != nil }, set: { if !$0 { drives.steamNote = nil } })) {
                Button(L("OK"), role: .cancel) { drives.steamNote = nil }
            } message: { Text(drives.steamNote ?? "") }
            .alert(L("Move Games"), isPresented: Binding(get: { batch.noRoom != nil }, set: { if !$0 { batch.noRoom = nil } })) {
                Button(L("OK"), role: .cancel) { batch.noRoom = nil }
            } message: { Text(batch.noRoom ?? "") }
            .sheet(item: $batch.page) { page in
                switch page {
                case .picker: BatchMovePicker()
                case .progress: BatchMoveProgress()
                case .result(let result):
                    BatchResultSheet(result: result) { ids in
                        batch.prepare(target: target(of: result), ids: Set(ids))
                    }
                }
            }
    }

    /// The drive the stopped or cancelled batch was moving to (the confirmation's target is gone by then).
    private func target(of result: BatchResult) -> String { BatchMove.shared.lastTarget }

    private var title: String {
        guard let plan = batch.plan else { return "" }
        return plan.games.count == 1 ? String(format: L("Move 1 game to %@?"), plan.target)
                                     : String(format: L("Move %d games to %@?"), plan.games.count, plan.target)
    }

    private func message(_ plan: BatchMove.Plan) -> String {
        let size = ByteCountFormatter.string(fromByteCount: plan.bytes, countStyle: .file)
        var text = plan.bytes == 0 ? "" : (plan.allSizesKnown ? String(format: L("About %@. "), size) : String(format: L("At least %@. "), size))
        if let free = plan.free {
            text += String(format: L("%@ has %@ free. "), plan.target, ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
        }
        return text + L("Each game is copied, checked, then deleted from where it was, one at a time. Keep the drive connected until it finishes.")
    }
}

extension View {
    func batchMoveDialogs() -> some View { modifier(BatchMoveDialogs()) }
}

/// Moving Games: where the batch is, each game's state, Cancel After This Game.
struct BatchMoveProgress: View {
    @ObservedObject private var batch = BatchMove.shared
    @ObservedObject private var mover = GameMover.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(format: L("Moving %d of %d"), batch.position, batch.total)).font(.headline)
                        ProgressView(value: min(1, (Double(max(0, batch.position - 1)) + mover.progress) / Double(max(1, batch.total))))
                        if !batch.currentName.isEmpty {
                            Text("\(batch.currentName) · \(Int(mover.progress * 100))%").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    ForEach(batch.rows) { row in
                        HStack {
                            Text(row.title)
                            Spacer()
                            Text(label(row.state)).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    Button(batch.cancelling ? L("Stopping after this game…") : L("Cancel After This Game"), role: .destructive) { batch.cancel() }
                        .disabled(batch.cancelling || !batch.running)
                } footer: {
                    Text(L("You can leave this screen. Moving keeps going in the background."))
                }
            }
            .navigationTitle(L("Moving Games"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L("Hide")) { dismiss() } } }
        }
    }

    private func label(_ state: BatchMove.Row.State) -> String {
        switch state {
        case .waiting: return L("Waiting")
        case .moving: return L("Moving…")
        case .moved: return L("Moved ✓")
        case .skipped: return L("Skipped")
        case .failed: return L("Failed")
        }
    }
}

/// Move Games (M2): the drive, the games, and the bar with Select All, the sizes and Move.
struct BatchMovePicker: View {
    @ObservedObject private var batch = BatchMove.shared
    @ObservedObject private var drives = ExternalDrives.shared
    @ObservedObject private var library = LibraryModel.shared
    @ObservedObject private var steamGames = SteamGamesModel.shared
    @Environment(\.dismiss) private var dismiss
    @State private var target = ""
    @State private var chosen = Set<UUID>()

    var body: some View {
        let places = drives.steamTargets.map(\.name)
        let place = places.contains(target) ? target : (places.dropFirst().first ?? places.first ?? "")
        let list = batch.candidates(to: place)
        let valid = Set(chosen.map { batch.current($0) }).intersection(list.map(\.id))
        NavigationStack {
            List {
                Section(L("Move to")) {
                    ForEach(places, id: \.self) { name in
                        Button {
                            target = name; chosen = []
                        } label: {
                            HStack {
                                Text(name).foregroundStyle(.primary)
                                Spacer()
                                if name == place { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }
                        }
                    }
                }
                Section(String(format: L("Games (%d selected)"), valid.count)) {
                    if list.isEmpty { Text(L("Every game is already there.")).foregroundStyle(.secondary) }
                    ForEach(list) { item in
                        Button {
                            if valid.contains(item.id) { chosen = Set(chosen.filter { batch.current($0) != item.id }) } else { chosen.insert(item.id) }
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: valid.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(valid.contains(item.id) ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).foregroundStyle(.primary)
                                    Text(detail(item)).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(L("Move Games"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button(valid.count == list.count && !list.isEmpty ? L("Select None") : L("Select All")) {
                        chosen = valid.count == list.count ? [] : Set(list.map(\.id))
                    }
                    Spacer()
                    Text(sumText(valid, place: place)).font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Move")) {
                        dismiss()
                        batch.prepare(target: place, ids: valid)
                    }
                    .fontWeight(.bold)
                    .disabled(valid.isEmpty || batch.preparing)
                }
            }
            .onAppear { batch.loadPickerFacts(target: place) }
            .onChange(of: place) { _, _ in batch.loadPickerFacts(target: place) }
            .onChange(of: steamGames.games.count) { _, _ in batch.loadPickerFacts(target: place) }
        }
    }

    private func detail(_ item: BatchMove.Candidate) -> String {
        let size = batch.sizes[item.id].map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "…"
        return "\(item.place) · \(size)"
    }

    /// "28 GB · needs 28 GB of 420 GB free".
    private func sumText(_ ids: Set<UUID>, place: String) -> String {
        guard !ids.isEmpty else { return "" }
        var bytes: Int64 = 0
        for id in ids { bytes += batch.sizes[id] ?? 0 }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        guard let free = batch.freeByTarget[place] else { return size }
        let needed = ByteCountFormatter.string(fromByteCount: bytes + Int64(ids.count) * BatchMove.marginPerGame, countStyle: .file)
        return String(format: L("%@ · needs %@ of %@ free"), size, needed, ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
    }
}
