import SwiftUI
import UniformTypeIdentifiers
import BackgroundTasks

/// Folders the user picked outside the app, usually on a USB or SSD drive.
///
/// iOS only lets the app reach them through the folder picker. The picked URL
/// is kept as a bookmark in Documents/madeira-external.json, and on every launch
/// (before the wineserver starts) each one is opened again and linked into the
/// prefix twice: as drive_c/External/<name>, so the library and the executable
/// browser work unchanged, and as dosdevices/<letter>:, so Windows lists it as a
/// drive. A folder whose drive is not plugged in is left out until next time.
struct ExternalFolder: Codable, Identifiable {
    var id = UUID()
    var name: String
    var letter: String
    var bookmark: Data
    /// Madeira's Steam downloads go to <folder>/SteamLibrary on this drive.
    var steamInstalls: Bool? = nil
    var libraryID: String? = nil
}

final class ExternalDrives: ObservableObject {
    static let shared = ExternalDrives()
    @Published private(set) var folders: [ExternalFolder] = []
    /// Folders opened this launch, by id, with the path they resolved to.
    @Published private(set) var mounted: [UUID: URL] = [:]
    /// The note shown after adding a folder where no Steam library was found.
    @Published var steamNote: String?

    private static var store: URL { LibraryModel.documents.appendingPathComponent("madeira-external.json") }
    static var linkRoot: URL { MadeiraDock.drive.appendingPathComponent("External", isDirectory: true) }
    private static var dosdevices: URL { MadeiraDock.prefix.appendingPathComponent("dosdevices", isDirectory: true) }

    /// Steam libraries (drive_c-relative steamapps folders) on the drives opened
    /// this launch, and the one Steam downloads go to. Read from any thread
    /// (MadeiraDock.games runs off the main thread), so kept behind a lock.
    private static let lock = NSLock()
    private static var libraries: [String] = []
    private static var installTarget: String?
    private static var installMissing: String?
    private static var opened: [String: (root: URL, identity: String?)] = [:]
    /// When each opened root last passed validateRoot (a directory read and a
    /// marker-file read on the drive). A drive busy with a download can take
    /// seconds to answer, and the Steam cloud check asked on the main thread
    /// (iOS killed Madeira for that, 0x8BADF00D, Nov 17). Only callers that pass
    /// `cached: true` (read-only Steam cloud lookups) reuse a pass, for 30 s.
    /// Off with `env.MADEIRA_EXTERNAL_VERIFY_CACHE = 0`.
    private static var verifiedAt: [String: Date] = [:]
    private static let verifyCacheSeconds: TimeInterval = 30
    private var loadFailure: Error?
    static var steamLibraries: [String] { lock.lock(); defer { lock.unlock() }; return libraries }
    /// The library Madeira's Steam downloads go to, or nil for drive_c's own.
    static var steamInstallLibrary: String? { lock.lock(); defer { lock.unlock() }; return installTarget }
    /// The name of the drive Steam downloads go to when it is not connected.
    static var steamInstallMissing: String? { lock.lock(); defer { lock.unlock() }; return installMissing }
    /// Where Steam libraries are looked for inside a picked folder.
    private static let libraryFolders = ["", "SteamLibrary", "Steam", "Program Files (x86)/Steam", "Program Files/Steam"]

    private init() {
        do {
            let data = try Data(contentsOf: Self.store)
            guard data.count <= 32 << 20 else { throw ExternalStorageError.invalidRecord }
            let list = try JSONDecoder().decode([ExternalFolder].self, from: data)
            try Self.validate(list)
            folders = list
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { }
        catch { loadFailure = error; LogStore.shared.log("[external] saved registrations could not be read; files kept") }
    }

    private static func validate(_ list: [ExternalFolder]) throws {
        guard list.count <= 22, Set(list.map(\.id)).count == list.count,
              list.filter({ $0.steamInstalls == true }).count <= 1,
              Set(list.map { $0.name.lowercased() }).count == list.count,
              Set(list.map(\.letter)).count == list.count else { throw ExternalStorageError.invalidRecord }
        for folder in list {
            guard try ExternalStoragePath.components(folder.name) == [folder.name],
                  folder.letter.count == 1, "defghijklmnopqrstuvwxy".contains(folder.letter),
                  !folder.bookmark.isEmpty, folder.bookmark.count <= 1 << 20,
                  folder.libraryID == nil || UUID(uuidString: folder.libraryID!) != nil else { throw ExternalStorageError.invalidRecord }
        }
    }

    private func save(_ list: [ExternalFolder]) throws {
        if let loadFailure { throw loadFailure }
        try Self.validate(list)
        try JSONEncoder().encode(list).write(to: Self.store, options: .atomic)
        folders = list
    }

    private func publishOpened() {
        let next = Dictionary(uniqueKeysWithValues: folders.compactMap { folder in
            mounted[folder.id].map { (folder.name, (root: $0, identity: folder.libraryID)) }
        })
        Self.lock.lock(); Self.opened = next; Self.verifiedAt = [:]; Self.lock.unlock()
    }

    static func externalRoot(for relative: String, cached: Bool = false) throws -> (root: URL, identity: String?)? {
        guard let name = driveName(library: relative) else { return nil }
        lock.lock(); let folder = opened[name]; lock.unlock()
        guard let folder else { throw ExternalStorageError.unavailable }
        let cacheOn = cached && MadeiraConfig.flag("MADEIRA_EXTERNAL_VERIFY_CACHE")
        if cacheOn {
            lock.lock(); let at = verifiedAt[folder.root.path]; lock.unlock()
            if let at, Date().timeIntervalSince(at) < verifyCacheSeconds { return folder }
        }
        try validateRoot(folder.root, identity: folder.identity)
        if cacheOn { lock.lock(); verifiedAt[folder.root.path] = Date(); lock.unlock() }
        return folder
    }

    private static func validateRoot(_ root: URL, identity: String?) throws {
        guard try root.checkResourceIsReachable(),
              try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw ExternalStorageError.unavailable }
        if let identity { try ExternalStorageIdentity.verify(identity, root: root) }
    }

    static func nativeURL(_ relative: String, write: Bool = false, cached: Bool = false) throws -> URL {
        _ = try ExternalStoragePath.components(relative)
        guard let external = try externalRoot(for: relative, cached: cached) else { return MadeiraDock.drive.appendingPathComponent(relative) }
        if write, try external.root.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly == true {
            throw CocoaError(.fileWriteVolumeReadOnly)
        }
        let parts = try ExternalStoragePath.components(relative)
        return parts.count == 2 ? external.root : try ExternalStoragePath.native(parts.dropFirst(2).joined(separator: "/"), root: external.root)
    }

    /// Opens every saved folder and refreshes the links. Safe to call again; it
    /// must run before the wineserver starts for Windows to list the drives.
    @MainActor func mountAll() {
        guard loadFailure == nil, wine_process_is_running() == 0 else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.linkRoot, withIntermediateDirectories: true)
        try? fm.createDirectory(at: Self.dosdevices, withIntermediateDirectories: true)
        var next = folders
        for i in folders.indices {
            let folder = folders[i]
            if let root = mounted[folder.id], (try? Self.validateRoot(root, identity: folder.libraryID)) != nil { continue }
            mounted.removeValue(forKey: folder.id)?.stopAccessingSecurityScopedResource()
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: folder.bookmark, bookmarkDataIsStale: &stale)
                guard url.startAccessingSecurityScopedResource() else { throw ExternalStorageError.unavailable }
                do {
                    try Self.validateRoot(url, identity: folder.libraryID)
                    try link(folder, to: url, owned: true)
                    if stale { next[i].bookmark = try url.bookmarkData() }
                    mounted[folder.id] = url
                } catch { url.stopAccessingSecurityScopedResource(); throw error }
            } catch {
                LogStore.shared.log("[external] \(folder.name) unavailable: \(error.localizedDescription)")
                unlink(folder)
            }
        }
        do { try save(next) } catch { LogStore.shared.log("[external] bookmark refresh could not be saved") }
        publishOpened()
        refreshSteam()
        SteamOwnedLibrary.shared.externalStorageReconnected()
    }

    /// Finds the Steam libraries on the opened drives, makes the chosen download
    /// folder, and lists them all in the Steam client's libraryfolders.vdf so
    /// Valve's client (started by Madeira Dock) can start their games.
    func refreshSteam() {
        let fm = FileManager.default
        var found: [String] = [], target: String?, missing: String?
        var deepOnes: Set<String> = []          // libraries from the two-level search: kept out of the log loop below (no disk read)
        loadDeepCacheOnce()
        for folder in folders {
            if folder.steamInstalls == true { target = "External/\(folder.name)/SteamLibrary/steamapps" }
            guard mounted[folder.id] != nil, Self.isConnected(folder.name) else {
                if folder.steamInstalls == true { missing = folder.name }
                deepCache[folder.id] = nil          // a drive that is not here has no libraries to keep
                continue
            }
            if folder.steamInstalls == true {
                do {
                    let common = try Self.nativeURL("External/\(folder.name)/SteamLibrary/steamapps/common", write: true)
                    try fm.createDirectory(at: common, withIntermediateDirectories: true)
                } catch { missing = folder.name }
            }
            for sub in Self.libraryFolders {
                let apps = sub.isEmpty ? "steamapps" : sub + "/steamapps"
                var isDir: ObjCBool = false
                if let appsURL = try? Self.nativeURL("External/\(folder.name)/" + apps),
                   fm.fileExists(atPath: appsURL.path, isDirectory: &isDir), isDir.boolValue {
                    found.append("External/\(folder.name)/" + apps)
                }
            }
            // The folder holds none of the usual libraries: a search one and two folders down for a real "steamapps"
            // (a drive added from its root, or from a folder above Steam's) runs OFF the main thread; this pass only reads its
            // kept result. env.MADEIRA_EXTERNAL_DEEP_SEARCH = 0 turns the search and its alert off.
            // It runs for every folder (a library Madeira made itself, SteamLibrary, must not hide the others), and its result
            // is kept until a newer successful search replaces it, so a refresh in between never drops those games.
            if Self.deepSearchOn {
                let cached = deepCache[folder.id]
                if cached.map({ Date().timeIntervalSince($0.at) > Self.deepRecheckAfter }) ?? true { startDeepSearch(folder) }
                let usual = found.filter { $0.hasPrefix("External/\(folder.name)/") }
                for path in cached?.libraries ?? [] {
                    let full = "External/\(folder.name)/" + path
                    // Not one the usual places already gave, and not inside one of them.
                    if usual.contains(where: { $0.caseInsensitiveCompare(full) == .orderedSame }) { continue }
                    // A usual library at the folder's top (External/<name>/steamapps) is the one pair already allowed beside others.
                    let rootDir = "External/\(folder.name)/".lowercased()
                    if usual.contains(where: { u in
                        let dir = String(u.dropLast("steamapps".count)).lowercased()
                        return dir != rootDir && full.lowercased().hasPrefix(dir)
                    }) { continue }
                    found.append(full); deepOnes.insert(full)
                }
            }
        }
        // What each drive library holds, to tell a moved game's state from the log.
        for library in found where !deepOnes.contains(library) {
            let apps = MadeiraDock.drive.appendingPathComponent(library)
            let records = ((try? fm.contentsOfDirectory(atPath: apps.path)) ?? []).filter { $0.hasPrefix("appmanifest_") }
            let folders = (try? fm.contentsOfDirectory(atPath: apps.appendingPathComponent("common").path)) ?? []
            LogStore.shared.log("[external] \(library) records=\(records.count) folders=\(folders.sorted().joined(separator: "|"))")
        }
        Self.lock.lock(); Self.libraries = found; Self.installTarget = target; Self.installMissing = missing; Self.lock.unlock()
        Self.listInSteamClient(found.map { String($0.dropLast("/steamapps".count)) })
        LogStore.shared.log("[external] steam libraries=\(found.count) install=\(target ?? "drive_c")")
    }

    // MARK: Two-level Steam library search (off the main thread)

    static var deepSearchOn: Bool { MadeiraConfig.flag("MADEIRA_EXTERNAL_DEEP_SEARCH", fallback: true) }
    /// A search result is re-made (off the main thread, which also drops a library that went away) when it is older than this.
    private static let deepRecheckAfter: TimeInterval = 20
    /// Result of the last successful search per folder (libraries relative to the folder; empty = looked, found none).
    /// A failed read never replaces it (a drive that is busy for a moment must not make its games vanish); it is dropped
    /// when the folder is removed or unmounted.
    private var deepCache: [UUID: (libraries: [String], at: Date)] = [:]
    private var deepRunning: Set<UUID> = []
    /// Folders just added whose "no Steam games" note has not been decided yet, and the ones already told (once each).
    private var notePending: Set<UUID> = []
    private var noteGiven: Set<UUID> = []

    /// The last search results are kept in UserDefaults (no drive read), so the first scan after a launch already lists those
    /// libraries; they count as old, so a new search starts at once and replaces them.
    private static let deepKey = "madeiraExternalDeepLibraries.v1"
    private var deepLoaded = false
    private func loadDeepCacheOnce() {
        guard !deepLoaded else { return }
        deepLoaded = true
        guard let stored = UserDefaults.standard.dictionary(forKey: Self.deepKey) as? [String: [String]] else { return }
        for (key, libraries) in stored { if let id = UUID(uuidString: key) { deepCache[id] = (libraries, .distantPast) } }
    }
    private func saveDeepCache() {
        var stored: [String: [String]] = [:]
        for (id, value) in deepCache where !value.libraries.isEmpty { stored[id.uuidString] = value.libraries }
        UserDefaults.standard.set(stored, forKey: Self.deepKey)
    }

    private func startDeepSearch(_ folder: ExternalFolder) {
        guard !deepRunning.contains(folder.id) else { return }
        deepRunning.insert(folder.id)
        let id = folder.id, name = folder.name
        let previous = deepCache[id]?.libraries ?? []
        Task.detached(priority: .utility) { [weak self] in
            let result = Self.deepSearch(name: name, previous: previous)
            await MainActor.run { self?.finishDeepSearch(id: id, name: name, result: result) }
        }
    }

    @MainActor private func finishDeepSearch(id: UUID, name: String, result: (libraries: [String], checked: Int, failed: Int)?) {
        deepRunning.remove(id)
        let decide = notePending.remove(id) != nil          // the note is decided once, by the first search that ends
        guard folders.contains(where: { $0.id == id && $0.name == name }), mounted[id] != nil else { deepCache[id] = nil; return }
        guard let result else {
            // The drive could not be read at all: the last good result stays, and nothing is searched again before the next refresh.
            LogStore.shared.log("[external] \(name): the two-level search could not read the drive; the last result is kept")
            return
        }
        var libraries = result.libraries
        if result.failed > 0 {
            // Some folders could not be read: keep what was known before, so a library in one of them is not lost.
            for old in deepCache[id]?.libraries ?? [] where !libraries.contains(old) { libraries.append(old) }
        }
        let before = deepCache[id]?.libraries
        deepCache[id] = (libraries, Date())
        saveDeepCache()
        if before != libraries {
            LogStore.shared.log("[external] \(name): two-level search for 'steamapps' looked in \(result.checked) places (\(result.failed) unreadable), found \(libraries.isEmpty ? "none" : libraries.joined(separator: ", "))")
            refreshSteam()
            SteamGamesModel.shared.refresh()
        }
        guard decide, libraries.isEmpty, result.failed == 0, !noteGiven.contains(id) else { return }
        // After the picker and the Find games sheet have closed: an alert shown now can be dropped. Re-checked then.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard Self.deepSearchOn, !self.noteGiven.contains(id),
                  let folder = self.folders.first(where: { $0.id == id }), self.mounted[id] != nil,
                  let cached = self.deepCache[id], cached.libraries.isEmpty,
                  !Self.steamLibraries.contains(where: { $0.hasPrefix("External/\(folder.name)/") }) else { return }
            self.noteGiven.insert(id)
            self.steamNote = String(format: L("No Steam games found in '%@'. If your Steam games are on this drive, remove it and add the folder that contains 'steamapps'."), folder.name)
        }
    }

    /// Words in a folder name that mark a copy rather than a live library.
    private static let copyWords: Set<String> = ["backup", "backups", "bak", "old", "copy", "trash", "recycle", "archive", "archived"]
    private static func looksLikeCopy(_ name: String) -> Bool {
        name.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { copyWords.contains(String($0)) }
    }
    /// Folders no library is looked for in (hidden, the recycle bin, system folders).
    private static func skipped(_ name: String) -> Bool {
        name.hasPrefix(".") || name.hasPrefix("$") || name.contains(":") || ["system volume information", "lost+found", "found.000", "common", "recovery"].contains(name.lowercased())
    }

    /// The libraries one and two folders below External/<name>, or nil when the folder itself cannot be read; a folder below that
    /// cannot be read is skipped and counted in `failed`. Disk reads: off the main thread only.
    /// A library is a plain Steam one: a folder called steamapps that holds a "common" folder and an appmanifest_*.acf, in a path
    /// whose names do not say backup/old/copy/trash. Never a library and one inside it. No cap on how many folders are looked at.
    nonisolated private static func deepSearch(name: String, previous: [String]) -> (libraries: [String], checked: Int, failed: Int)? {
        let fm = FileManager.default
        guard let root = try? nativeURL("External/\(name)"), let top = try? fm.contentsOfDirectory(atPath: root.path) else { return nil }
        func folderNames(_ url: URL) -> [String]? {
            guard let names = try? fm.contentsOfDirectory(atPath: url.path) else { return nil }
            return names.sorted().filter { child in
                var isDir: ObjCBool = false
                return !skipped(child) && fm.fileExists(atPath: url.appendingPathComponent(child).path, isDirectory: &isDir) && isDir.boolValue
            }
        }
        var libraries: [String] = [], checked = 0, failed = 0
        for first in top.sorted() where !skipped(first) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.appendingPathComponent(first).path, isDirectory: &isDir), isDir.boolValue else { continue }
            let seconds: [String] = folderNames(root.appendingPathComponent(first)) ?? { failed += 1; return [] }()
            for path in [first + "/steamapps"] + seconds.map({ first + "/" + $0 + "/steamapps" }) {
                checked += 1
                if path.split(separator: "/").contains(where: { looksLikeCopy(String($0)) }) { continue }
                let url = root.appendingPathComponent(path)
                var apps: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &apps), apps.boolValue else { continue }
                guard let inside = try? fm.contentsOfDirectory(atPath: url.path) else { failed += 1; continue }
                var common: ObjCBool = false
                guard inside.contains(where: { $0.hasPrefix("appmanifest_") && $0.hasSuffix(".acf") }),
                      fm.fileExists(atPath: url.appendingPathComponent("common").path, isDirectory: &common), common.boolValue else { continue }
                if libraries.contains(where: { path.hasPrefix($0.dropLast("steamapps".count)) }) { continue }
                libraries.append(path)
            }
        }
        // A library found last time and not now: it is dropped only when it is really gone. A stat that failed for another
        // reason (the drive hiccuped) counts as unreadable, which keeps it.
        for old in previous where !libraries.contains(old) {
            do { _ = try fm.attributesOfItem(atPath: root.appendingPathComponent(old).path) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { continue }
            catch { failed += 1 }
        }
        return (libraries, checked, failed)
    }

    /// Adds `C:\<folder>` entries for the libraries Valve's client does not list yet, and
    /// drops a leftover External entry above one of them (ExternalSteamLibraries.staleParents).
    /// Both of the client's libraryfolders.vdf files are written: config/ is the one Valve's
    /// client reads, steamapps/ its copy (the same pair Big Picture's ml2230 writes).
    private static func listInSteamClient(_ relative: [String]) {
        guard !relative.isEmpty else { return }
        let paths = [SteamRuntimeFiles.relativeRoot] + relative
        // DJMAX RESPECT V (Sentry Nov 16, 0.2.26): a drive held a library at its top (SteamLibrary_Win) and Madeira's
        // own one inside it (SteamLibrary_Win/SteamLibrary); both were written, but Valve's client later listed only the
        // top one and the game in the inner one stopped with code 41. Log such pairs so the next report shows whether
        // the client dropped the inner library (cause not proven).
        // env.MADEIRA_EXTERNAL_NESTED_LOG = 0 turns the line off.
        for outer in relative where MadeiraConfig.flag("MADEIRA_EXTERNAL_NESTED_LOG", fallback: true) {
            for inner in relative where inner.hasPrefix(outer + "/") {
                LogStore.shared.log("[external] nested libraries: C:\\\(outer.replacingOccurrences(of: "/", with: "\\")) holds C:\\\(inner.replacingOccurrences(of: "/", with: "\\")); both are listed in libraryfolders.vdf")
            }
        }
        // Drive libraries: a leftover entry above a drive's Steam library (C:\External\steam
        // when the games are in C:\External\steam\SteamLibrary) is removed from Steam's
        // libraryfolders.vdf, so Valve's client lists the real library and Dock does not stop
        // with code 41. 0 keeps every entry.
        let prune = MadeiraConfig.flag("MADEIRA_EXTERNAL_PRUNE_PARENT_LIBRARIES", fallback: true)
        // Drive libraries: Madeira also lists them in Steam's config/libraryfolders.vdf (the
        // file Valve's client reads), when it exists, beside steamapps/libraryfolders.vdf.
        // 0 writes steamapps/ only.
        let subfolders = MadeiraConfig.flag("MADEIRA_EXTERNAL_STEAM_CONFIG_VDF", fallback: true) ? ["config", "steamapps"] : ["steamapps"]
        for sub in subfolders {
            let vdf = MadeiraDock.drive.appendingPathComponent(SteamRuntimeFiles.relativeRoot + "/" + sub + "/libraryfolders.vdf")
            do {
                let existing: Data?
                do { existing = try Data(contentsOf: vdf) }
                catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { existing = nil }
                // config/ is Valve's own: only an existing one is updated, never created.
                if sub == "config" && existing == nil { continue }
                let data = try ExternalSteamLibraries.add(paths: paths, to: existing, pruneParents: prune)
                guard data != existing else { continue }
                try FileManager.default.createDirectory(at: vdf.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: vdf, options: .atomic)
                LogStore.shared.log("[external] \(sub)/libraryfolders.vdf updated (libraries=\(relative.count) prune=\(prune ? 1 : 0))")
            } catch { LogStore.shared.log("[external] Steam \(sub) library metadata was kept: \(error.localizedDescription)") }
        }
    }

    /// "External/<name>/..." -> "<name>", or nil for drive_c.
    static func driveName(library: String) -> String? {
        let parts = library.split(separator: "/", maxSplits: 2).map(String.init)
        return parts.count >= 2 && parts[0] == "External" ? parts[1] : nil
    }
    static func isConnected(_ name: String) -> Bool {
        (try? externalRoot(for: "External/" + name)) != nil
    }
    /// Places a Steam game can be installed or moved to: this device's own
    /// library and <folder>/SteamLibrary on each connected drive.
    var steamTargets: [(name: String, library: String)] {
        [("This iPhone", SteamInstallPaths.libraryRelative)] + folders.filter { mounted[$0.id] != nil }
            .map { ($0.name, "External/\($0.name)/SteamLibrary/steamapps") }
    }
    /// Places a non-Steam game can be moved to: drive_c/Games, or <folder>/Games.
    var gameTargets: [(name: String, root: String)] {
        [("This iPhone", "Games")] + folders.filter { mounted[$0.id] != nil }.map { ($0.name, "External/\($0.name)/Games") }
    }

    /// Sends Madeira's Steam downloads to this folder (nil: back to drive_c).
    func setSteamInstalls(_ id: UUID?) {
        var next = folders
        for i in next.indices { next[i].steamInstalls = next[i].id == id ? true : nil }
        do { try save(next); refreshSteam() }
        catch { LogStore.shared.log("[external] install target was not changed: \(error.localizedDescription)") }
    }

    /// Adds a folder picked with the folder picker and links it right away.
    func add(_ url: URL) throws {
        if let loadFailure { throw loadFailure }
        guard wine_process_is_running() == 0 else { throw LibraryError.message("Close the running game before adding a drive.") }
        guard url.startAccessingSecurityScopedResource() else { throw LibraryError.message("Madeira could not open that folder.") }
        let bookmark: Data
        do { bookmark = try url.bookmarkData() } catch { url.stopAccessingSecurityScopedResource(); throw error }
        let used = Set(folders.map(\.letter))
        guard let letter = "defghijklmnopqrstuvwxy".map(String.init).first(where: {
            !used.contains($0) && (try? FileManager.default.attributesOfItem(atPath: Self.dosdevices.appendingPathComponent($0 + ":").path)) == nil
        }) else {
            url.stopAccessingSecurityScopedResource()
            throw LibraryError.message("No free drive letters.")
        }
        var name = url.lastPathComponent.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined()
        if name.isEmpty { name = "Drive" }
        let base = name; var n = 2
        while folders.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { name = "\(base) \(n)"; n += 1 }
        var folder = ExternalFolder(name: name, letter: letter, bookmark: bookmark)
        do {
            guard !mounted.values.contains(where: { $0.resolvingSymlinksInPath() == url.resolvingSymlinksInPath() }) else {
                throw LibraryError.message("That folder is already registered.")
            }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isUbiquitousItemKey, .volumeIsLocalKey, .volumeIsReadOnlyKey])
            guard values.isDirectory == true, values.isUbiquitousItem != true, values.volumeIsLocal == true else {
                throw LibraryError.message("Choose a folder on a local USB or SSD drive.")
            }
            if values.volumeIsReadOnly != true { folder.libraryID = try ExternalStorageIdentity.register(root: url) }
            try Self.validate(folders + [folder])
            try link(folder, to: url, owned: false)
            do { try save(folders + [folder]) } catch { unlink(folder); throw error }
            mounted[folder.id] = url
        } catch { url.stopAccessingSecurityScopedResource(); throw error }
        publishOpened()
        // The two-level search (off the main thread) decides, when it ends, whether this folder gets a "no Steam games" note.
        if Self.deepSearchOn { notePending.insert(folder.id) }
        refreshSteam()
        LogStore.shared.log("[external] added \(letter.uppercased()): \(name) -> \(url.path)")
    }

    /// Forgets a folder. Its files stay on the drive; the library entries that
    /// start programs on it (and its Steam games' entries) are removed.
    @MainActor func remove(_ id: UUID) {
        guard let folder = folders.first(where: { $0.id == id }) else { return }
        guard wine_process_is_running() == 0, GameMover.shared.moving == nil,
              SteamOwnedLibrary.shared.moveBlocker("external") == nil else {
            LogStore.shared.log("[external] drive kept while a game, download or cloud operation uses storage")
            return
        }
        do { try save(folders.filter { $0.id != id }) }
        catch { LogStore.shared.log("[external] drive registration could not be removed"); return }
        let prefix = "External/\(folder.name)/"
        let library = LibraryModel.shared
        for entry in library.entries where entry.relativePath.hasPrefix(prefix) {
            if let appID = entry.steamAppID { library.removeSteam(appID: appID) } else { library.remove(entry.id) }
        }
        unlink(folder)
        mounted.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
        deepCache[id] = nil; notePending.remove(id); saveDeepCache()
        publishOpened()
        refreshSteam()
        Task { @MainActor in SteamGamesModel.shared.refresh() }
        LogStore.shared.log("[external] removed \(folder.name)")
    }

    private func link(_ folder: ExternalFolder, to url: URL, owned: Bool) throws {
        let fm = FileManager.default
        for container in [Self.linkRoot, Self.dosdevices] {
            try fm.createDirectory(at: container, withIntermediateDirectories: true)
            guard try fm.attributesOfItem(atPath: container.path)[.type] as? FileAttributeType == .typeDirectory else {
                throw ExternalStorageError.mappingConflict
            }
        }
        let links = [Self.linkRoot.appendingPathComponent(folder.name), Self.dosdevices.appendingPathComponent(folder.letter + ":")]
        for path in links { try ExternalStorageMapping.validate(path, root: url, owned: owned) }
        for path in links { try ExternalStorageMapping.replace(path, root: url, owned: owned) }
    }

    private func unlink(_ folder: ExternalFolder) {
        // Only links are removed, never what they point at.
        for path in [Self.linkRoot.appendingPathComponent(folder.name).path,
                     Self.dosdevices.appendingPathComponent(folder.letter + ":").path] {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil { try? FileManager.default.removeItem(atPath: path) }
        }
    }

    /// The real roots of the folders opened this launch.
    var roots: [(name: String, path: String)] {
        folders.compactMap { f in mounted[f.id].map { (f.name, $0.resolvingSymlinksInPath().path) } }
    }
}

/// Games already on an external folder: the programs that look like a game's
/// own executable, a few folders deep. Steam libraries are left to Steam.
enum ExternalGameScan {
    private static let skipNames = ["unins", "setup", "install", "redist", "vcredist", "vc_redist", "dxsetup", "directx",
                                    "dotnet", "crash", "report", "update", "patch", "launcherhelper", "helper", "cef",
                                    "touchup", "easyanticheat", "battleye", "ue4prereq", "prereq", "config", "settings"]
    private static let skipFolders: Set<String> = ["steamapps", "_commonredist", "commonredist", "redist",
                                                   "redistributables", "directx", "dotnet", "vcredist", "__installer", "windows", "system32",
                                                   "$recycle.bin", "system volume information", "engine", "node_modules"]

    /// Every subfolder is searched, within a budget of folders and time so a
    /// huge drive still returns.
    static func scan(_ root: URL) -> [URL] {
        var found: [URL] = [], budget = Budget()
        walk(root, depth: 40, into: &found, budget: &budget)
        return found
    }

    private struct Budget { var folders = 0; let deadline = Date().addingTimeInterval(20) }

    private static func walk(_ folder: URL, depth: Int, into found: inout [URL], budget: inout Budget) {
        budget.folders += 1
        guard found.count < 1000, budget.folders < 50_000, Date() < budget.deadline, let items = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles) else { return }
        for item in items.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let name = item.lastPathComponent.lowercased()
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if depth > 0, !skipFolders.contains(name), !item.isSymlink { walk(item, depth: depth - 1, into: &found, budget: &budget) }
            } else if item.pathExtension.lowercased() == "exe", !skipNames.contains(where: { name.hasPrefix($0) || name.contains("_" + $0) || name.contains("-" + $0) }) {
                found.append(item)
            }
        }
    }
}

private extension URL {
    var isSymlink: Bool { (try? resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true }
}

/// Lists the games found on one external folder and adds the chosen ones.
struct ExternalGamesSheet: View {
    let folder: ExternalFolder
    let root: URL
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var library = LibraryModel.shared
    @State private var found: [URL]?
    @State private var chosen: Set<URL> = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let found {
                    if found.isEmpty { Text("No games found. Steam games on this drive show up in the Steam section.").foregroundStyle(.secondary) }
                    ForEach(found, id: \.self) { url in
                        let added = isAdded(url)
                        Button { if chosen.contains(url) { chosen.remove(url) } else { chosen.insert(url) } } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(url.deletingPathExtension().lastPathComponent)
                                    Text(String(url.path.dropFirst(root.path.count + 1))).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if added { Text("Added").foregroundStyle(.secondary) }
                                else if chosen.contains(url) { Image(systemName: "checkmark") }
                            }
                        }
                        .disabled(added)
                    }
                } else {
                    HStack { ProgressView(); Text("Looking for games") }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(folder.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add \(chosen.count)") { add() }.disabled(chosen.isEmpty) }
            }
        }
        .task {
            let root = root
            found = await Task.detached(priority: .userInitiated) { ExternalGameScan.scan(root) }.value
        }
    }

    private func isAdded(_ url: URL) -> Bool {
        guard let relative = LibraryModel.relativeToDrive(url) else { return false }
        return library.entries.contains { $0.relativePath.caseInsensitiveCompare(relative) == .orderedSame }
    }

    private func add() {
        var failed: [String] = []
        for url in chosen.sorted(by: { $0.path < $1.path }) {
            do {
                var entry = try LibraryModel.inspect(url)
                // A program's own name is often generic: use its folder's.
                let parent = url.deletingLastPathComponent()
                if parent.path != root.path { entry.title = parent.lastPathComponent }
                library.save(entry)
            } catch { failed.append(url.lastPathComponent + ": " + error.localizedDescription) }
        }
        LogStore.shared.log("[external] added games=\(chosen.count - failed.count) from \(folder.name)")
        if failed.isEmpty { dismiss() } else { error = failed.joined(separator: "\n"); chosen = [] }
    }
}

/// Settings › External drives.
struct ExternalDrivesSection: View {
    @ObservedObject private var drives = ExternalDrives.shared
    @State private var picking = false
    @State private var error: String?
    @State private var scanning: ExternalFolder?
    @State private var removing: ExternalFolder?

    var body: some View {
        Group {
            // The dialogs and the sheet go on ONE view (a modifier on the Group would attach them to both).
            drivesSection.batchMoveDialogs()
            BatchMoveSection()      // BatchMove.swift: Move Games… and Move All Games to <drive>…
        }
    }

    private var drivesSection: some View {
        Section {
            ForEach(drives.folders) { folder in
                HStack {
                    Text(folder.letter.uppercased() + ":").font(.body.monospaced())
                    Text(folder.name)
                    Spacer()
                    Text(drives.mounted[folder.id] == nil ? "Not connected" : "Connected").foregroundStyle(.secondary)
                }
                .swipeActions { Button("Remove", role: .destructive) { removing = folder } }
                if drives.mounted[folder.id] != nil {
                    Button("Find games on \(folder.name)") { scanning = folder }
                }
            }
            Button("Add drive or folder") { picking = true }
            if !drives.folders.isEmpty {
                Picker("Install Steam games on", selection: Binding(
                    get: { drives.folders.first { $0.steamInstalls == true }?.id },
                    set: { drives.setSteamInstalls($0) })) {
                    Text("This iPhone").tag(UUID?.none)
                    ForEach(drives.folders) { Text($0.name).tag(UUID?.some($0.id)) }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        } header: { Text("External drives") } footer: {
            Text("Pick a folder on a USB or SSD drive, or a whole drive that already has games on it. Windows sees it as a drive letter and as C:\\External\\<name>. Find games adds the games on it to the library; Steam libraries on it (steamapps or SteamLibrary) show up in the Steam section. Install Steam games on picks where new Steam downloads go by default (each install can still pick another place); on a drive they go into <name>\\SteamLibrary. Unplugging the drive while a game runs will close it. Restart Madeira after adding a folder for Windows to list the new drive.")
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            do {
                try drives.add(try result.get()); error = nil
                SteamGamesModel.shared.refresh()
                // Offer the games already on it.
                scanning = drives.folders.last
            } catch { self.error = error.localizedDescription }
        }
        .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { folder in
            Button("Remove", role: .destructive) { drives.remove(folder.id) }
        } message: { _ in
            Text("Madeira forgets this drive and removes its games from the library. The files on the drive are kept.")
        }
        .sheet(item: $scanning) { folder in
            if let root = drives.mounted[folder.id] { ExternalGamesSheet(folder: folder, root: root.resolvingSymlinksInPath()) }
        }
    }
}

/// Moves an installed game between this device and external drives: copies
/// it, checks the copy, then deletes the original. A failed or cancelled move
/// removes the partial copy and leaves the original as it was.
@MainActor final class GameMover: ObservableObject {
    static let shared = GameMover()
    /// The entry being moved, and how far along (0...1).
    @Published private(set) var moving: UUID?
    @Published private(set) var progress = 0.0

    struct Failure: LocalizedError { let errorDescription: String? }

    /// What a non-Steam entry's move takes along: the program's folder, or the
    /// folder above it when the program sits in a bin/Win64-style subfolder.
    static func gameFolder(_ relativePath: String) -> String {
        var parts = relativePath.split(separator: "/").map(String.init).dropLast()
        let inner: Set<String> = ["bin", "bin32", "bin64", "binaries", "win32", "win64", "x86", "x64", "x86_64", "system", "game", "release", "shipping"]
        while parts.count > 1, inner.contains(parts.last!.lowercased()) { parts = parts.dropLast() }
        // Never a top-level container such as "Games" or "External/<name>" itself.
        return parts.joined(separator: "/")
    }

    /// Where a library entry is now (a drive name, or "This iPhone").
    static func place(_ relativePath: String) -> String {
        ExternalDrives.driveName(library: relativePath) ?? "This iPhone"
    }

    func move(_ entry: LibraryEntry, toSteamLibrary target: String? = nil, toRoot root: String? = nil) async throws -> LibraryEntry {
        guard moving == nil else { throw Failure(errorDescription: "Another game is being moved.") }
        guard wine_process_is_running() == 0 else { throw Failure(errorDescription: "Close the running game first.") }
        guard SteamOwnedLibrary.shared.moveBlocker("move", scoped: true, appID: entry.steamAppID) == nil else { throw Failure(errorDescription: "Wait for downloads and cloud operations to finish.") }
        var entry = entry
        var items: [(from: URL, to: URL)] = []
        var newPath: String
        if let appID = entry.steamAppID {
            guard SteamOwnedLibrary.shared.downloads[appID] == nil else { throw Failure(errorDescription: "Wait for the download to finish or cancel it first.") }
            guard let target, let game = SteamGamesModel.shared.games.first(where: { $0.id == appID }) else {
                throw Failure(errorDescription: "Steam does not list this game as installed.")
            }
            // An empty name or one of only spaces, dots and slashes would point at the whole "common" folder.
            guard !game.installDir.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n./\\")).isEmpty else {
                throw Failure(errorDescription: "This game's Steam install record has no usable folder name, so it was not moved.")
            }
            guard game.library.caseInsensitiveCompare(target) != .orderedSame else { return entry }
            guard SteamInstallPaths.isManaged(library: target) else { throw ExternalStorageError.invalidRecord }
            let fromGame = try ExternalDrives.nativeURL(game.library + "/common/" + game.installDir, write: true)
            let toGame = try ExternalDrives.nativeURL(target + "/common/" + game.installDir, write: true)
            items.append((fromGame, toGame))
            let manifest = "/appmanifest_\(appID).acf"
            items.append((try ExternalDrives.nativeURL(game.library + manifest, write: true),
                          try ExternalDrives.nativeURL(target + manifest, write: true)))
            let journal = "downloading/\(appID)"
            let fromJournal = try ExternalDrives.nativeURL(game.library + "/" + journal, write: true)
            if FileManager.default.fileExists(atPath: fromJournal.path) {
                items.append((fromJournal, try ExternalDrives.nativeURL(target + "/" + journal, write: true)))
            }
            newPath = target + "/common/" + game.installDir
        } else {
            guard let root else { throw Failure(errorDescription: "Choose where to move the game.") }
            let folder = Self.gameFolder(entry.relativePath)
            let name = (folder as NSString).lastPathComponent
            guard !folder.isEmpty, !["games", "external"].contains(folder.lowercased()), folder.split(separator: "/").count >= (folder.hasPrefix("External/") ? 3 : 1)
            else { throw Failure(errorDescription: "This game's folder cannot be moved.") }
            let dest = root + "/" + name
            guard dest.caseInsensitiveCompare(folder) != .orderedSame else { return entry }
            items.append((try ExternalDrives.nativeURL(folder, write: true), try ExternalDrives.nativeURL(dest, write: true)))
            newPath = dest + entry.relativePath.dropFirst(folder.count)
        }
        if let name = ExternalDrives.driveName(library: newPath), !ExternalDrives.isConnected(name) {
            throw Failure(errorDescription: "\(name) is not connected.")
        }
        let copy = items.map { (from: $0.from.resolvingSymlinksInPath(), to: $0.to) }

        moving = entry.id; progress = 0
        MoveBackground.shared.started(entry.title)
        defer { moving = nil; MoveBackground.shared.ended() }
        LogStore.shared.log("[move] \(entry.title): \(entry.relativePath) -> \(newPath)")
        try await Task.detached(priority: .userInitiated) {
            try Self.copyVerifyDelete(copy) { fraction in
                Task { @MainActor in GameMover.shared.progress = fraction; MoveBackground.shared.progress(fraction) }
            }
        }.value
        entry.relativePath = newPath
        LibraryModel.shared.save(entry)
        if let appID = entry.steamAppID, let target {
            SteamOwnedLibrary.shared.installMoved(appID, to: target)
            if newPath.hasPrefix("External/") { ExternalDrives.shared.refreshSteam() }
            SteamGamesModel.shared.refresh()
        }
        LogStore.shared.log("[move] done \(entry.title)")
        return entry
    }

    /// Copies one file in 8 MB pieces, reporting each piece, so a large file
    /// moves the progress bar too.
    nonisolated private static func copyFile(_ from: URL, to: URL, copied: (Int64) -> Void) throws {
        guard FileManager.default.createFile(atPath: to.path, contents: nil) else {
            throw Failure(errorDescription: "Could not write \(to.lastPathComponent).")
        }
        let input = try FileHandle(forReadingFrom: from), output = try FileHandle(forWritingTo: to)
        defer { try? input.close(); try? output.close() }
        while true {
            let chunk = try autoreleasepool { try input.read(upToCount: 8 << 20) } ?? Data()
            if chunk.isEmpty { break }
            try output.write(contentsOf: chunk)
            copied(Int64(chunk.count))
        }
        try output.synchronize()
    }

    nonisolated private static func copyVerifyDelete(_ items: [(from: URL, to: URL)], progress: @escaping (Double) -> Void) throws {
        let fm = FileManager.default
        func files(_ url: URL) -> [(URL, Int64)] {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
            if !isDir.boolValue { return [(url, Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))] }
            // Any folder that cannot be read fails the move: a skipped folder
            // would be missing from the copy and then deleted with the original.
            var out: [(URL, Int64)] = [], unreadable: URL?
            let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]) { failed, _ in
                unreadable = failed; return false
            }
            while let item = walker?.nextObject() as? URL {
                let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey])
                if values?.isRegularFile == true { out.append((item, Int64(values?.fileSize ?? 0))) }
                else if values?.isDirectory != true { unreadable = item; break }
            }
            if let unreadable { failure = "Could not read \(unreadable.lastPathComponent)." }
            return out
        }
        var failure: String?
        let sources = items.map { files($0.from) }
        if let failure { throw Failure(errorDescription: failure) }
        let total = sources.flatMap { $0 }.reduce(Int64(0)) { $0 + $1.1 }
        guard !sources.isEmpty, !(sources.first?.isEmpty ?? true) else { throw Failure(errorDescription: "The game's files were not found.") }
        for item in items where fm.fileExists(atPath: item.to.path) {
            throw Failure(errorDescription: "\(item.to.lastPathComponent) already exists there.")
        }
        if let parent = items.first?.to.deletingLastPathComponent() {
            try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
            // FAT32 holds no file of 4 GB or more.
            let largest = sources.flatMap { $0 }.map(\.1).max() ?? 0
            if let type = parent.fileSystemType?.lowercased(), ["msdos", "fat", "fat32", "vfat"].contains(type), largest >= 1 << 32 {
                throw Failure(errorDescription: "This drive is formatted FAT32, which cannot hold this game's files over 4 GB. Use an exFAT or APFS drive.")
            }
            if let free = parent.freeSpace, free < total + 256 << 20 {
                throw Failure(errorDescription: "Not enough free space: \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)) needed.")
            }
        }
        var done: Int64 = 0, lastReport = Date.distantPast
        do {
            for (index, item) in items.enumerated() {
                let base = item.from.path
                for (file, size) in sources[index] {
                    let relative = file.path == base ? "" : String(file.path.dropFirst(base.count + 1))
                    let dest = relative.isEmpty ? item.to : item.to.appendingPathComponent(relative)
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try copyFile(file, to: dest) { bytes in
                        done += bytes
                        if Date().timeIntervalSince(lastReport) > 0.2 { lastReport = Date(); progress(total > 0 ? Double(done) / Double(total) : 1) }
                    }
                    let copied = Int64((try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1)
                    guard copied == size else { throw Failure(errorDescription: "The copy of \(file.lastPathComponent) does not match.") }
                }
            }
            // Check the whole copy before anything is deleted. Both sides are listed by
            // path relative to their own folder (no shared path prefix to mismatch, such
            // as /private/var vs /var through the drive's link) and by Unicode-normalized
            // name, so a drive that stores names in another form is not a false mismatch.
            for (index, item) in items.enumerated() {
                func tree(_ root: URL) -> [String: Int64] {
                    var out: [String: Int64] = [:], isDir: ObjCBool = false
                    guard fm.fileExists(atPath: root.path, isDirectory: &isDir) else { return out }
                    func size(_ path: String) -> Int64 { ((try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? -1 }
                    if !isDir.boolValue { out[""] = size(root.path); return out }
                    guard let walker = fm.enumerator(atPath: root.path) else { return out }
                    while let relative = walker.nextObject() as? String {
                        let full = root.appendingPathComponent(relative).path
                        guard (try? fm.attributesOfItem(atPath: full))?[.type] as? FileAttributeType == .typeRegular else { continue }
                        out[relative.precomposedStringWithCanonicalMapping] = size(full)
                    }
                    return out
                }
                let copied = tree(item.to)
                // The original is listed again, in case it changed or was only partly read.
                let original = tree(item.from)
                guard copied == original, original.count == sources[index].count else {
                    let missing = original.keys.filter { copied[$0] == nil }.sorted()
                    let extra = copied.keys.filter { original[$0] == nil }.sorted()
                    let sizes = original.keys.filter { copied[$0] != nil && copied[$0] != original[$0] }.sorted()
                    LogStore.shared.log("[move] check failed for \(item.from.lastPathComponent): copy \(copied.count) files, original \(original.count), first listing \(sources[index].count); missing \(missing.count) extra \(extra.count) size-differs \(sizes.count)")
                    for name in missing.prefix(5) { LogStore.shared.log("[move] check: missing from the copy: \(name) (\(original[name] ?? -1) bytes)") }
                    for name in extra.prefix(5) { LogStore.shared.log("[move] check: only in the copy: \(name) (\(copied[name] ?? -1) bytes)") }
                    for name in sizes.prefix(5) { LogStore.shared.log("[move] check: size differs: \(name) copy \(copied[name] ?? -1) original \(original[name] ?? -1)") }
                    throw Failure(errorDescription: "The copy is incomplete (\(copied.count) of \(original.count) files).")
                }
            }
        } catch {
            for item in items { try? fm.removeItem(at: item.to) }
            throw error
        }
        progress(1)
        LogStore.shared.log("[move] copied and checked files=\(sources.reduce(0) { $0 + $1.count }) bytes=\(total)")
        // The copy is already checked, so the move stands; a source that cannot be
        // removed (read-only or busy files) is logged rather than left unexplained,
        // because it keeps using the old drive's space.
        for item in items {
            do { try fm.removeItem(at: item.from) }
            catch { LogStore.shared.log("[move] copied, but the original \(item.from.lastPathComponent) could not be removed: \(error.localizedDescription)") }
        }
    }
}

/// Game details › Location: where the game is and Move to.
struct GameMoveSection: View {
    @Binding var entry: LibraryEntry
    @ObservedObject private var mover = GameMover.shared
    @ObservedObject private var drives = ExternalDrives.shared
    @State private var error: String?
    /// "120 GB free of 500 GB" for each place, by its library or root.
    @State private var sizes: [String: String] = [:]

    var body: some View {
        let here = GameMover.place(entry.relativePath)
        let steam = entry.steamAppID != nil
        let targets: [(name: String, value: String)] = steam ? drives.steamTargets.map { ($0.name, $0.library) } : drives.gameTargets.map { ($0.name, $0.root) }
        Section {
            LabeledContent("Installed on", value: here)
            if mover.moving == entry.id {
                ProgressView(value: mover.progress) { Text("Moving") } currentValueLabel: { Text("\(Int(mover.progress * 100))%") }
            } else if targets.count > 1 {
                Menu("Move to") {
                    ForEach(targets.filter { $0.name != here }, id: \.value) { target in
                        Button { start(target.value, steam: steam) } label: {
                            Text(target.name)
                            if let size = sizes[target.value] { Text(size) }
                        }
                    }
                }
                .disabled(mover.moving != nil)
            }
            if let error { Text(error).foregroundStyle(.red) }
        } header: { Text("Install Location") } footer: {
            Text("Moving copies the game, checks the copy, then deletes the original. Keep the drive connected until it finishes.")
        }
        .task(id: targets.map(\.value).joined()) {
            let drive = LibraryModel.drive
            var next: [String: String] = [:]
            for target in targets {
                let url = drive.appendingPathComponent(target.value)
                let free = url.freeSpace
                let total = url.volumeTotal
                let f = ByteCountFormatter.string(fromByteCount: free ?? 0, countStyle: .file)
                next[target.value] = switch (free, total) {
                case let (_?, total?): "\(f) free of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))"
                case (_?, nil): "\(f) free"
                default: nil
                }
            }
            sizes = next
        }
    }

    private func start(_ value: String, steam: Bool) {
        error = nil
        Task {
            do { entry = try await GameMover.shared.move(entry, toSteamLibrary: steam ? value : nil, toRoot: steam ? nil : value) }
            catch { self.error = error.localizedDescription }
        }
    }
}

extension URL {
    /// The volume's file system ("exfat", "msdos", "apfs", ...), or nil.
    var fileSystemType: String? {
        var url = resolvingSymlinksInPath()
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 { url.deleteLastPathComponent() }
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return nil }
        return withUnsafeBytes(of: info.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }
    /// Total bytes of the volume holding this path (statfs), or nil.
    var volumeTotal: Int64? {
        var url = resolvingSymlinksInPath()
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 { url.deleteLastPathComponent() }
        if let total = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity, total > 0 { return Int64(total) }
        var info = statfs()
        if statfs(url.path, &info) == 0, info.f_blocks > 0 { return Int64(info.f_blocks) * Int64(info.f_bsize) }
        return nil
    }
}

/// A move shown by iOS like a Steam download (SteamDownloadBackground.swift):
/// on iOS 26 and later a continued-processing task with the move's progress,
/// which also keeps Madeira running if it leaves the foreground. Its
/// identifier "<bundle id>.download.move" is covered by Info.plist's
/// `.download.*` entry.
@MainActor final class MoveBackground {
    static let shared = MoveBackground(suffix: "move")
    /// The batch uninstall's task ("<bundle id>.download.uninstall"); the batch
    /// move uses `shared` too, held across its games with batchStarted.
    static let uninstall = MoveBackground(suffix: "uninstall")
    private let suffix: String
    private init(suffix: String) { self.suffix = suffix }
    private var task: AnyObject?
    private var registered = false
    private var title = ""
    private var fraction = 0.0
    /// A batch holds the task from its first game to its last: one game ending
    /// does not end it, so it is not lost when Madeira is in the background.
    private var batch = false
    private var batchDone = 0
    private var batchTotal = 1
    private var onExpire: (@MainActor () -> Void)?
    private var tag: String { suffix == "move" ? "move" : "batch-" + suffix }

    private var identifier: String? {
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        return permitted.first { $0.hasSuffix(".download.*") }.map { String($0.dropLast()) + suffix }
    }

    func started(_ name: String) {
        guard !batch else { return }
        begin("Moving \(name)")
    }

    /// `onExpire` runs if iOS ends the task (or the user stops it from the system UI): the batch stops after its current game.
    func batchStarted(_ name: String, total: Int, onExpire: (@MainActor () -> Void)? = nil) {
        batch = true; batchDone = 0; batchTotal = max(1, total); self.onExpire = onExpire
        begin(name)
    }

    /// The batch moved on: `done` games are finished; `title` names the next.
    func batchStep(done: Int, title: String) {
        batchDone = done; self.title = title
        fraction = Double(done) / Double(batchTotal)
        if #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = Int64(min(1, fraction) * 1000)
            task.updateTitle(title, subtitle: "Madeira")
        }
    }

    func batchEnded() {
        batch = false
        onExpire = nil
        finish()
    }

    private func begin(_ newTitle: String) {
        title = newTitle; fraction = 0
        guard #available(iOS 26.0, *), let identifier else { return }
        if !registered {
            registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
                guard let task = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
                MainActor.assumeIsolated { self?.attach(task) }
            }
            guard registered else { LogStore.shared.log("[\(tag)] background task refused"); return }
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: "Madeira")
        request.strategy = .fail
        do { try BGTaskScheduler.shared.submit(request) } catch { LogStore.shared.log("[\(tag)] background task not submitted") }
    }

    @available(iOS 26.0, *)
    private func attach(_ task: BGContinuedProcessingTask) {
        guard batch || GameMover.shared.moving != nil else { task.setTaskCompleted(success: true); return }
        self.task = task
        task.progress.totalUnitCount = 1000
        task.progress.completedUnitCount = Int64(fraction * 1000)
        task.updateTitle(title, subtitle: "Madeira")
        let tag = self.tag, expire = onExpire
        task.expirationHandler = {
            LogStore.shared.log("[\(tag)] background time ended")
            Task { @MainActor in expire?() }
        }
    }

    func progress(_ value: Double) {
        fraction = batch ? (Double(batchDone) + min(1, value)) / Double(batchTotal) : value
        if #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = Int64(min(1, fraction) * 1000)
            task.updateTitle(title, subtitle: "\(Int(min(1, fraction) * 100))% · Madeira")
        }
    }

    func ended() {
        guard !batch else { return }
        finish()
    }

    private func finish() {
        if #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask { task.setTaskCompleted(success: true) }
        task = nil
    }
}
