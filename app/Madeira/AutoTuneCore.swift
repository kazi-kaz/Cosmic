//
//  AutoTuneCore.swift
//  Madeira
//
//  (auto-tune) The part of auto-tune that needs no app: the rule model, the rule
//  table, the log scan, which rule fits a run, and whether a fix that was tried
//  stays. Foundation only, so the host test can build it with swiftc on its own.
//
//  A rule says: when a game ended this way (it crashed, iOS closed it) and its log
//  has every one of these lines and none of those, adding these lines to the
//  game's own config is worth one try. Every rule names our own logs that showed
//  the line ("evidence"); a rule without evidence is refused when the table loads.
//  Rules are written by us from our own fixes, not taken from anywhere else.
//
//  Nothing here writes a file. AutoTune.swift reads the log, keeps the per-game
//  state and goes through Get Help's shared Apply and Undo (GetHelp.apply with
//  source .autoTune(rule id)).
//

import Foundation

enum AutoTuneCore {

    // MARK: Model

    /// How a run ended, as auto-tune sorts it.
    enum Ending: String, Codable, CaseIterable {
        /// It stopped by itself: a Windows error, an exit code other than 0, or no window.
        case crashed
        /// Madeira itself went away while the game ran in the foreground (a crash, or iOS ending it for memory).
        case killed
        /// The player ended it, or it ended with exit code 0. Step 4 adds "played-slow" and "played-choppy".
        case played
    }

    struct Line: Codable, Equatable {
        var key: String
        var value: String
        /// One plain sentence for the card: what the line does.
        var plain: String
    }

    struct Rule: Codable, Equatable {
        /// Lower-case letters, digits and "-": the record's "auto-tune:<id>" tag.
        var id: String
        /// Which endings it is for: "crashed", "killed" (and later "played-slow", "played-choppy").
        var when: [String]
        /// Regular expressions; every one must match some line of the run's log.
        var all: [String]
        /// Regular expressions; none may match any line (for example: the fix is on already).
        var none: [String]?
        var lines: [Line]
        /// Only for builds from / until this one ("0.2.48"), both included.
        var fromBuild: String?
        var untilBuild: String?
        /// What Madeira saw, in plain words, for the card.
        var reason: String
        /// Our own logs that showed it (Send Log or Sentry ids, a games/ note).
        var evidence: [String]
    }

    // MARK: The rule table

    /// The rules this build ships. JSON, so a signed copy can later come the same way as the
    /// recommendations (RemoteRecs) and go through the same `rules(from:)`.
    static let builtInJSON = #"""
    [
      {
        "id": "avx-vex-illegal",
        "when": ["crashed"],
        "all": ["Unhandled illegal instruction",
                "\\[guest-code\\] .*\\): c[45] "],
        "none": ["MADEIRA_FEX_AVX=[12]"],
        "lines": [{"key": "env.MADEIRA_FEX_AVX", "value": "1",
                   "plain": "Turns on AVX and AVX2 for this game (the same as Game details > Compatibility > AVX and AVX2)."}],
        "reason": "The game stopped on an AVX instruction, and AVX is off for it.",
        "evidence": ["Sentry 7848583628 (Blue Prince, Nov 15): [guest-code] bytes c4 c1 68 c2 d8 0e (a VEX, so AVX, instruction) at the illegal instruction, AVX off",
                     "Not for Sentry 7853042697 (Minecraft Dungeons II, Nov 17): illegal instruction with AVX already on (MADEIRA_FEX_AVX=1 in its log) and no VEX bytes logged"]
      },
      {
        "id": "big-reserve-oversize",
        "when": ["crashed"],
        "all": ["\\[jumbo\\] kernel-pick reserve failed \\(0xc0000017\\)",
                "\\[oversize\\] ml1298 unhinted reserve .* would serve it in part"],
        "lines": [{"key": "oversize-reserve", "value": "1",
                   "plain": "Lets the game reserve more memory than fits, in part (Game details > Large memory reservations)."}],
        "reason": "The game asked for a very large block of memory and did not get it.",
        "evidence": ["Sentry 2G/2M/2N/2P (Plants vs Zombies RH, Test 8): [jumbo] kernel-pick reserve failed (0xc0000017); oversize-reserve = 1 fixed the crash in the player's next 2 runs",
                     "The same runs have [oversize] ml1298 '... does not fit the map and fails; oversize-reserve = 1 ... would serve it in part' (said only while it is off). games/subliminal-oversize-2026-11-17.md: with it on, the line is a different one (commit ... failed) and the rule does not fit"]
      }
    ]
    """#

    struct Loaded {
        var rules: [Rule]
        /// Why a rule was left out, one line each (logged by the app).
        var refused: [String]
    }

    static let endingNames = Set(Ending.allCases.map(\.rawValue))

    /// Decodes a rule table and keeps only rules that are whole: a usable id (once), known
    /// endings, patterns that compile, at least one config line, a reason and evidence.
    static func rules(from data: Data) -> Loaded {
        guard let decoded = try? JSONDecoder().decode([Rule].self, from: data) else {
            return Loaded(rules: [], refused: ["the rule table is not valid JSON"])
        }
        var kept: [Rule] = [], refused: [String] = [], seen = Set<String>()
        let idChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        for rule in decoded {
            let problem: String? = {
                if rule.id.isEmpty || rule.id.unicodeScalars.contains(where: { !idChars.contains($0) }) { return "bad id" }
                if seen.contains(rule.id) { return "id used twice" }
                if rule.when.isEmpty || rule.when.contains(where: { !endingNames.contains($0) }) { return "unknown ending" }
                if rule.all.isEmpty { return "no log line to look for" }
                if (rule.all + (rule.none ?? [])).contains(where: { (try? NSRegularExpression(pattern: $0)) == nil }) { return "a pattern does not compile" }
                if rule.lines.isEmpty { return "no config line" }
                for line in rule.lines {
                    let key = line.key.trimmingCharacters(in: .whitespaces)
                    if key.isEmpty || key.hasPrefix("#") || key.contains("=") || key != line.key { return "bad key \(line.key)" }
                    if (line.key + line.value).contains(where: { $0.isNewline }) || line.value.trimmingCharacters(in: .whitespaces).isEmpty { return "bad value for \(line.key)" }
                    if line.plain.isEmpty { return "no plain words for \(line.key)" }
                }
                if Set(rule.lines.map(\.key)).count != rule.lines.count { return "a key twice" }
                if rule.reason.isEmpty { return "no reason" }
                if rule.evidence.isEmpty || rule.evidence.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) { return "no evidence from our logs" }
                if let f = rule.fromBuild, build(f) == nil { return "fromBuild is not a build number" }
                if let u = rule.untilBuild, build(u) == nil { return "untilBuild is not a build number" }
                return nil
            }()
            if let problem { refused.append("\(rule.id.isEmpty ? "?" : rule.id): \(problem)") }
            else { kept.append(rule); seen.insert(rule.id) }
        }
        return Loaded(rules: kept, refused: refused)
    }

    static let builtIn: Loaded = rules(from: Data(builtInJSON.utf8))

    // MARK: Builds

    /// "0.2.48" (also inside "Madeira Nightly 0.2.48" or "v0.2.48 (1)") as numbers; nil without one.
    static func build(_ text: String) -> [Int]? {
        guard let r = text.range(of: #"\d+\.\d+\.\d+"#, options: .regularExpression) else { return nil }
        return text[r].split(separator: ".").compactMap { Int($0) }
    }

    /// Whether the rule is for this build. A rule with bounds is skipped when the build is unknown.
    static func fits(_ rule: Rule, build current: String) -> Bool {
        guard rule.fromBuild != nil || rule.untilBuild != nil else { return true }
        guard let now = build(current) else { return false }
        if let f = rule.fromBuild.flatMap(build), now.lexicographicallyPrecedes(f) { return false }
        if let u = rule.untilBuild.flatMap(build), u.lexicographicallyPrecedes(now) { return false }
        return true
    }

    // MARK: Scanning a run's log

    /// Which of the rules' patterns showed up in one run's log. Feed it line by line.
    struct Scan {
        private let patterns: [String]
        private let compiled: [NSRegularExpression]
        private(set) var hit: Set<String> = []
        private(set) var lines = 0

        init(rules: [Rule]) {
            var unique: [String] = []
            for rule in rules { for p in rule.all + (rule.none ?? []) where !unique.contains(p) { unique.append(p) } }
            var kept: [String] = [], compiled: [NSRegularExpression] = []
            for p in unique { if let rx = try? NSRegularExpression(pattern: p) { kept.append(p); compiled.append(rx) } }
            patterns = kept; self.compiled = compiled
        }

        mutating func feed(_ line: some StringProtocol) {
            lines += 1
            guard hit.count < patterns.count else { return }
            let s = String(line)
            let range = NSRange(s.startIndex..., in: s)
            for (i, rx) in compiled.enumerated() where !hit.contains(patterns[i]) {
                if rx.firstMatch(in: s, options: [], range: range) != nil { hit.insert(patterns[i]) }
            }
        }

        /// Every `all` line seen and no `none` line.
        func shows(_ rule: Rule) -> Bool {
            rule.all.allSatisfy(hit.contains) && !(rule.none ?? []).contains(where: hit.contains)
        }

        /// The rule's sign: every `all` line seen (whatever `none` says). The verdict asks this.
        func showsSign(_ rule: Rule) -> Bool { rule.all.allSatisfy(hit.contains) }
    }

    /// The most a scan reads: the last 4 MB of the run.
    static let scanCap = 4 << 20
    /// And, for a run longer than that, its first 256 KB.
    static let headCap = 256 << 10

    /// Reads the run's part of a log: from `offset` to the end, only the last `cap` bytes of it.
    /// A first line cut by the cap is skipped. An offset past the end (another file) reads the last `cap` bytes.
    static func scan(fileAt url: URL, from offset: UInt64, rules: [Rule], cap: Int = scanCap) -> Scan? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        // An offset past the end belongs to another file (the log rotated again): read nothing.
        guard offset <= end else { return nil }
        let runStart = offset
        var start = offset
        var cut = false
        if end - start > UInt64(cap) {
            start = end - UInt64(cap)
            // Cut inside a line, unless the byte before the cut ends one.
            if (try? handle.seek(toOffset: start - 1)) != nil, let before = try? handle.read(upToCount: 1) { cut = before.first != 0x0A }
            else { cut = true }
        }
        var scan = Scan(rules: rules)
        if start == end { return scan }   // nothing written since the run began
        // A long run: its first 256 KB too, where the start-up lines are (for example MADEIRA_FEX_AVX=1),
        // up to its last whole line and never past where the tail begins.
        if start > runStart, (try? handle.seek(toOffset: runStart)) != nil,
           let head = try? handle.read(upToCount: Int(min(UInt64(headCap), start - runStart))),
           let lastNL = head.lastIndex(of: 0x0A) {
            for raw in head[..<lastNL].split(separator: 0x0A) {
                var line = String(decoding: raw, as: UTF8.self)
                if line.hasSuffix("\r") { line.removeLast() }
                if !line.isEmpty { scan.feed(line) }
            }
        }
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.read(upToCount: Int(end - start)) else { return nil }
        var first = true
        for raw in data.split(separator: 0x0A, omittingEmptySubsequences: false) {
            defer { first = false }
            if first && cut { continue }
            var line = String(decoding: raw, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            if line.isEmpty { continue }
            scan.feed(line)
        }
        return scan
    }

    // MARK: Choosing a rule

    /// The first rule (table order) for this run that is still worth a try: the ending fits, the log
    /// shows it, it is for this build, it was not tried for this game before, and none of its keys is
    /// set already, by the player or by Get Help.
    static func pick(_ rules: [Rule], scan: Scan, ending: Ending, build: String,
                     config: [String: String], getHelpKeys: Set<String>, tried: Set<String>) -> Rule? {
        rules.first { rule in
            rule.when.contains(ending.rawValue) && !tried.contains(rule.id) && fits(rule, build: build)
                && scan.shows(rule)
                && !rule.lines.contains { config[$0.key] != nil || getHelpKeys.contains($0.key) }
        }
    }

    // MARK: Per-game state and the verdict

    /// Beside the game's config (<hash>.auto-tune.json).
    struct State: Codable, Equatable {
        /// Found after a run, waiting for the player's "Try it next start" (the card, step 3).
        var offer: String?
        var offerAt: Date?
        /// Applied and waiting to be judged by the next run(s).
        var trial: Trial?
        /// Rules this game tried that came out again: never offered again for it.
        var tried: [String] = []
        /// Rules that stayed.
        var kept: [String] = []

        struct Trial: Codable, Equatable {
            var rule: String
            var appliedAt: Date
            /// Runs since Apply too short to judge.
            var unclear: Int = 0

            init(rule: String, appliedAt: Date, unclear: Int = 0) { self.rule = rule; self.appliedAt = appliedAt; self.unclear = unclear }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                rule = try c.decode(String.self, forKey: .rule)
                appliedAt = try c.decode(Date.self, forKey: .appliedAt)
                unclear = try c.decodeIfPresent(Int.self, forKey: .unclear) ?? 0
            }
        }

        init() {}
        /// Missing fields (a file from an older or newer build) read as empty, so the tried list is never lost.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            offer = try? c.decodeIfPresent(String.self, forKey: .offer)
            offerAt = try? c.decodeIfPresent(Date.self, forKey: .offerAt)
            trial = try? c.decodeIfPresent(Trial.self, forKey: .trial)
            tried = (try? c.decodeIfPresent([String].self, forKey: .tried)) ?? []
            kept = (try? c.decodeIfPresent([String].self, forKey: .kept)) ?? []
        }
    }

    enum Verdict: Equatable {
        /// The game played and the sign is gone: the lines stay.
        case keep
        /// The lines come out again, and why.
        case takeOut(String)
        /// Not enough of a run to judge; ask the next one.
        case wait
    }

    /// A run that counts as "it played": a window showed and it ran this long.
    static let playedSeconds: Double = 60
    /// Short runs in a row before the trial ends without a clear result.
    static let unclearRuns = 3

    /// Judges a trial by the run that just ended (one that started after the Apply).
    static func verdict(_ trial: State.Trial, rule: Rule?, ending: Ending, seconds: Double, windowShown: Bool, scan: Scan?) -> Verdict {
        guard let rule else { return .takeOut("the rule is not in this build's table any more") }
        switch ending {
        case .crashed: return .takeOut("the game still stopped by itself")
        case .killed: return .takeOut("Madeira closed again while the game ran")
        case .played: break
        }
        if let scan, scan.showsSign(rule) { return .takeOut("the same log lines came back") }
        if windowShown && seconds >= playedSeconds { return .keep }
        return trial.unclear + 1 >= unclearRuns ? .takeOut("\(unclearRuns) short runs gave no clear result") : .wait
    }
}
