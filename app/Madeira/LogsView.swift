// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
//  Settings › Logs: every log Madeira keeps, in one place, to read or share.
//
//  Players kept asking where their logs are. They are in Documents, which the
//  Files app shows (On My iPhone/iPad › Madeira), but few people find that,
//  and a whole log carries personal details (PrivacyScrub.swift says which).
//  This page lists them: the session summary, the last log with a game in it,
//  this run's and the previous run's log, and each game session's own log
//  (Documents/logs, LogStore.startSessionLog). Tapping one shows its end;
//  Share sends a copy with personal details taken out.
//
//  Share Logs (here and on Game details) makes one plain "<game> log.txt" for a
//  bug report (get-help-auto): Get Help's short scrubbed report, about 30 KB.
//  The Madeira Discord's bot deletes .zip files, and Discord previews a .txt.
//  LogFiles.bundle (the old .zip) is kept but no button uses it.
//  Nothing is sent anywhere by Madeira itself.
//

import Foundation
import SwiftUI
import zlib

enum LogFiles {
    struct Item: Identifiable, Hashable {
        let url: URL
        let title: String
        var id: String { url.path }
    }

    static var documents: URL? { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first }

    /// The fixed logs in Documents, then Documents/logs newest first.
    static func items() -> (main: [Item], sessions: [Item]) {
        guard let docs = documents else { return ([], []) }
        let fm = FileManager.default
        var main: [Item] = []
        let game = lastGame(in: docs)
        for (name, title) in [(LogSummary.fileName, "Session summary"),
                              (LogSummary.gameLogName, "Last game log" + (game.map { " (\($0))" } ?? "")),
                              ("madeira-log.txt", "This run's log"),
                              ("madeira-log.prev.txt", "Previous run's log")] {
            let url = docs.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { main.append(Item(url: url, title: title)) }
        }
        let folder = docs.appendingPathComponent("logs", isDirectory: true)
        let sessions = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "txt" }
            .sorted { modified($0) > modified($1) }
            .map { Item(url: $0, title: $0.deletingPathExtension().lastPathComponent) }
        return (main, sessions)
    }

    static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    static func detail(_ url: URL) -> String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        return size + " · " + modified(url).formatted(date: .abbreviated, time: .shortened)
    }

    /// The "Program:" line of madeira-summary.txt: the game the last game log is from.
    static func lastGame(in docs: URL) -> String? {
        guard let text = try? String(contentsOf: docs.appendingPathComponent(LogSummary.fileName), encoding: .utf8) else { return nil }
        return text.split(separator: "\n").first { $0.hasPrefix("Program: ") }
            .map { String($0.dropFirst("Program: ".count).prefix { $0 != "(" }).trimmingCharacters(in: .whitespaces) }
    }

    static var shareFolder: URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SharedLogs", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A scrubbed copy to share, under the same name.
    static func scrubbedCopy(of url: URL) throws -> URL {
        let out = shareFolder.appendingPathComponent(url.lastPathComponent)
        let changed = try PrivacyScrub.copy(from: url, to: out)
        // (log-lastrun) This launch's log alone shares none of the game played before Madeira was opened again.
        let extra = url.lastPathComponent == "madeira-log.txt" ? RunLedger.previousLaunchRun() + (RunLedger.tailText() ?? "") : ""
        if !extra.isEmpty, let handle = try? FileHandle(forWritingTo: out) {
            _ = try? handle.seekToEnd(); handle.write(Data(extra.utf8)); try? handle.close()
        }
        LogStore.shared.log("[logs] share \(url.lastPathComponent) (\(changed) lines with personal details taken out)")
        return out
    }

    /// The end of a log, scrubbed, for the viewer: at most `lines` lines from its last 512 KB.
    static func tail(of url: URL, lines: Int = 600) -> [String] {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        var ring: [String] = []
        LogLines.forEach(in: url, fromByte: size > 512 * 1024 ? size - 512 * 1024 : 0) { line in
            ring.append(line.count > 400 ? String(line.prefix(400)) + " ..." : line)
            if ring.count > lines { ring.removeFirst(ring.count - lines) }
        }
        return ring.map(PrivacyScrub.line)
    }

    /// One .zip for a bug report: the summary, the last game log, this run's log
    /// and madeira.cfg, each scrubbed.
    static func bundle() throws -> URL {
        guard let docs = documents else { throw CocoaError(.fileNoSuchFile) }
        let fm = FileManager.default
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd_HH-mm"
        let zipURL = shareFolder.appendingPathComponent("Madeira-logs-\(stamp.string(from: Date())).zip")
        try? fm.removeItem(at: zipURL)
        let zip = try LogZip(url: zipURL)
        var names: [String] = []
        for name in [LogSummary.fileName, LogSummary.gameLogName, "madeira-log.txt", MadeiraConfig.fileName] {
            let source = docs.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { continue }
            let entry = name.hasSuffix(".cfg") ? name + ".txt" : name
            let copy = shareFolder.appendingPathComponent(entry)
            try PrivacyScrub.copy(from: source, to: copy)
            try zip.add(name: entry, data: Data(contentsOf: copy, options: .alwaysMapped))
            try? fm.removeItem(at: copy)
            names.append(entry)
        }
        try zip.finish()
        LogStore.shared.log("[logs] bundle \(zipURL.lastPathComponent): \(names.joined(separator: ", "))")
        return zipURL
    }
}

/// A deflated zip, written one entry at a time (no zip64: logs are far below 4 GB).
final class LogZip {
    private let handle: FileHandle
    private var central = Data()
    private var count = 0
    private var offset: UInt32 = 0

    init(url: URL) throws {
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    private static func le16(_ v: Int) -> Data { var x = UInt16(truncatingIfNeeded: v).littleEndian; return Data(bytes: &x, count: 2) }
    private static func le32(_ v: UInt32) -> Data { var x = v.littleEndian; return Data(bytes: &x, count: 4) }

    /// Raw deflate (no zlib header), as zip's method 8 expects.
    static func deflate(_ input: Data) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, 6, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION,
                            Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { deflateEnd(&stream) }
        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        var status = Z_OK
        try input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(raw.count)
            repeat {
                status = chunk.withUnsafeMutableBufferPointer { buffer -> Int32 in
                    stream.next_out = buffer.baseAddress
                    stream.avail_out = uInt(buffer.count)
                    return zlib.deflate(&stream, Z_FINISH)
                }
                guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else { throw CocoaError(.fileWriteUnknown) }
                out.append(chunk, count: chunk.count - Int(stream.avail_out))
            } while status != Z_STREAM_END
        }
        return out
    }

    func add(name: String, data: Data) throws {
        let n = Data(name.utf8)
        let crc = data.withUnsafeBytes { raw -> UInt32 in
            UInt32(crc32(0, raw.bindMemory(to: Bytef.self).baseAddress, uInt(raw.count)))
        }
        let packed = try Self.deflate(data)
        // Version 2.0, UTF-8 names (bit 11), deflate, 1980-01-01 00:00.
        func header(central: Bool) -> Data {
            var h = Data()
            h += Self.le32(central ? 0x0201_4b50 : 0x0403_4b50)
            if central { h += Self.le16(20) }
            h += Self.le16(20); h += Self.le16(0x0800); h += Self.le16(8)
            h += Self.le16(0); h += Self.le16(0x21)
            h += Self.le32(crc); h += Self.le32(UInt32(packed.count)); h += Self.le32(UInt32(data.count))
            h += Self.le16(n.count); h += Self.le16(0)
            if central {
                h += Self.le16(0); h += Self.le16(0); h += Self.le16(0); h += Self.le32(0); h += Self.le32(offset)
            }
            return h + n
        }
        let local = header(central: false)
        central += header(central: true)
        try handle.write(contentsOf: local)
        try handle.write(contentsOf: packed)
        offset += UInt32(local.count + packed.count)
        count += 1
    }

    func finish() throws {
        var end = Data()
        end += Self.le32(0x0605_4b50); end += Self.le16(0); end += Self.le16(0)
        end += Self.le16(count); end += Self.le16(count)
        end += Self.le32(UInt32(central.count)); end += Self.le32(offset); end += Self.le16(0)
        try handle.write(contentsOf: central)
        try handle.write(contentsOf: end)
        try handle.close()
    }
}

private struct SharedLogs: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// "Share Logs": (get-help-auto) one plain "<game> log.txt", the same file as Save copy for Discord
/// (DiscordLog, GetHelpView.swift): Get Help's short scrubbed report plus (discord-full-log) the
/// whole scrubbed log, up to 5 MB, made in the background. Not a .zip any more: the
/// Madeira Discord's bot deletes zips, and Discord shows a .txt. LogFiles.bundle stays for
/// anyone who wants the whole logs (the rows below share each one).
struct ShareLogsButton: View {
    /// Game details › Advanced: that game's config goes in the report and names the file.
    var entry: LibraryEntry? = nil
    @State private var shared: SharedLogs?
    @State private var busy = false
    @State private var failed: String?
    var body: some View {
        Button {
            guard !busy else { return }
            busy = true
            let entry = entry
            let game = entry.map(ClaudeHelp.gameText)
            let device = ClaudeHelp.deviceLine()
            let folder = GameOwnLogs.game(for: entry)   // (share-game-logs) read on main
            DispatchQueue.global(qos: .userInitiated).async {
                let url = DiscordLog.file(title: entry?.title, report: GetHelp.report(game: game, title: entry?.title, device: device), gameFolder: folder)
                DispatchQueue.main.async {
                    busy = false
                    if let url { shared = SharedLogs(urls: [url]) } else { failed = L("Madeira couldn't write the file. Try again.") }
                }
            }
        } label: {
            HStack {
                Label("Share Logs", systemImage: "doc.text")
                if busy { Spacer(); ProgressView() }
            }
        }
        .disabled(busy)
        .sheet(item: $shared) { ActivitySheet(items: $0.urls) }
        .alert("Could not make the logs file", isPresented: Binding(get: { failed != nil }, set: { if !$0 { failed = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(failed ?? "") }
    }
}

/// (debug-logging) Game details › Advanced, test bundle only: this game's last run and its own config as one scrubbed .zip.
struct DebugShareGameLogsButton: View {
    let entry: LibraryEntry
    @State private var shared: SharedLogs?
    @State private var busy = false
    @State private var failed = false
    var body: some View {
        Button {
            guard !busy else { return }
            busy = true
            let title = entry.title, path = entry.windowsPath
            DispatchQueue.global(qos: .userInitiated).async {
                let url = DebugLogging.shareZip(title: title, windowsPath: path)
                DispatchQueue.main.async {
                    busy = false
                    if let url { shared = SharedLogs(urls: [url]) } else { failed = true }
                }
            }
        } label: {
            HStack {
                Label { Text(verbatim: "Share this game's logs") } icon: { Image(systemName: "doc.zipper") }
                if busy { Spacer(); ProgressView() }
            }
        }
        .disabled(busy)
        .sheet(item: $shared) { ActivitySheet(items: $0.urls) }
        .alert(Text(verbatim: "Could not make the logs file"), isPresented: $failed) {
            Button(role: .cancel) {} label: { Text(verbatim: "OK") }
        } message: { Text(verbatim: "Madeira couldn't write the zip. Try again.") }
    }
}

/// (debug-logging) Game details › Advanced, test bundle only: takes the Debug logging lines and the lines Get Help
/// added out of this game's own config (and nothing else), after a confirmation.
struct DebugResetButton: View {
    let entry: LibraryEntry
    var changed: () -> Void
    @State private var ask = false
    @State private var counts = (debug: 0, getHelp: 0)
    var body: some View {
        Button(role: .destructive) {
            counts = DebugLogging.cleanCounts(windowsPath: entry.windowsPath)
            ask = true
        } label: {
            Label { Text(verbatim: "Reset to clean state") } icon: { Image(systemName: "eraser") }
        }
        .confirmationDialog(Text(verbatim: "Reset \(entry.title) to a clean state?"), isPresented: $ask, titleVisibility: .visible) {
            Button(role: .destructive) {
                DebugLogging.resetToClean(windowsPath: entry.windowsPath, title: entry.title)
                changed()
            } label: { Text(verbatim: "Reset") }
            Button(role: .cancel) {} label: { Text(verbatim: "Cancel") }
        } message: {
            Text(verbatim: counts.debug + counts.getHelp == 0
                 ? "This game's config has no Debug logging or Get Help lines. Nothing changes."
                 : "Takes \(counts.debug) Debug logging line(s) and \(counts.getHelp) line(s) Get Help added out of this game's config. Every other line stays. madeira.cfg is not touched.")
        }
    }
}
/// Settings › Logs.
struct LogsSection: View {
    @State private var main: [LogFiles.Item] = []
    @State private var sessions: [LogFiles.Item] = []

    var body: some View {
        Section {
            ShareLogsButton()
        } footer: {
            Text("Share Logs makes one text file (up to 5 MB) with the last game's log and your settings, with personal details taken out. Post it in the Madeira Discord. To send another log, tap it below and share it.")
        }
        .onAppear { reload() }
        CrashReportsSection()   // (crash-reports) Send crash reports, CrashReports.swift
        Section {
            if main.isEmpty { Text("No logs yet. Play a game once and its log shows here.").foregroundStyle(.secondary) }
            ForEach(main) { row($0) }
        }
        if !sessions.isEmpty {
            Section {
                ForEach(sessions) { row($0) }
            } header: { Text("Game sessions") } footer: {
                Text("Each game session's own log, newest first. Tap one to read its end. The same files are in the Files app: On My iPhone or On My iPad > Madeira.")
            }
        }
    }

    private func reload() {
        DispatchQueue.global(qos: .userInitiated).async {
            let found = LogFiles.items()
            DispatchQueue.main.async { main = found.main; sessions = found.sessions }
        }
    }

    private func row(_ item: LogFiles.Item) -> some View {
        NavigationLink { LogViewer(item: item) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: item.title).lineLimit(1)
                Text(verbatim: LogFiles.detail(item.url)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// The end of one log, scrubbed, with Share for a scrubbed copy of the whole file.
struct LogViewer: View {
    let item: LogFiles.Item
    @State private var lines: [String]?
    @State private var shared: SharedLogs?
    @State private var busy = false

    var body: some View {
        Group {
            if let lines {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            Text("Showing the last \(lines.count) lines, with personal details taken out.")
                                .font(.caption).foregroundStyle(.secondary).padding(.bottom, 8)
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                Text(verbatim: line).font(.system(.caption2, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading).id(index)
                            }
                        }
                        .textSelection(.enabled)
                        .padding()
                    }
                    .onAppear { if !lines.isEmpty { proxy.scrollTo(lines.count - 1, anchor: .bottom) } }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(Text(verbatim: item.title)).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    guard !busy else { return }
                    busy = true
                    let url = item.url
                    DispatchQueue.global(qos: .userInitiated).async {
                        let copy = try? LogFiles.scrubbedCopy(of: url)
                        DispatchQueue.main.async {
                            busy = false
                            if let copy { shared = SharedLogs(urls: [copy]) }
                        }
                    }
                } label: {
                    if busy { ProgressView() } else { Label("Share", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .sheet(item: $shared) { ActivitySheet(items: $0.urls) }
        .onAppear {
            guard lines == nil else { return }
            let url = item.url
            DispatchQueue.global(qos: .userInitiated).async {
                let tail = LogFiles.tail(of: url)
                DispatchQueue.main.async { lines = tail }
            }
        }
    }
}

//
//  (share-game-logs, Cameron Nov 21: "why aren't all the logs coming with that? we are debugging")
//  The log files a game writes itself, inside drive_c, added to the one shared "<game> log.txt"
//  (DiscordLog.file: Share Logs in Settings and Game details, Save copy for Discord).
//
//  madeira-log.txt holds Wine's, FEX's and Madeira's lines, and the Documents/logs/<exe>-<time>.txt
//  files are hard links to it (LogStore.startSessionLog), so they add nothing. What was missing is
//  what the game, its launcher or Steam write on their own: a launcher's .log, Unity's Player.log,
//  Unreal's Saved/Logs, a crash .txt, Steam's logs folder.
//
//  Where it looks:
//   - the game's own folder (its library path; for an Unreal Binaries/Win64 exe, the game folder
//     above it), 4 levels deep: log files written in the last 7 days. Never a shared folder
//     (C:\, Program Files, Games, Steam, steamapps, users, External) or one holding another game;
//   - users/*/AppData (Local, LocalLow, Roaming), users/*/Documents, users/*/Saved Games and
//     Program Files (x86)/Steam/logs: log files written during this game's last run (its newest
//     Documents/logs session, minus 2 minutes), so other games' logs stay out.
//  Never: browser storage (LevelDB "000003.log" files in Local Storage, IndexedDB, webcache,
//  BrowserCaches: they hold sign-in state), login/chat/changelog files, binary files, symlinks.
//  The newest 12 files go in, each at most its last 256 KB, all together at most 1 MB; each line
//  is scrubbed (PrivacyScrub: tokens, passwords, user names, Steam IDs, e-mails, public IPs), then cut
//  to 2000 characters. Read-only: nothing in drive_c is changed.
//
//  Off switch: env.MADEIRA_SHARE_GAME_LOGS = 0 (the shared file is then as before).
//
enum GameOwnLogs {
    static var enabled: Bool { MadeiraConfig.flag("MADEIRA_SHARE_GAME_LOGS") }
    static let maxFiles = 12
    static let perFileCap: UInt64 = 256 * 1024
    static let totalCap = 1024 * 1024
    /// Files one walk looks at before it stops: the game folder, and the other places together.
    static let gameVisits = 15_000
    static let otherVisits = 25_000
    /// Folders never walked: caches, browser storage (sign-in state), other installs, Madeira's own.
    static let skipFolders: Set<String> = ["cache", "caches", "htmlcache", "gpucache", "code cache", "shadercache",
                                           "shader cache", "dxcache", "nvidia", "steamapps", "crashpad", "inetcache",
                                           "temp", "tmp", "packages", "madeira-games", "leveldb", "local storage",
                                           "session storage", "indexeddb", "service worker", "blob_storage",
                                           "browsercaches", "cookies", "webstorage", "databases", "external"]
    /// Top folders (relative to drive_c, lower case) that hold many games: never walked as "the game's folder".
    static let sharedFolders: Set<String> = ["", "games", "program files", "program files (x86)", "programdata",
                                             "program files (x86)/steam", "program files/steam",
                                             "program files (x86)/steam/steamapps", "program files (x86)/steam/steamapps/common",
                                             "program files/steam/steamapps", "program files/steam/steamapps/common",
                                             "program files/epic games", "program files (x86)/gog galaxy/games", "gog games",
                                             "users", "windows", "external"]

    struct Game { let windowsPath: String; let exe: String?; let others: [String] }

    /// Main thread: the game whose logs go in. The entry when there is one (Game details), else the
    /// library entry of the last game played (Settings › Logs), matched by title or program name.
    static func game(for entry: LibraryEntry?) -> Game? {
        guard enabled else { return nil }
        let entries = LibraryModel.shared.entries
        var chosen = entry
        if chosen == nil, let docs = LogFiles.documents, let name = LogFiles.lastGame(in: docs)?.lowercased() {
            chosen = entries.first { $0.title.lowercased() == name }
                ?? entries.first { ($0.launchRelativePath.split(separator: "/").last.map { $0.lowercased() } ?? "") == name }
        }
        guard let chosen else { return nil }
        let exe = chosen.launchRelativePath.split(separator: "/").last.map(String.init)
        let others = entries.filter { $0.id != chosen.id }.map(\.windowsPath)
        return Game(windowsPath: chosen.windowsPath, exe: exe?.lowercased().hasSuffix(".exe") == true ? exe : nil, others: others)
    }

    /// A log file by name: .log, or a .txt named as a log; never a login, chat or changelog file, never a
    /// LevelDB/Chromium "000123.log".
    static func isLogName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower.hasPrefix("madeira") { return false }
        if ["login", "dialog", "catalog", "changelog", "chat", "password", "token", "cookie", "blog"].contains(where: { lower.contains($0) }) { return false }
        let stem = lower.split(separator: ".").first.map(String.init) ?? lower
        if !stem.isEmpty, stem.allSatisfy(\.isNumber) { return false }
        if lower.hasSuffix(".log") { return true }
        guard lower.hasSuffix(".txt") else { return false }
        let words = Set(stem.split(whereSeparator: { !$0.isLetter }).map(String.init))
        return !words.isDisjoint(with: ["log", "logs", "crash", "error", "errors", "debug", "exception", "player", "output"])
            || stem.hasSuffix("log") && !stem.hasSuffix("blog")
    }

    /// A file with a NUL byte in its first 4 KB is binary: left out.
    static func isText(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 4096)) ?? Data()
        return !head.contains(0)
    }

    /// The newest game launch from the Documents/logs/<exe>-<yyyy-MM-dd_HH-mm-ss>.txt names: of `exe`
    /// when given and found, else of any game. A time in the future (another calendar) is ignored.
    static func lastLaunch(in docs: URL, exe: String?) -> Date? {
        let folder = docs.appendingPathComponent("logs", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let soon = Date().addingTimeInterval(300)
        let all = names.compactMap { name -> (String, Date)? in
            guard name.hasSuffix(".txt"), name.count > 24,
                  let d = stamp.date(from: String(name.dropLast(4).suffix(19))), d < soon else { return nil }
            return (String(name.dropLast(24)).lowercased(), d)
        }
        if let exe, let mine = all.filter({ $0.0 == exe.lowercased() }).map(\.1).max() { return mine }
        return all.map(\.1).max()
    }

    struct Found { let url: URL; let shown: String; let modified: Date; let size: UInt64 }

    /// Log files under `root`, at most `depth` folders down, written at or after `since`.
    static func walk(_ root: URL, depth: Int, since: Date, drive: String, budget: inout Int, into found: inout [Found]) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey]
        guard budget > 0, let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                                      options: [.skipsPackageDescendants]) else { return }
        for case let url as URL in walker {
            budget -= 1
            if budget <= 0 { return }
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isSymbolicLink == true { if v.isDirectory == true { walker.skipDescendants() }; continue }
            if v.isDirectory == true {
                let name = url.lastPathComponent.lowercased()
                if walker.level >= depth || skipFolders.contains(name) || name.hasPrefix("webcache") { walker.skipDescendants() }
                continue
            }
            guard isLogName(url.lastPathComponent), let modified = v.contentModificationDate, modified >= since,
                  let size = v.fileSize, size > 0, isText(url) else { continue }
            let path = url.resolvingSymlinksInPath().path
            let shown = path.hasPrefix(drive) ? "C:\\" + path.dropFirst(drive.count).replacingOccurrences(of: "/", with: "\\") : url.lastPathComponent
            found.append(Found(url: url, shown: shown, modified: modified, size: UInt64(size)))
        }
    }

    /// drive_c-relative, lower case path of a folder already resolved under `drive`.
    static func relative(_ path: String, drive: String) -> String? {
        if path + "/" == drive { return "" }
        guard path.hasPrefix(drive) else { return nil }
        return String(path.dropFirst(drive.count)).lowercased()
    }

    /// The section for the shared file, "" when off or nothing was found. Off the main thread.
    static func section(game: Game?, limit: Int = totalCap) -> String {
        guard enabled, limit > 4096, let docs = LogFiles.documents else { return "" }
        let fm = FileManager.default
        let driveURL = LibraryEntry.hostDrive.resolvingSymlinksInPath()
        guard fm.fileExists(atPath: driveURL.path) else { return "" }
        let drive = driveURL.path.hasSuffix("/") ? driveURL.path : driveURL.path + "/"
        var found: [Found] = []
        var walked = Set<String>()
        // The game's own folder: its files are its own, so a week back.
        var gameFolder = false
        if let game, let exe = LibraryEntry.hostURL(ofWindowsPath: game.windowsPath) {
            var folder = GetHelpUpload.listFolder(of: exe, ownFolder: true).resolvingSymlinksInPath()
            // Unreal: <Game>/Binaries/Win64/x.exe keeps its logs in <Game>/Saved/Logs.
            if folder.lastPathComponent.lowercased().hasPrefix("win"), folder.deletingLastPathComponent().lastPathComponent.lowercased() == "binaries" {
                folder = folder.deletingLastPathComponent().deletingLastPathComponent()
            }
            let path = folder.path
            let others = game.others.compactMap { LibraryEntry.hostURL(ofWindowsPath: $0)?.resolvingSymlinksInPath().path }
            let holdsOther = others.contains { $0.hasPrefix(path + "/") }
            if let rel = relative(path, drive: drive), !sharedFolders.contains(rel), !rel.hasPrefix("external"), !holdsOther {
                gameFolder = true
                walked.insert(path)
                var budget = gameVisits
                walk(folder, depth: 4, since: Date().addingTimeInterval(-7 * 24 * 3600), drive: drive, budget: &budget, into: &found)
            }
        }
        // Everywhere else: only what this game's last run wrote. Steam's logs first (small).
        let since = (lastLaunch(in: docs, exe: game?.exe) ?? Date().addingTimeInterval(-3600)).addingTimeInterval(-120)
        var roots: [(URL, Int)] = [(driveURL.appendingPathComponent("Program Files (x86)/Steam/logs", isDirectory: true), 1)]
        let users = driveURL.appendingPathComponent("users", isDirectory: true)
        for user in (try? fm.contentsOfDirectory(atPath: users.path)) ?? [] {
            let home = users.appendingPathComponent(user, isDirectory: true)
            for (sub, depth) in [("AppData/Local", 5), ("AppData/LocalLow", 5), ("AppData/Roaming", 5),
                                 ("Documents", 4), ("My Documents", 4), ("Saved Games", 4)] {
                roots.append((home.appendingPathComponent(sub, isDirectory: true), depth))
            }
        }
        var budget = otherVisits
        for (root, depth) in roots {
            // A start folder can be a link (Wine's Documents often points outside drive_c): resolve it,
            // keep it only inside drive_c and only once.
            let real = root.resolvingSymlinksInPath()
            guard fm.fileExists(atPath: real.path), real.path.hasPrefix(drive),
                  !walked.contains(where: { real.path == $0 || real.path.hasPrefix($0 + "/") }) else { continue }
            walked.insert(real.path)
            walk(real, depth: depth, since: since, drive: drive, budget: &budget, into: &found)
        }
        // One file once (resolved path), newest first.
        var seen = Set<String>()
        let files = found.sorted { $0.modified > $1.modified }
            .filter { seen.insert($0.url.resolvingSymlinksInPath().path).inserted }.prefix(maxFiles)
        guard !files.isEmpty else {
            LogStore.shared.log("[share-game-logs] none found (game folder: \(gameFolder ? "yes" : "no"))")
            return ""
        }
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var out = "\n\n## The game's own log files (\(files.count), newest first, personal details taken out)\n"
        out += files.map { "- \(PrivacyScrub.line($0.shown)) (\($0.size) bytes, written \(time.string(from: $0.modified)))" }.joined(separator: "\n") + "\n"
        var used = out.utf8.count
        for file in files {
            let room = limit - used - 512
            guard room > 2048 else { out += "\n(More files were left out to keep the shared file under its size cap.)\n"; break }
            let cap = min(perFileCap, UInt64(room))
            let from = file.size > cap ? file.size - cap : 0
            var part = "\n### \(PrivacyScrub.line(file.shown))\n"
            if from > 0 { part += "(Only the newest \(cap / 1024) KB of this \(file.size / 1024) KB file.)\n" }
            var first = from > 0
            LogLines.forEach(in: file.url, fromByte: from) { raw in
                if first { first = false; return }
                // Scrub the whole line first, so a cut never splits a token past the rules.
                var clean = PrivacyScrub.line(raw)
                if clean.count > 2000 { clean = String(clean.prefix(2000)) + " ..." }
                guard used + part.utf8.count + clean.utf8.count + 1 < limit else { return }
                part += clean + "\n"
            }
            out += part
            used += part.utf8.count
        }
        LogStore.shared.log("[share-game-logs] \(files.count) file(s), \(used) bytes (game folder: \(gameFolder ? "yes" : "no"))")
        return out
    }
}
