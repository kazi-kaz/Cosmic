// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
//  (kill-list) A signed list of Madeira switches the team wants OFF for a build, so a fix that
//  breaks games can be turned off for everyone without a new IPA (plan: plans/stop-regressions-2026-11-17.md,
//  item D; Cameron's go Nov 17 2026).
//
//  It reuses the shared-configs channel: the Get Help server signs the file with the same Ed25519 key
//  (SharedConfigs.publicKey, SharedConfigs.verify), the app keeps the last good signed copy, and a
//  file that fails its signature is ignored. No code ever comes down: only switch NAMES.
//
//  What an entry can do: set `NAME` to "0" in the process environment (setenv, overwrite = 0) BEFORE any
//  switch is read. That is the same as a line `env.NAME = 0` at the lowest priority:
//    - a line in madeira.cfg or in a game's own config for that NAME still wins (the player's choice, and
//      how we turn a fix back ON for one game while the list has it off);
//    - an entry can only turn a switch off, never on and never set another value;
//    - only names that exist in the settings catalog as on/off switches (`env.NAME`, kind bool) count, and
//      never the ones in `neverKill`.
//  An entry may list `builds`: it applies when the build label (BuildStamp.text) contains any of them.
//  No `builds` = every build. A new file applies from the NEXT start of Madeira.
//
//  Off: env.MADEIRA_KILLLIST = 0 (madeira.cfg or the environment). Needs MadeiraSharedConfigsKey in the
//  build's Info.plist, like shared configs; without it nothing happens.
//  Logs: [killlist] ...

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLRequest/URLSession on Linux (the host check); nothing on iOS
#endif

enum KillList {
    /// The team's list of switches to keep off. 0 turns the whole thing off.
    static let enabled = MadeiraConfig.flag("MADEIRA_KILLLIST")
    static let refreshEvery: TimeInterval = 3600
    static let maxEntries = 30

    /// Names no list may touch: the kill list itself, the config plumbing, the Get Help channel.
    static let neverKill: Set<String> = ["MADEIRA_KILLLIST", "MADEIRA_ENV_LOCKED", "MADEIRA_CFG_GAME", "MADEIRA_SHARED_CONFIGS",
                                          "MADEIRA_RESPAWN_GUARD", "MADEIRA_JIT_SIGNING_CHECK", "MADEIRA_JIT_SHORTCUT", "MADEIRA_JITLESS", "MADEIRA_JIT_ENV_INHERIT"]
    /// ...and every name starting with one of these: the front end (controller and keyboard navigation), the
    /// signing refresh, Get Help and its offer, the new look's pad. Turning these off can lock a player out of
    /// the app, so a list can never touch them (review finding: neverKill was too thin).
    static let neverKillPrefixes = ["MADEIRA_FRONTEND", "MADEIRA_SIGNING", "MADEIRA_GET_HELP", "MADEIRA_NEW_LOOK"]
    struct Entry: Codable, Equatable { let name: String; let builds: [String]?; let reason: String }
    struct File: Codable { let format: Int; let kind: String; let made: String; let entries: [Entry] }

    /// A switch name Madeira will set: MADEIRA_ then capitals, digits and underscores.
    static func safeName(_ name: String) -> Bool {
        guard name.hasPrefix("MADEIRA_"), name.count <= 70, !neverKill.contains(name),
              !neverKillPrefixes.contains(where: { name.hasPrefix($0) }) else { return false }
        return name.unicodeScalars.allSatisfy { ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    /// The entries of a file, or nil when it is not a file Madeira knows. A file with one unsafe entry is refused whole.
    static func parse(_ data: Data) -> [Entry]? {
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.format == 1, file.kind == "killlist",
              madeDate(file.made) != nil, file.entries.count <= maxEntries,
              file.entries.allSatisfy({ safeName($0.name) && !$0.reason.isEmpty && $0.reason.count <= 200 && oneLine($0.reason)
                                        && ($0.builds.map { !$0.isEmpty && $0.allSatisfy(goodBuildToken) } ?? true) })
        else { return nil }
        return file.entries
    }

    /// One line of plain text: no newline, no control character.
    static func oneLine(_ text: String) -> Bool { text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }

    /// A build token names a version: 4 to 80 characters with at least one digit (so "0.2.29", not "0" or "Madeira").
    static func goodBuildToken(_ t: String) -> Bool { t.count >= 4 && t.count <= 80 && t.contains(where: \.isNumber) && oneLine(t) }

    /// `made` as a date: ISO 8601 UTC like 2026-11-17T17:00:00.000Z (the server's toISOString), else nil.
    static func madeDate(_ text: String) -> Date? {
        guard text.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,3})?Z$"#, options: .regularExpression) != nil else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = text.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f.date(from: text)
    }

    /// The entries that apply to `build` (its label), in file order.
    static func applying(_ entries: [Entry], build: String) -> [Entry] {
        entries.filter { e in
            guard let builds = e.builds, !builds.isEmpty else { return true }
            return builds.contains { matches(build, $0) }
        }
    }

    /// `token` is in `build` as a whole version: not inside a longer number ("0.2.2" is not in "0.2.29",
    /// "0.2.29" is not in "0.2.290").
    static func matches(_ build: String, _ token: String) -> Bool {
        var from = build.startIndex
        while let r = build.range(of: token, range: from..<build.endIndex) {
            let before = r.lowerBound == build.startIndex ? nil : build[build.index(before: r.lowerBound)]
            let after = r.upperBound == build.endIndex ? nil : build[r.upperBound]
            let rest = r.upperBound == build.endIndex ? "" : String(build[build.index(after: r.upperBound)...].prefix(1))
            let afterDigit = after?.isNumber == true || (after == "." && rest.first?.isNumber == true)
            let beforeDigit = before?.isNumber == true || (before == "." && token.first?.isNumber == true)
            if !afterDigit && !beforeDigit { return true }
            from = r.upperBound
        }
        return false
    }

    /// Whether the settings catalog lists `NAME` as an on/off switch.
    static func isCatalogSwitch(_ name: String) -> Bool {
        ConfigCatalog.generated.contains { $0.key == "env." + name && $0.kind == .bool }
    }

    // MARK: - Log lines
    // apply() runs before LogStore exists and stderr only reaches madeira-log.txt once Wine starts, so the
    // lines wait here and refresh() (called when the library appears) writes them with LogStore.
    private static let logLock = NSLock()
    nonisolated(unsafe) private static var waiting: [String] = []
    private static func say(_ line: String) { logLock.lock(); waiting.append(line); logLock.unlock() }
    static func flushLog() {
        logLock.lock(); let lines = waiting; waiting = []; logLock.unlock()
        for l in lines { LogStore.shared.log(l) }
    }

    // MARK: - On the device

    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KillList", isDirectory: true)
    }
    /// One file, written in one atomic step: the signature on the first line, then the signed body exactly as received.
    private static var signedURL: URL { folder.appendingPathComponent("kill-list.signed") }

    /// (signature, body) of the kept file, or nil.
    private static func keptParts() -> (String, Data)? {
        guard let all = try? Data(contentsOf: signedURL), let nl = all.firstIndex(of: 0x0A),
              let sig = String(data: all[..<nl], encoding: .utf8) else { return nil }
        return (sig, all[all.index(after: nl)...])
    }
    /// The kept list's entries, checked against the signature; nil when there is none or it fails.
    static func keptEntries() -> [Entry]? {
        guard let (sig, data) = keptParts() else { return nil }
        guard SharedConfigs.verify(data, signature: sig) else {
            fputs("[killlist] kept file failed its signature check; not used\n", stderr)
            return nil
        }
        return parse(data)
    }

    /// Start of the app, before any switch is read: turns the listed switches off in the environment.
    /// Writes to stderr because LogStore is not up yet; the lines reach the log with the rest of stderr.
    static func apply(entries: [Entry]? = nil, build: String = BuildStamp.text,
                      known: (String) -> Bool = isCatalogSwitch, cfgLine: (String) -> String? = { MadeiraConfig.get($0) }, set: (String) -> Void = { setenv($0, "0", 0) }) {
        guard enabled, !SharedConfigs.publicKey.isEmpty, let list = entries ?? keptEntries() else { return }
        var turnedOff: [String] = []
        for e in applying(list, build: build) {
            guard known(e.name) else { say("[killlist] \(e.name): not a catalog switch; ignored"); continue }
            // A line in madeira.cfg is the player's choice and wins: leave the environment alone for that name
            // (native code that reads the environment directly would otherwise see the "0" first).
            guard cfgLine("env." + e.name) == nil else { say("[killlist] \(e.name): madeira.cfg has its own line; the list does not touch it"); continue }
            set(e.name)
            turnedOff.append(e.name)
            say("[killlist] \(e.name) kept OFF for \(build): \(e.reason)")
        }
        say("[killlist] \(turnedOff.count) switch\(turnedOff.count == 1 ? "" : "es") off by the team's list (a game's own config line still wins)")
    }

    /// The file's `made` time, or nil.
    static func madeStamp(_ data: Data) -> Date? { (try? JSONDecoder().decode(File.self, from: data)).flatMap { madeDate($0.made) } }

    /// Asks the Get Help server for the newest list, at most every `refreshEvery`. Does not wait.
    static func refresh() {
        flushLog()
        guard enabled, !SharedConfigs.publicKey.isEmpty, GetHelp.enabled, let key = GetHelp.key else { return }
        let last = UserDefaults.standard.double(forKey: "kill-list-checked")
        let now = Date().timeIntervalSince1970
        guard now - last >= refreshEvery else { return }
        UserDefaults.standard.set(now, forKey: "kill-list-checked")
        var request = URLRequest(url: GetHelpCore.server.appendingPathComponent("shared/killlist"), timeoutInterval: 20)
        request.setValue(key, forHTTPHeaderField: "x-madeira-key")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let http = response as? HTTPURLResponse
            // A redirect to another host is not our server: ignore.
            guard http?.url?.host == GetHelpCore.server.host else {
                LogStore.shared.log("[killlist] newest list: answered by another host; ignored")
                return
            }
            guard http?.statusCode == 200, let data, let sig = http?.value(forHTTPHeaderField: "x-madeira-signature"),
                  SharedConfigs.verify(data, signature: sig), let entries = parse(data) else {
                LogStore.shared.log("[killlist] newest list: not used (status \(http?.statusCode ?? 0)); the kept one stays")
                return
            }
            // An older signed file than the kept one is a replay: keep what we have.
            if let made = madeStamp(data), let keptMade = keptParts().flatMap({ madeStamp($0.1) }), made < keptMade {
                LogStore.shared.log("[killlist] newest list is older than the kept one; ignored")
                return
            }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try (Data((sig.trimmingCharacters(in: .whitespacesAndNewlines) + "\n").utf8) + data).write(to: signedURL, options: .atomic)
                LogStore.shared.log("[killlist] newest list kept: \(entries.count) entr\(entries.count == 1 ? "y" : "ies"); applies from the next start")
            } catch {
                LogStore.shared.log("[killlist] could not keep the list: \(error.localizedDescription)", level: .error)
            }
        }.resume()
    }
}
