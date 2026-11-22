//
//  GameRecommendationsApply.swift
//  Madeira
//
//  madeira-bcd: writes GameRecommendations.swift's lists into a game's
//  settings (owner's decision, 2026-10-09).
//
//  The first time Madeira sees a game it has a recommendation for (a Steam
//  download finishing, the library opening or saving the game, Game details
//  opening, a start):
//    - with nothing of its own yet (no config file, no lines in upstream's
//      `config` field), a game new to the library gets its whole
//      recommendation, and one already in the library the config file only:
//      its fields and switches (resolution, FPS limit, AVX ...) stay the
//      player's until Reset to Recommended;
//    - with a config of its own, it keeps it, and only Reset to Recommended
//      replaces it.
//  A config Madeira wrote that nobody has changed since follows a newer
//  version of its list (the config file only); one the player changed, or
//  emptied, is never written again by itself. "Reset to Recommended" at the
//  bottom of the game's settings writes the whole recommendation again,
//  whatever the game holds; for a game without one it empties the game's
//  config. A game without a list of its own, and the Desktop, gets the
//  standard list (owner's decisions, 2026-10-12), which a list for the game
//  replaces later as on first sight while nobody has changed the file.
//
//  The config file and the switches LibraryPrefs keeps belong to the game's
//  Windows path. A library entry's own fields (fastsync, FPS limit,
//  resolution, scaling) are written with them, or later for an entry new to
//  the library.
//

import Foundation

extension GameRecommendations {
    /// What Madeira did for which game: [lowercased Windows path: "<id>#<version>#<file hash>"
    /// for a recommendation it wrote, "" for a game that kept its own config].
    private static let appliedKey = "madeira.recommended.applied"

    private enum Write: String { case firstSight = "first sight", updated, reset }

    /// The recommendation for a game in drive_c: a program, or a Steam game's install folder.
    /// A game Madeira has no list for gets the standard one; a path that names nothing, none.
    static func recommendation(windowsPath: String, steamAppID: Int?) -> GameRecommendation? {
        var base = match(windowsPath: windowsPath, steamAppID: steamAppID, fileExists: driveFileExists)
        if base == nil {
            let parts = windowsPath.replacingOccurrences(of: "/", with: "\\").split(separator: "\\")
            // [engine-presets] a game with no list of its own gets its engine's preset when its folder shows one, else the standard list.
            if parts.count > 1 { base = enginePreset(windowsPath: windowsPath, fileExists: driveFileExists) ?? standard }
        }
        // (remote-recs) A newer list for the game from the signed file the Get Help server serves (RemoteRecs.swift).
        return RemoteRecs.replacement(base: base, steamAppID: steamAppID) ?? base
    }

    /// [engine-presets] The preset of the engine a game's folder shows, for a game with no list of its own that
    /// Madeira has not written anything for yet (no mark) or wrote an engine preset for before. A game that has a
    /// mark of its own (the standard list, a game's list, "" for a config of its own) never gets one, so a game
    /// already in the library keeps what it runs with. Off switches (madeira.cfg): env.MADEIRA_ENGINE_PRESETS = 0
    /// for all, env.MADEIRA_ENGINE_PRESET_<UNITY|MONO|DOTNET|JVM> = 0 for one; with a switch off the preset is not
    /// offered and a config still exactly as an engine preset wrote it goes back to the standard list.
    static func enginePreset(windowsPath: String, fileExists: (String) -> Bool) -> GameRecommendation? {
        let mark = marks[windowsPath.lowercased()]
        guard mark == nil || mark?.hasPrefix("engine-") == true else { return nil }
        guard MadeiraConfig.flag("MADEIRA_ENGINE_PRESETS") else { return nil }
        // Written before: the same engine, without looking at the folder again.
        let written = mark.flatMap { m in Engine(rawValue: String(m.dropFirst("engine-".count).prefix { $0 != "#" })) }
        guard let engine = written ?? self.engine(windowsPath: windowsPath, fileExists: fileExists),
              MadeiraConfig.flag(engine.switchName) else { return nil }
        return enginePreset(engine)
    }

    /// A library entry's recommendation: the Desktop's is the standard list.
    static func recommendation(for entry: LibraryEntry) -> GameRecommendation? {
        if entry.desktop == true { return standard }
        let rec = recommendation(windowsPath: entry.windowsPath, steamAppID: entry.steamAppID)
        // (shared-configs) A game with only the standard list takes the settings other players
        // said work for it, once approved (SharedConfigs.swift). A list of its own always wins.
        if rec?.id == standard.id || rec?.id.hasPrefix("engine-") == true,
           let shared = SharedConfigs.recommendation(title: entry.title) { return shared }
        return rec
    }

    /// A library entry's recommendation, when one is due (see above). `new`: the entry
    /// is not in the library yet; it then also takes the fields of a list written for
    /// its game before (for an entry since removed). True when the entry's own fields
    /// changed, so the caller saves the entry.
    @discardableResult
    static func prepare(_ entry: inout LibraryEntry, new: Bool = false) -> Bool {
        if let found = due(entry.windowsPath, recommendation(for: entry), ownLines: entry.config, title: entry.title),
           put(found.rec, to: entry.windowsPath, found.kind, title: entry.title, switches: new), found.kind == .firstSight {
            // A game already in the library keeps its own fields and switches (resolution,
            // FPS limit, AVX ...): the player may have set them. It gets the config file only;
            // Reset to Recommended brings the rest.
            guard new else {
                LogStore.shared.log("[recommended] \(entry.title): \(found.rec.id) v\(found.rec.version) config only; "
                                    + "the entry keeps its own fields and switches")
                return false
            }
            takeEntryFields(found.rec, &entry)
            return true
        }
        // After an update too: a new entry takes the list now recorded for its path.
        guard new, let mark = marks[entry.windowsPath.lowercased()], !mark.isEmpty,
              let rec = recommendation(for: entry), mark.hasPrefix(rec.id + "#") else { return false }
        takeEntryFields(rec, &entry)
        LogStore.shared.log("[recommended] \(entry.title): \(rec.id) v\(rec.version) fields for a new library entry")
        return true
    }

    /// Game details › Reset to Recommended. Returns what was written; nil when the
    /// game has no recommendation and its config was emptied.
    @discardableResult
    static func reset(_ entry: inout LibraryEntry) -> GameRecommendation? {
        entry.config = nil
        guard let rec = recommendation(for: entry) else { clear(entry.windowsPath, title: entry.title); return nil }
        put(rec, to: entry.windowsPath, .reset, title: entry.title)
        takeEntryFields(rec, &entry)
        return rec
    }

    /// (shared-configs) Undo on "Madeira used shared settings": the standard list goes back, and
    /// the game keeps it as its own, so the shared list is never written again by itself
    /// (Reset to Recommended still brings it back).
    static func undoShared(windowsPath: String, title: String) {
        GameProfile(windowsPath: windowsPath).text = standard.fileText
        setMark("", windowsPath)
        LogStore.shared.log("[shared-configs] \(title): undo, standard list back; the shared list is one Reset to Recommended away")
    }

    /// The line under Reset to Recommended. `desktop`: the Desktop entry's page.
    static func note(_ rec: GameRecommendation?, desktop: Bool = false) -> String {
        guard let rec else { return "Madeira has no recommended settings for this game yet; resetting empties this game's config." }
        let lines = GameProfile.parse(rec.fileText).count
        if rec.id == standard.id {
            return (desktop ? "Madeira recommends its standard settings for the Desktop: "
                            : "Madeira has no list for this game yet, so it recommends its standard settings: ")
                + "\(lines) config line\(lines == 1 ? "" : "s") (the emulator's code-patch report off, without which many games "
                + "close at start). Resetting replaces "
                + (desktop ? "the Desktop's" : "this game's") + " config with them."
        }
        if SharedConfigs.isShared(rec) {
            return "Settings other players said work for \(rec.title), approved by Madeira: \(lines) config lines. "
                + "Resetting replaces this game's config with them."
        }
        let summary = rec.switchSummary
        let switches = summary.isEmpty ? "" : "; " + summary
        return "Madeira's recommended settings for \(rec.title): \(lines) config lines\(switches). Resetting replaces this game's config and these switches with them."
    }

    /// The question before a reset.
    static func question(_ rec: GameRecommendation?, desktop: Bool = false) -> String {
        guard let rec else { return "Madeira has no recommended settings for this game yet. Empty this game's config?" }
        if rec.id == standard.id {
            return "Replace \(desktop ? "the Desktop's" : "this game's") config with Madeira's standard settings? Changes you made to it are lost."
        }
        return "Replace this game's config and switches with Madeira's recommended settings for \(rec.title)? Changes you made to them are lost."
    }

    // MARK: -

    /// (recommended-after-get-help) What Madeira or Get Help added to the end of a config: from the first
    /// "# Get Help added these" or "# Added by Madeira:" comment to the end, kept exactly as it is (a line the
    /// player typed below that comment included). `base` is what stands above it, trailing blank lines dropped.
    /// A config with no such comment is all `base`, unchanged.
    static func splitAdded(_ text: String) -> (base: String, tail: String) {
        var rows = text.components(separatedBy: "\n")
        if rows.last == "" { rows.removeLast() }
        guard let i = rows.firstIndex(where: { isAddedHeader($0) }) else { return (text, "") }
        var head = Array(rows[..<i])
        while let last = head.last, last.trimmingCharacters(in: .whitespaces).isEmpty { head.removeLast() }
        return (head.isEmpty ? "" : head.joined(separator: "\n") + "\n", rows[i...].joined(separator: "\n") + "\n")
    }

    private static func isAddedHeader(_ row: String) -> Bool {
        let r = row.trimmingCharacters(in: .whitespaces)
        return r.hasPrefix("# Get Help added these") || r.hasPrefix("# Added by Madeira:")
    }

    private static func due(_ windowsPath: String, _ found: GameRecommendation?, ownLines: String?,
                            title: String) -> (rec: GameRecommendation, kind: Write)? {
        let mark = marks[windowsPath.lowercased()]
        guard let rec = found else { return nil }
        let text = GameProfile(windowsPath: windowsPath).text
        // (recommended-after-get-help) Get Help's and Madeira's own additions at the end do not count as the
        // player's config: the list is compared and written without them, and they are put back after it.
        let (base, tail) = splitAdded(text)
        if mark == "" {
            // Kept its own config at first sight. When all that is in it is Madeira's or Get Help's additions,
            // nothing of the player's is there to protect: the list is written as on first sight. A config the
            // player emptied has no additions and stays empty.
            guard base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (ownLines ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            LogStore.shared.log("[recommended] \(title): only Get Help's or Madeira's own lines in the config; \(rec.id) v\(rec.version) goes in above them")
            return (rec: rec, kind: .firstSight)
        }
        if let mark {
            // Written before: a newer list replaces it while the file above the additions is exactly what was written.
            guard mark != stamp(rec), mark.hasSuffix("#" + fileHash(base)) else { return nil }
            // The standard list gives way to the game's own list as on first sight, switches too.
            let fromStandard = (mark.hasPrefix(standard.id + "#") || mark.hasPrefix("engine-"))
                && rec.id != standard.id && !rec.id.hasPrefix("engine-")
            return (rec: rec, kind: fromStandard ? Write.firstSight : Write.updated)
        }
        if !(base + (ownLines ?? "")).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // First seen with a config of its own: it stays, now and later.
            setMark("", windowsPath)
            LogStore.shared.log("[recommended] \(title): keeps its own config; \(rec.id) v\(rec.version) is one Reset to Recommended away")
            return nil
        }
        return (rec: rec, kind: .firstSight)
    }

    /// The config file, and on first sight or a reset the switches LibraryPrefs keeps for
    /// the game's path: AVX, NVIDIA, the older NVIDIA card and Wine's C++ runtime.
    @discardableResult
    private static func put(_ rec: GameRecommendation, to windowsPath: String, _ kind: Write, title: String,
                            switches: Bool = true) -> Bool {
        let file = GameProfile(windowsPath: windowsPath)
        // (recommended-after-get-help) Madeira's and Get Help's additions stay, below the list. A reset writes the list alone.
        let tail = kind == .reset ? "" : splitAdded(file.text).tail
        let want = tail.isEmpty ? rec.fileText : rec.fileText + "\n" + tail
        file.text = want
        guard file.text == want else {
            LogStore.shared.log("[recommended] \(title): could not write \(rec.id)", level: .error)
            return false
        }
        if kind != .updated && switches {
            if let on = rec.avx { LibraryPrefs.setAVX(on, for: windowsPath) }
            if let on = rec.nvidia { LibraryPrefs.setNvidia(on, for: windowsPath) }
            if let on = rec.olderNvidia { LibraryPrefs.setOlderNvidia(on, for: windowsPath) }
            if let on = rec.wineVCRT { LibraryPrefs.setWineVCRT(on, for: windowsPath) }
        }
        setMark(stamp(rec), windowsPath)
        LogStore.shared.log("[recommended] \(title): \(rec.id) v\(rec.version) written (\(kind.rawValue))")
        // (shared-configs) Written by itself: ask Keep or Undo (SharedConfigsNotice).
        if kind != .reset, SharedConfigs.isShared(rec) { SharedConfigs.applied(title: title, windowsPath: windowsPath) }
        return true
    }

    private static func clear(_ windowsPath: String, title: String) {
        GameProfile(windowsPath: windowsPath).text = ""
        setMark(nil, windowsPath)
        LogStore.shared.log("[recommended] \(title): none for this game; its config was emptied (reset)")
    }

    /// The switches a library entry keeps itself.
    private static func takeEntryFields(_ rec: GameRecommendation, _ entry: inout LibraryEntry) {
        if let on = rec.fastSync { entry.fastSync = on }
        if let on = rec.semaphoreFastPath { entry.semaphoreFastPath = on }
        if let mode = rec.fpsMode { entry.fpsMode = mode }
        if let size = rec.resolution {
            // This screen's shape at 720 lines; a screen whose default has them keeps its own.
            if size != GameRecommendation.screen720 { entry.resolution = size }
            else if let lines720 = ResolutionChoices.screen720Value { entry.resolution = lines720 }
        }
        if let mode = rec.display { entry.display = mode == DisplayMode.fit.rawValue ? nil : mode }
        if let mode = rec.launchMode { entry.launchMode = mode == "desktop" ? mode : nil }
        if let on = rec.startServices { entry.startServices = on ? true : nil }
    }

    private static var marks: [String: String] {
        (UserDefaults.standard.dictionary(forKey: appliedKey) as? [String: String]) ?? [:]
    }

    private static func setMark(_ value: String?, _ windowsPath: String) {
        var all = marks
        all[windowsPath.lowercased()] = value
        UserDefaults.standard.set(all, forKey: appliedKey)
    }

    private static func stamp(_ rec: GameRecommendation) -> String { "\(rec.id)#\(rec.version)#\(fileHash(rec.fileText))" }

    private static func fileHash(_ text: String) -> String { String(LibraryPrefs.stableHash(text), radix: 16) }

    /// Whether a C:\ path exists in drive_c; the name's case does not matter, as on Windows.
    static func driveFileExists(_ windowsPath: String) -> Bool {
        let path = windowsPath.replacingOccurrences(of: "\\", with: "/")
        guard path.lowercased().hasPrefix("c:/") else { return false }
        let url = LibraryModel.drive.appendingPathComponent(String(path.dropFirst(3)))
        let name = url.lastPathComponent.lowercased()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []
        return names.contains { $0.lowercased() == name }
    }
}
