// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
// Save sync through a WebDAV server you run (docs/SAVE_SYNC.md). A library game's saves live in the
// Wine prefix (C:\users\...), so two devices running Cosmic each have their own copy. With the sync
// on, Play first brings this device up to date with the server and, when the game ends, sends what
// changed back: the Steam Cloud behaviour, for every game that is not a Steam one.
//
// What is synced is the same set of folders as Settings > Saves > Back up saves (SaveBackup.roots and
// .skipped). Nothing outside C:\users is touched, so the registry and the rest of the prefix are
// never synced.
//
// The server holds two things under the URL you give:
//   manifest.json   path -> sha256, size, modified time, for every synced file
//   blobs/<sha256>  the file contents, named by their hash
// Blobs are never overwritten or removed by the app, so an older save is always still on the server
// until you clean it up there. A file is compared three ways: this device now, the server now, and
// what both agreed on at the last sync (the baseline). Only one side changed: that side wins. Both
// changed: the newer file wins and the other is kept (a local copy goes to Documents/Save Sync
// Conflicts, which the Files app shows under Cosmic). Deleting a file is never synced: the next pass
// brings it back from the server.

import Foundation
import SwiftUI
import UIKit
import CryptoKit
import Security

// MARK: - What a file is, and what to do about it

struct SaveSyncEntry: Codable, Equatable {
    var sha: String
    var size: Int
    var mtime: Double       // seconds since 1970
}

struct SaveSyncManifest: Codable, Equatable {
    var version = 1
    var files: [String: SaveSyncEntry] = [:]
}

enum SaveSyncAction: Equatable {
    case upload(String)
    case download(String)
    /// Both sides changed since the baseline. The newer one wins; the older is kept.
    case conflictKeepLocal(String)
    case conflictKeepRemote(String)
}

enum SaveSyncPlan {
    /// `baseline` is the hash each path had when this device and the server last agreed.
    static func decide(local: [String: SaveSyncEntry], remote: [String: SaveSyncEntry],
                       baseline: [String: String]) -> [SaveSyncAction] {
        var actions: [SaveSyncAction] = []
        for path in Set(local.keys).union(remote.keys).sorted() {
            let l = local[path], r = remote[path]
            if l?.sha == r?.sha { continue }
            switch (l, r) {
            case (_?, nil): actions.append(.upload(path))
            case (nil, _?): actions.append(.download(path))
            case let (l?, r?):
                let b = baseline[path]
                if l.sha == b { actions.append(.download(path)) }          // only the server's changed
                else if r.sha == b { actions.append(.upload(path)) }       // only this device's changed
                else { actions.append(l.mtime >= r.mtime ? .conflictKeepLocal(path) : .conflictKeepRemote(path)) }
            case (nil, nil): break
            }
        }
        return actions
    }
}

// MARK: - This device's files

struct SaveSyncCache: Codable, Equatable {
    var size: Int
    var mtime: Double
    var sha: String
}

struct SaveSyncState: Codable {
    var baseline: [String: String] = [:]
    var cache: [String: SaveSyncCache] = [:]
}

enum SaveSyncLocal {
    /// Larger files are left alone: a save is not that big, and hashing one on every launch is slow.
    static let maxFile = 64 << 20

    static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Every synced file under drive_c/users, keyed like the backup zip ("users/<name>/Documents/...").
    /// `cache` skips hashing a file whose size and modified time have not changed.
    static func scan(drive: URL, cache: [String: SaveSyncCache])
        -> (files: [String: SaveSyncEntry], cache: [String: SaveSyncCache], tooLarge: Int) {
        let fm = FileManager.default
        let users = drive.appendingPathComponent("users", isDirectory: true)
        var files: [String: SaveSyncEntry] = [:]
        var fresh: [String: SaveSyncCache] = [:]
        var tooLarge = 0
        for user in (try? fm.contentsOfDirectory(atPath: users.path)) ?? [] {
            for root in SaveBackup.roots {
                let base = "users/\(user)/\(root)"
                let dir = drive.appendingPathComponent(base, isDirectory: true)
                guard let e = fm.enumerator(atPath: dir.path) else { continue }
                while let rel = e.nextObject() as? String {
                    let type = e.fileAttributes?[.type] as? FileAttributeType
                    if type == .typeDirectory {
                        if SaveBackup.skipped.contains((rel as NSString).lastPathComponent.lowercased()) { e.skipDescendants() }
                        continue
                    }
                    guard type == .typeRegular else { continue }    // links are not followed
                    let size = (e.fileAttributes?[.size] as? NSNumber)?.intValue ?? 0
                    if size > maxFile { tooLarge += 1; continue }
                    let mtime = (e.fileAttributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                    let key = base + "/" + rel
                    let sha: String
                    if let c = cache[key], c.size == size, abs(c.mtime - mtime) < 0.001 {
                        sha = c.sha
                    } else if let h = sha256(of: dir.appendingPathComponent(rel)) {
                        sha = h
                    } else {
                        continue
                    }
                    files[key] = SaveSyncEntry(sha: sha, size: size, mtime: mtime)
                    fresh[key] = SaveSyncCache(size: size, mtime: mtime, sha: sha)
                }
            }
        }
        return (files, fresh, tooLarge)
    }

    /// The same checks as SaveBackup.restore: only users/<name>/..., nothing that climbs out of drive_c.
    static func safeURL(drive: URL, key: String) -> URL? {
        let parts = key.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3, parts[0].lowercased() == "users",
              !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return parts.reduce(drive) { $0.appendingPathComponent($1) }
    }

    static func install(temp: URL, to dst: URL, mtime: Double) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.moveItem(at: temp, to: dst)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime)], ofItemAtPath: dst.path)
    }

    static var conflictsFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Save Sync Conflicts", isDirectory: true)
    }

    /// A copy of the local file a download is about to replace, at Save Sync Conflicts/<time>/<key>.
    static func keepCopy(of file: URL, key: String, stamp: String) {
        let fm = FileManager.default
        let dst = key.split(separator: "/").reduce(conflictsFolder.appendingPathComponent(stamp, isDirectory: true)) {
            $0.appendingPathComponent(String($1))
        }
        try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.copyItem(at: file, to: dst)
    }
}

// MARK: - The server

enum SaveSyncError: LocalizedError {
    case notConfigured
    case notHTTPS
    case http(Int, String)
    case badFile(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Enter the server address first."
        case .notHTTPS: return "Use https://, or http:// with a home-network address (192.168.x.x, a .local name). iOS blocks other plain http."
        case .http(401, _), .http(403, _): return "The server refused the user name or password."
        case .http(404, let what): return "The server has no \(what). Check the address."
        case .http(let code, let what): return "The server answered \(code) for \(what)."
        case .badFile(let path): return "A downloaded file did not match its checksum: \(path)"
        }
    }
}

struct WebDAVClient {
    private let base: String
    private let authorization: String?
    private let session: URLSession

    init?(address: String, user: String, password: String) throws {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard let url = URL(string: trimmed), url.host != nil else { throw SaveSyncError.notConfigured }
        // iOS refuses plain http except to the local network (Info.plist: NSAllowsLocalNetworking), which
        // is what lets a server at home be used while LocalDevVPN holds the one VPN slot (no Tailscale).
        let scheme = url.scheme?.lowercased()
        guard scheme == "https" || (scheme == "http" && Self.isLocalHost(url.host ?? "")) else { throw SaveSyncError.notHTTPS }
        base = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        authorization = user.isEmpty ? nil
            : "Basic " + Data("\(user):\(password)".utf8).base64EncodedString()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 600
        session = URLSession(configuration: configuration)
    }

    /// What NSAllowsLocalNetworking covers: private IPv4 addresses, .local names and one-word names.
    static func isLocalHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h.hasSuffix(".local") || !h.contains(".") { return true }
        let n = h.split(separator: ".").compactMap { Int($0) }
        guard n.count == 4, h.split(separator: ".").count == 4 else { return false }
        return n[0] == 10 || (n[0] == 172 && (16...31).contains(n[1])) || (n[0] == 192 && n[1] == 168)
            || (n[0] == 169 && n[1] == 254)
    }

    private func request(_ path: String, _ method: String, _ headers: [String: String] = [:]) throws -> URLRequest {
        guard let url = URL(string: base + "/" + path) else { throw SaveSyncError.notConfigured }
        var r = URLRequest(url: url)
        r.httpMethod = method
        if let authorization { r.setValue(authorization, forHTTPHeaderField: "Authorization") }
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    private func status(_ response: URLResponse) -> Int { (response as? HTTPURLResponse)?.statusCode ?? 0 }

    private func expect(_ response: URLResponse, _ ok: Set<Int>, _ what: String) throws {
        let code = status(response)
        if !ok.contains(code) { throw SaveSyncError.http(code, what) }
    }

    /// nil when the server has none yet (a first sync). The ETag lets the write back refuse to
    /// overwrite a manifest another device wrote in between, on servers that honour If-Match.
    func manifest() async throws -> (SaveSyncManifest?, String?) {
        let (data, response) = try await session.data(for: try request("manifest.json", "GET"))
        if status(response) == 404 { return (nil, nil) }
        try expect(response, [200], "manifest.json")
        let parsed = try JSONDecoder().decode(SaveSyncManifest.self, from: data)
        return (parsed, (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag"))
    }

    func putManifest(_ manifest: SaveSyncManifest, ifMatch etag: String?) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let body = try encoder.encode(manifest)
        let conditional = etag.map { ["If-Match": $0] } ?? ["If-None-Match": "*"]
        var r = try request("manifest.json", "PUT", conditional)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.upload(for: r, from: body)
        try expect(response, [200, 201, 204], "manifest.json")
    }

    /// First sync: make the folder and blobs/ (an existing one answers 405, which is fine).
    func ensureFolders() async {
        for path in ["", "blobs"] {
            if let r = try? request(path, "MKCOL") { _ = try? await session.data(for: r) }
        }
    }

    func putBlobIfMissing(sha: String, file: URL) async throws {
        let (_, head) = try await session.data(for: try request("blobs/\(sha)", "HEAD"))
        if status(head) == 200 { return }
        let (_, response) = try await session.upload(for: try request("blobs/\(sha)", "PUT"), fromFile: file)
        try expect(response, [200, 201, 204], "blobs/\(sha.prefix(8))")
    }

    /// Downloads to a temporary file of its own (the one URLSession returns is not ours to keep).
    func fetchBlob(sha: String) async throws -> URL {
        let (tmp, response) = try await session.download(for: try request("blobs/\(sha)", "GET"))
        let mine = FileManager.default.temporaryDirectory.appendingPathComponent("save-sync-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: tmp, to: mine)
        do { try expect(response, [200], "blobs/\(sha.prefix(8))") } catch {
            try? FileManager.default.removeItem(at: mine)
            throw error
        }
        return mine
    }
}

// MARK: - Password

private enum SaveSyncKeychain {
    private static let service = "madeira.saveSync"
    private static let account = "webdav"

    private static var match: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func get() -> String? {
        var query = match
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String) {
        SecItemDelete(match as CFDictionary)
        guard !value.isEmpty else { return }
        var item = match
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(item as CFDictionary, nil)
    }
}

// MARK: - The sync

@MainActor final class SaveSync: ObservableObject {
    static let shared = SaveSync()

    private enum Key {
        static let enabled = "madeira.saveSync.enabled"
        static let address = "madeira.saveSync.address"
        static let user = "madeira.saveSync.user"
    }

    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: Key.enabled) } }
    @Published var address: String { didSet { UserDefaults.standard.set(address, forKey: Key.address) } }
    @Published var user: String { didSet { UserDefaults.standard.set(user, forKey: Key.user) } }
    @Published var password: String { didSet { SaveSyncKeychain.set(password) } }
    @Published private(set) var status = "Not synced yet."
    @Published private(set) var busy = false

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: Key.enabled)
        address = d.string(forKey: Key.address) ?? ""
        user = d.string(forKey: Key.user) ?? ""
        password = SaveSyncKeychain.get() ?? ""
    }

    private func log(_ text: String, level: LogEntry.Level = .info) { LogStore.shared.log("[save-sync] " + text, level: level) }

    // What is remembered between runs.
    private static var stateURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("save-sync-state.json")
    }
    private func loadState() -> SaveSyncState {
        guard let data = try? Data(contentsOf: Self.stateURL),
              let state = try? JSONDecoder().decode(SaveSyncState.self, from: data) else { return SaveSyncState() }
        return state
    }
    private func saveState(_ state: SaveSyncState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: Self.stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.stateURL, options: .atomic)
    }

    // MARK: entry points

    /// Settings > Saves > Sync now.
    func syncNow() async { await perform("manual") }

    /// Play, before the game starts: the server's newer saves arrive first. A server that cannot be
    /// reached costs one request timeout, and the game starts anyway.
    func beforeLaunch() async {
        guard enabled else { return }
        await perform("before launch")
    }

    /// The game has ended: send what changed.
    func afterSession() async {
        guard enabled else { return }
        await perform("after session")
    }

    private func perform(_ reason: String) async {
        guard !busy else { return }
        busy = true
        let background = UIApplication.shared.beginBackgroundTask(withName: "save-sync") {}
        defer {
            busy = false
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
        }
        do {
            let summary = try await runPass()
            status = summary + " " + DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
            log("\(reason): \(summary)")
        } catch {
            status = "Sync failed: \(error.localizedDescription)"
            log("\(reason): failed: \(error.localizedDescription)", level: .error)
        }
    }

    // MARK: one pass

    private func runPass() async throws -> String {
        guard let client = try WebDAVClient(address: address, user: user, password: password) else {
            throw SaveSyncError.notConfigured
        }
        let drive = LibraryModel.drive
        var state = loadState()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        var attempt = 0
        while true {
            attempt += 1
            let cache = state.cache
            let scan = await Task.detached(priority: .utility) { SaveSyncLocal.scan(drive: drive, cache: cache) }.value
            state.cache = scan.cache
            let (manifest, etag) = try await client.manifest()
            if manifest == nil { await client.ensureFolders() }
            let remote = manifest?.files ?? [:]
            let actions = SaveSyncPlan.decide(local: scan.files, remote: remote, baseline: state.baseline)

            var newRemote = remote
            var baseline = state.baseline
            for (path, entry) in scan.files where remote[path]?.sha == entry.sha { baseline[path] = entry.sha }
            var uploaded = 0, downloaded = 0, conflicts = 0, failed = 0

            for action in actions {
                do {
                    switch action {
                    case .upload(let path), .conflictKeepLocal(let path):
                        guard let entry = scan.files[path] else { continue }
                        let file = path.split(separator: "/").reduce(drive) { $0.appendingPathComponent(String($1)) }
                        try await client.putBlobIfMissing(sha: entry.sha, file: file)
                        newRemote[path] = entry
                        baseline[path] = entry.sha
                        uploaded += 1
                        if case .conflictKeepLocal = action { conflicts += 1 }
                    case .download(let path), .conflictKeepRemote(let path):
                        guard let entry = remote[path], let dst = SaveSyncLocal.safeURL(drive: drive, key: path) else { continue }
                        let temp = try await client.fetchBlob(sha: entry.sha)
                        guard SaveSyncLocal.sha256(of: temp) == entry.sha else {
                            try? FileManager.default.removeItem(at: temp)
                            throw SaveSyncError.badFile(path)
                        }
                        if case .conflictKeepRemote = action {
                            SaveSyncLocal.keepCopy(of: dst, key: path, stamp: stamp)
                            conflicts += 1
                        }
                        try SaveSyncLocal.install(temp: temp, to: dst, mtime: entry.mtime)
                        baseline[path] = entry.sha
                        state.cache[path] = SaveSyncCache(size: entry.size, mtime: entry.mtime, sha: entry.sha)
                        downloaded += 1
                    }
                } catch {
                    failed += 1
                    log("\(error.localizedDescription)", level: .error)
                }
            }

            if uploaded > 0 {
                do {
                    try await client.putManifest(SaveSyncManifest(files: newRemote), ifMatch: etag)
                } catch SaveSyncError.http(let code, _) where code == 412 && attempt < 2 {
                    // Another device wrote the manifest while this pass ran: compare again.
                    saveState(state)
                    continue
                }
            }
            state.baseline = baseline
            saveState(state)

            var parts: [String] = []
            if uploaded > 0 { parts.append("\(uploaded) sent") }
            if downloaded > 0 { parts.append("\(downloaded) received") }
            var summary = parts.isEmpty ? "Up to date" : parts.joined(separator: ", ")
            if conflicts > 0 {
                summary += "; \(conflicts) changed on both devices (the newer kept; the older copy is on the server, and local ones are in Files > Cosmic > Save Sync Conflicts)"
            }
            if failed > 0 { summary += "; \(failed) failed" }
            if scan.tooLarge > 0 { summary += "; \(scan.tooLarge) files over 64 MB skipped" }
            return summary + "."
        }
    }
}

// MARK: - Settings

/// Settings > Saves, under the backup buttons.
struct SaveSyncSection: View {
    @ObservedObject private var sync = SaveSync.shared

    var body: some View {
        Section {
            Toggle("Sync saves with my server", isOn: $sync.enabled)
            TextField("http://192.168.1.x:8090", text: $sync.address)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            TextField("User name", text: $sync.user)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password", text: $sync.password)
            Button {
                Task { await sync.syncNow() }
            } label: {
                HStack {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                    if sync.busy { Spacer(); ProgressView() }
                }
            }
            .disabled(sync.busy || sync.address.isEmpty)
            Text(sync.status).font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("Save sync (WebDAV)")
        } footer: {
            Text("With this on, Play first fetches newer saves from your server and, when the game ends, sends "
                 + "what changed. Steam games keep using Steam Cloud. If both devices changed the same file, the "
                 + "newer one wins and the older is kept. A file you delete here comes back at the next sync. See docs/SAVE_SYNC.md.")
        }
    }
}
