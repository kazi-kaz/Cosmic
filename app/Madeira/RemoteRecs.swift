// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
//  (remote-recs) A game's recommended settings as signed data from the Get Help server, so a fix to a
//  game's list reaches players without a new IPA (plan: plans/compare-similar-projects-2026-11-17.md item 1;
//  Cameron's go Nov 17 2026).
//
//  It reuses the shared-configs channel: the same Ed25519 key (SharedConfigs.publicKey / verify), the same
//  Get Help key header, the same "keep only a file whose signature checks, check it again when read".
//
//  What a file entry can do:
//    - `id` equal to a built-in list's id ("rdr2-steam"): replaces that list, but ONLY when its `version`
//      is higher than the built-in one. When a newer IPA ships a built-in list with an equal or higher
//      version, the built-in wins again by itself (the entry is then just ignored, and logged once).
//    - `id` starting "remote-" with `app_ids`: a list for a Steam game the app has no list of its own for
//      (it replaces the standard list for that game; a built-in list for the game wins over it).
//  The list then travels the same first-sight rules as a built-in one (GameRecommendationsApply.swift):
//  written into that game's own config only, never over a config the player wrote or changed, a newer
//  version replaces a config nobody changed, Reset to Recommended writes it. A line the player wrote still
//  wins (it is in the config Madeira will not overwrite). An entry the server drops goes back to the
//  built-in list in every config nobody changed.
//  Lines: same safety check as shared settings (SharedConfigs.safe). Switches: only on/off ones and the FPS
//  mode, from a fixed set. No code and no paths ever come down.
//  A file older than the kept one (`made`) is refused (no going back to an older list by replay).
//
//  A kept file older than 120 days is not used. A new file applies as soon as it is downloaded (to the next
//  recommendation lookup); a config nobody changed is rewritten then.
//
//  Off: env.MADEIRA_REMOTE_RECS = 0 (Settings › All settings › App & front end). No MadeiraSharedConfigsKey
//  in the build's Info.plist: off. Server: wrangler var RECS="off" sends an empty list.
//  Logs: [remote-recs] ...

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLRequest/URLSession on Linux (the host check); nothing on iOS
#endif

enum RemoteRecs {
    /// Game lists from the Get Help server. 0 turns it off (behaviour identical to the built-in lists only).
    static let enabled = MadeiraConfig.flag("MADEIRA_REMOTE_RECS")
    static let refreshEvery: TimeInterval = 3600
    static let maxEntries = 60
    static let staleAfterDays = 45
    /// A kept file older than this is not used (a device that never reached the server must not hold an old list for ever).
    static let expireAfterDays = 120

    struct Entry: Codable, Equatable {
        let id: String
        let title: String
        let version: Int
        let app_ids: [Int]?
        let lines: [SharedConfigs.Line]
        let small_ram_lines: [SharedConfigs.Line]?
        let avx: Bool?
        let nvidia: Bool?
        let older_nvidia: Bool?
        let wine_vcrt: Bool?
        let fast_sync: Bool?
        let semaphore_fast_path: Bool?
        let fps_mode: Int?
        let reason: String
    }
    struct File: Codable { let format: Int; let kind: String; let made: String; let recs: [Entry] }

    static func oneLine(_ text: String) -> Bool { text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }

    /// `made` as a date: ISO 8601 UTC like 2026-11-17T17:00:00.000Z (the server's toISOString), else nil.
    static func madeDate(_ text: String) -> Date? {
        guard text.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$"#, options: .regularExpression) != nil else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = text.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f.date(from: text)
    }

    static func goodID(_ id: String) -> Bool {
        id.count >= 2 && id.count <= 60 && id.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    static func safe(_ e: Entry) -> Bool {
        guard goodID(e.id), e.version >= 1, e.version <= 99999, !e.title.isEmpty, e.title.count <= 80, oneLine(e.title),
              !e.reason.isEmpty, e.reason.count <= 200, oneLine(e.reason),
              !e.lines.isEmpty, e.lines.count <= 80, e.lines.allSatisfy(SharedConfigs.safe),
              (e.small_ram_lines ?? []).count <= 40, (e.small_ram_lines ?? []).allSatisfy(SharedConfigs.safe),
              [nil, 0, 1, 2, 3, 4].contains(e.fps_mode) else { return false }
        if let ids = e.app_ids { guard !ids.isEmpty, ids.count <= 10, ids.allSatisfy({ $0 > 0 && $0 <= 99_999_999 }) else { return false } }
        // A list for a game the app has no list of its own for must say so with a remote- id and App IDs.
        if e.id.hasPrefix("remote-") { return e.app_ids != nil }
        return e.app_ids == nil
    }

    /// The entries of a file, by id, and its `made` date; nil when it is not a file Madeira knows.
    /// One unsafe entry refuses the whole file (a half-trusted list is not a list).
    static func parse(_ data: Data) -> (made: Date, recs: [Entry])? {
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.format == 1, file.kind == "recs",
              let made = madeDate(file.made), file.recs.count <= maxEntries, file.recs.allSatisfy(safe),
              Set(file.recs.map(\.id)).count == file.recs.count else { return nil }
        return (made, file.recs)
    }

    static func text(_ lines: [SharedConfigs.Line]) -> String {
        lines.map { "\($0.key) = \($0.value.trimmingCharacters(in: .whitespaces))" }.joined(separator: "\n")
    }

    /// `base`: the list it replaces (built-in or the standard list). Everything the entry does not say stays as in
    /// `base` (small-RAM lines, resolution, display, launch mode, services, switches); a `remote-` list on the
    /// standard list keeps the standard lines first, like shared settings.
    static func recommendation(_ e: Entry, base: GameRecommendation?, standardID: String) -> GameRecommendation {
        let onStandard = base == nil || base?.id == standardID
        var r = GameRecommendation(id: e.id, title: e.title, version: e.version,
                                   config: onStandard && base != nil ? base!.config + "\n" + text(e.lines) : text(e.lines))
        if let base, !onStandard {
            r.avx = base.avx; r.nvidia = base.nvidia; r.olderNvidia = base.olderNvidia; r.wineVCRT = base.wineVCRT
            r.fastSync = base.fastSync; r.semaphoreFastPath = base.semaphoreFastPath; r.fpsMode = base.fpsMode
            r.resolution = base.resolution; r.display = base.display; r.launchMode = base.launchMode
            r.startServices = base.startServices; r.smallRAMConfig = base.smallRAMConfig
        }
        if let v = e.avx { r.avx = v }
        if let v = e.nvidia { r.nvidia = v }
        if let v = e.older_nvidia { r.olderNvidia = v }
        if let v = e.wine_vcrt { r.wineVCRT = v }
        if let v = e.fast_sync { r.fastSync = v }
        if let v = e.semaphore_fast_path { r.semaphoreFastPath = v }
        if let v = e.fps_mode { r.fpsMode = v }
        if let extra = e.small_ram_lines, !extra.isEmpty { r.smallRAMConfig = text(extra) }
        return r
    }

    /// The list to use instead of `base` (what the built-in rules found: a built-in list, the standard
    /// list, or nil), or nil to keep `base`. `standardID`: GameRecommendations.standard.id.
    static func replacement(base: GameRecommendation?, steamAppID: Int?, in recs: [Entry]?, standardID: String) -> GameRecommendation? {
        guard let recs else { return nil }
        if let base, base.id != standardID {
            guard let e = recs.first(where: { $0.id == base.id }) else { return nil }
            if e.version > base.version {
                note("\(e.id) v\(e.version) is in force instead of the built-in v\(base.version)")
                return recommendation(e, base: base, standardID: standardID)
            }
            note("\(e.id) v\(e.version) is not newer than the built-in v\(base.version); built-in kept")
            return nil
        }
        guard let app = steamAppID, let e = recs.first(where: { $0.app_ids?.contains(app) == true }) else { return nil }
        note("\(e.id) v\(e.version) is in force for Steam app \(app)")
        return recommendation(e, base: base, standardID: standardID)
    }

    /// For GameRecommendations.recommendation(windowsPath:steamAppID:).
    static func replacement(base: GameRecommendation?, steamAppID: Int?) -> GameRecommendation? {
        guard let recs = entries() else { return nil }
        return replacement(base: base, steamAppID: steamAppID, in: recs, standardID: GameRecommendations.standard.id)
    }

    // MARK: - Log lines (each only once per start)
    private static let logLock = NSLock()
    nonisolated(unsafe) private static var said = Set<String>()
    private static func note(_ line: String) {
        logLock.lock(); let fresh = said.insert(line).inserted; logLock.unlock()
        if fresh { LogStore.shared.log("[remote-recs] " + line) }
    }

    // MARK: - On the device

    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded: [Entry]?? = nil

    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RemoteRecs", isDirectory: true)
    }
    /// One file, written in one atomic step: the signature on the first line, then the signed body exactly as received.
    private static var signedURL: URL { folder.appendingPathComponent("remote-recs.signed") }

    private static func keptParts() -> (String, Data)? {
        guard let all = try? Data(contentsOf: signedURL), let nl = all.firstIndex(of: 0x0A),
              let sig = String(data: all[..<nl], encoding: .utf8) else { return nil }
        return (sig, all[all.index(after: nl)...])
    }
    private static func keptFile() -> (made: Date, recs: [Entry])? {
        guard let (sig, data) = keptParts() else { return nil }
        guard SharedConfigs.verify(data, signature: sig) else {
            note("kept file failed its signature check; not used")
            return nil
        }
        return parse(data)
    }

    /// The kept file's entries, checked once per start (and again after a download); nil when off or none.
    static func entries() -> [Entry]? {
        guard enabled, !SharedConfigs.publicKey.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let loaded { return loaded }
        var found: [Entry]? = nil
        if let kept = keptFile() {
            let age = Int(Date().timeIntervalSince(kept.made) / 86400)
            found = age > expireAfterDays ? nil : kept.recs
            note("kept file: \(kept.recs.count) list\(kept.recs.count == 1 ? "" : "s"), made \(age) day\(age == 1 ? "" : "s") ago"
                 + (age > expireAfterDays ? " (too old: not used, built-in lists only)" : age > staleAfterDays ? " (old: the server has not been reachable, or has had nothing newer)" : ""))
        }
        loaded = .some(found)
        return found
    }

    /// Asks the Get Help server for the newest file, at most every `refreshEvery`. Does not wait.
    static func refresh() {
        guard enabled, !SharedConfigs.publicKey.isEmpty, GetHelp.enabled, let key = GetHelp.key else { return }
        let last = UserDefaults.standard.double(forKey: "remote-recs-checked")
        let now = Date().timeIntervalSince1970
        guard now - last >= refreshEvery else { return }
        UserDefaults.standard.set(now, forKey: "remote-recs-checked")
        var request = URLRequest(url: GetHelpCore.server.appendingPathComponent("shared/recs"), timeoutInterval: 20)
        request.setValue(key, forHTTPHeaderField: "x-madeira-key")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let http = response as? HTTPURLResponse
            guard http?.statusCode == 200, let data, let sig = http?.value(forHTTPHeaderField: "x-madeira-signature"),
                  SharedConfigs.verify(data, signature: sig), let new = parse(data) else {
                LogStore.shared.log("[remote-recs] newest file: not used (status \(http?.statusCode ?? 0))")
                return
            }
            if let kept = keptFile(), new.made < kept.made {
                LogStore.shared.log("[remote-recs] newest file is older than the kept one; refused")
                return
            }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try (Data(sig.utf8) + Data([0x0A]) + data).write(to: signedURL, options: .atomic)
                lock.lock(); loaded = .some(new.recs); lock.unlock()
                LogStore.shared.log("[remote-recs] newest file kept: \(new.recs.count) list\(new.recs.count == 1 ? "" : "s")")
            } catch {
                LogStore.shared.log("[remote-recs] could not keep the file: \(error.localizedDescription)", level: .error)
            }
        }.resume()
    }
}
