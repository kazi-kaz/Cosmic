// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
//  madeira-shared-configs: settings other players said work for a game, approved by
//  the team, used as that game's recommended settings (plan: auto-apply shared configs,
//  owner's go 2026-11-14).
//
//  The Get Help server counts a player's "Yes, the fix worked" once per device. Lines
//  3 players on 3 networks said worked go on the team's review page; only lines the team
//  approves go into GET /shared/configs, signed with Ed25519. Madeira downloads it at
//  most every 6 hours, keeps it only when the signature checks with `publicKey`, and
//  checks it again every time it reads it.
//
//  A game with a list of its own in GameRecommendations keeps it. A game that would
//  get the standard list gets the standard list plus the shared lines instead, through
//  the same first-sight rules (GameRecommendationsApply.swift): written only into that
//  game's own config, never over a config the player wrote or changed, and Reset to
//  Recommended writes them again. A shared list the team pulls (or this switch off)
//  goes back to the standard list in every config nobody changed.
//
//  The first time it writes them by itself, the library asks Keep or Undo (SharedConfigsView.swift).
//  Undo puts the standard list back and the game keeps it as its own.
//
//  Off: Settings › All settings › App & front end › Shared settings from other players
//  (env.MADEIRA_SHARED_CONFIGS = 0). No MadeiraSharedConfigsKey in the build's Info.plist: off.
//  Logs: [shared-configs] ...

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking   // URLRequest/URLSession on Linux (the host check); nothing on iOS
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

enum SharedConfigs {
    /// Settings other players said work, used as a game's recommended settings. 0 turns it off.
    static let enabled = MadeiraConfig.flag("MADEIRA_SHARED_CONFIGS")
    /// The server's Ed25519 public key (base64 of the 32 raw bytes), from the build's Info.plist
    /// (MadeiraSharedConfigsKey, put there by set-shared-configs-key.sh like the Get Help key). Empty: off.
    static let publicKey: String = {
        guard let key = (Bundle.main.infoDictionary?["MadeiraSharedConfigsKey"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              Data(base64Encoded: key)?.count == 32 else { return "" }
        return key
    }()
    static let refreshEvery: TimeInterval = 6 * 3600
    static let idPrefix = "shared-"

    struct Line: Codable, Equatable { let key: String; let value: String }
    struct Config: Codable, Equatable { let game: String; let game_key: String; let lines: [Line] }
    struct File: Codable { let format: Int; let made: String; let configs: [Config] }

    /// The same key the server makes from a game's name (results.ts gameKey).
    static func gameKey(_ title: String) -> String {
        var out = "", dash = false
        for c in title.lowercased().unicodeScalars {
            if ("a"..."z").contains(c) || ("0"..."9").contains(c) {
                if dash && !out.isEmpty { out.append("-") }
                out.unicodeScalars.append(c)
                dash = false
            } else {
                dash = true
            }
        }
        let key = String(out.prefix(60))
        return key.isEmpty ? "unknown" : key
    }

    /// A line Madeira will write: a plain key, and a value on one line.
    static func safe(_ line: Line) -> Bool {
        let keyOK = !line.key.isEmpty && line.key.count <= 80 && line.key.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)
        }
        let value = line.value.trimmingCharacters(in: .whitespaces)
        return keyOK && !value.isEmpty && value.count <= 300 && !value.contains("\n") && !value.contains("\r")
    }

    /// The configs in a file, by game key; nil when it is not a file Madeira knows.
    static func parse(_ data: Data) -> [String: Config]? {
        guard let file = try? JSONDecoder().decode(File.self, from: data), file.format == 1 else { return nil }
        var out: [String: Config] = [:]
        for c in file.configs where !c.lines.isEmpty && c.lines.allSatisfy(safe) { out[c.game_key] = c }
        return out
    }

    /// The text the game's config gets: the standard list, then the shared lines.
    static func configText(_ c: Config, standard: String) -> String {
        standard + "\n# Shared settings: other players said these work for this game, and Madeira approved them.\n"
            + c.lines.map { "\($0.key) = \($0.value.trimmingCharacters(in: .whitespaces))" }.joined(separator: "\n")
    }

    /// The shared recommendation for a game, from `configs`; nil when there is none.
    static func recommendation(title: String, configs: [String: Config]?, standard: GameRecommendation) -> GameRecommendation? {
        guard let c = configs?[gameKey(title)] else { return nil }
        return GameRecommendation(id: idPrefix + c.game_key, title: title, version: 1,
                                  config: configText(c, standard: standard.config))
    }

    static func isShared(_ rec: GameRecommendation?) -> Bool { rec?.id.hasPrefix(idPrefix) == true }

    // MARK: - Keep or Undo

    /// A game Madeira just gave shared settings by itself, waiting for the player's Keep or Undo
    /// (SharedConfigsNotice in SharedConfigsView.swift shows them one at a time in the library).
    struct Applied: Equatable, Identifiable { let title: String; let windowsPath: String; var id: String { windowsPath } }
    static let appliedNotification = Notification.Name("madeira.shared-configs.applied")
    private static let pendingLock = NSLock()
    nonisolated(unsafe) private static var pendingList: [Applied] = []

    /// From GameRecommendationsApply after it wrote a shared list on first sight or an update.
    static func applied(title: String, windowsPath: String) {
        pendingLock.lock()
        if !pendingList.contains(where: { $0.windowsPath == windowsPath }) { pendingList.append(Applied(title: title, windowsPath: windowsPath)) }
        pendingLock.unlock()
        LogStore.shared.log("[shared-configs] \(title): shared settings written; asking Keep or Undo")
        NotificationCenter.default.post(name: appliedNotification, object: nil)
    }

    /// The next game to ask about, and taking it off the list once answered.
    static var nextPending: Applied? { pendingLock.lock(); defer { pendingLock.unlock() }; return pendingList.first }
    static func answered(_ a: Applied) {
        pendingLock.lock(); pendingList.removeAll { $0.windowsPath == a.windowsPath }; pendingLock.unlock()
    }

    // MARK: - On the device

    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded: [String: Config]?? = nil

    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SharedConfigs", isDirectory: true)
    }
    private static var dataURL: URL { folder.appendingPathComponent("shared-configs.json") }
    private static var signatureURL: URL { folder.appendingPathComponent("shared-configs.sig") }

    /// Whether `signature` (base64) is the server's signature of `data`.
    static func verify(_ data: Data, signature: String, key: String = publicKey) -> Bool {
        #if canImport(CryptoKit)
        guard let raw = Data(base64Encoded: key), raw.count == 32,
              let sig = Data(base64Encoded: signature.trimmingCharacters(in: .whitespacesAndNewlines)),
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
        return pub.isValidSignature(sig, for: data)
        #else
        return false
        #endif
    }

    /// The kept file's configs, checked once per start (and again after a download).
    static func configs() -> [String: Config]? {
        guard enabled, !publicKey.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        if let loaded { return loaded }
        var found: [String: Config]? = nil
        if let data = try? Data(contentsOf: dataURL), let sig = try? String(contentsOf: signatureURL, encoding: .utf8) {
            if verify(data, signature: sig) { found = parse(data) }
            else { LogStore.shared.log("[shared-configs] kept file failed its signature check; not used", level: .error) }
        }
        loaded = .some(found)
        return found
    }

    /// The shared recommendation for a library game's title, if any.
    static func recommendation(title: String) -> GameRecommendation? {
        recommendation(title: title, configs: configs(), standard: GameRecommendations.standard)
    }

    /// Asks the Get Help server for the newest file, at most every `refreshEvery`. Does not wait.
    static func refresh() {
        guard enabled, !publicKey.isEmpty, GetHelp.enabled, let key = GetHelp.key else { return }
        let last = UserDefaults.standard.double(forKey: "shared-configs-checked")
        let now = Date().timeIntervalSince1970
        guard now - last >= refreshEvery else { return }
        UserDefaults.standard.set(now, forKey: "shared-configs-checked")
        var request = URLRequest(url: GetHelpCore.server.appendingPathComponent("shared/configs"), timeoutInterval: 20)
        request.setValue(key, forHTTPHeaderField: "x-madeira-key")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let http = response as? HTTPURLResponse
            guard http?.statusCode == 200, let data, let sig = http?.value(forHTTPHeaderField: "x-madeira-signature"),
                  verify(data, signature: sig), let configs = parse(data) else {
                LogStore.shared.log("[shared-configs] newest file: not used (status \(http?.statusCode ?? 0))")
                return
            }
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: dataURL, options: .atomic)
                try Data(sig.utf8).write(to: signatureURL, options: .atomic)
                lock.lock(); loaded = .some(configs); lock.unlock()
                LogStore.shared.log("[shared-configs] newest file kept: \(configs.count) game\(configs.count == 1 ? "" : "s")")
            } catch {
                LogStore.shared.log("[shared-configs] could not keep the file: \(error.localizedDescription)", level: .error)
            }
        }.resume()
    }
}
