//
//  AutoTune.swift
//  Madeira
//
//  (auto-tune) After a game crashes, or Madeira closed while it ran, read that run's log and
//  find one rule (AutoTuneCore) worth a try. Step 2 only gets it ready: the offer is kept for
//  the game and logged, nothing is changed. The card that asks the player ("Try it next
//  start" / "Not now") is step 3 and calls `tryNextStart`. A fix that was tried is judged by
//  the next run: it stays only if the game played and its log lines are gone, else its lines
//  come out again through Get Help's shared Undo.
//
//  Off by default: env.MADEIRA_AUTO_TUNE = 1 turns it on. Needs the log trail (LogTrail, on by
//  default). Every change goes through GetHelp.apply / GetHelp.undoAutoTune (one writer, one record).
//

import Foundation

enum AutoTune {
    static let enabled = MadeiraConfig.flag("MADEIRA_AUTO_TUNE", fallback: false)

    private static let queue = DispatchQueue(label: "madeira.auto-tune", qos: .utility)
    /// "<offset> <start time>" in one value, so a reader never pairs one run's offset with another's time.
    private static let markKey = "autoTune.runMark"
    private static func mark() -> (offset: UInt64, at: Double)? {
        guard let parts = UserDefaults.standard.string(forKey: markKey)?.split(separator: " "), parts.count == 2,
              let offset = UInt64(parts[0]), let at = Double(parts[1]), at > 0 else { return nil }
        return (offset, at)
    }

    static var logURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("madeira-log.txt")
    }
    static var previousLogURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("madeira-log.prev.txt")
    }

    /// Beside the game's config: <hash>.auto-tune.json.
    static func stateURL(_ windowsPath: String) -> URL? {
        GameProfile(windowsPath: windowsPath).url?.deletingPathExtension().appendingPathExtension("auto-tune.json")
    }
    static func state(_ windowsPath: String) -> AutoTuneCore.State {
        guard let url = stateURL(windowsPath), let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode(AutoTuneCore.State.self, from: data) else { return AutoTuneCore.State() }
        return s
    }
    private static func save(_ s: AutoTuneCore.State, _ windowsPath: String) {
        guard let url = stateURL(windowsPath) else { return }
        if s == AutoTuneCore.State() { try? FileManager.default.removeItem(at: url); return }
        if let data = try? JSONEncoder().encode(s) { try? data.write(to: url, options: .atomic) }
    }

    /// The table, once; refused rules are logged.
    static let rules: [AutoTuneCore.Rule] = {
        let loaded = AutoTuneCore.builtIn
        for why in loaded.refused { LogStore.shared.log("[auto-tune] rule left out: \(why)", level: .error) }
        return loaded.rules
    }()

    // MARK: Hooks (LogTrail)

    /// Play (LogTrail.play), or a session that starts without Play (LogTrail.began, a Madeira Dock
    /// start): where this run starts in madeira-log.txt, and when. LogTrail's open-run marker carries
    /// both too (`markerLines`), so a run Madeira did not live through is found at the next start.
    static func play() {
        guard enabled, let url = logURL else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        UserDefaults.standard.set("\(size) \(Date().timeIntervalSince1970)", forKey: markKey)
    }

    /// For madeira-trail-open.txt (LogTrail.Session.saveMarker): this run's log position.
    static func markerLines() -> [String] {
        guard enabled, let m = mark() else { return [] }
        return ["auto-tune-offset=\(m.offset)", "auto-tune-at=\(m.at)"]
    }

    /// This run's start in the log, only when play() marked this run (within 10 s of its start).
    private static func offset(for started: Date) -> UInt64? {
        guard let m = mark(), abs(started.timeIntervalSince1970 - m.at) < 10 else { return nil }
        return m.offset
    }

    /// LogTrail.finished: the run is over and its [game-end] line is written.
    static func ended(title: String, windowsPath: String?, started: Date, seconds: Double, windowShown: Bool, ending: AutoTuneCore.Ending) {
        guard enabled, let windowsPath, !windowsPath.isEmpty, let url = logURL else { return }
        LogStore.shared.flushRepeats()
        guard let offset = offset(for: started) else {
            LogStore.shared.log("[auto-tune] \(title): this run's place in the log is not known; not read")
            return
        }
        // Now, before GetHelpCenter.gameFinished's main-queue block can end Get Help's own check.
        let busy = GetHelp.fixChecks[windowsPath] != nil
        judge(title: title, windowsPath: windowsPath, started: started, seconds: seconds, windowShown: windowShown,
              ending: ending, log: url, offset: offset, getHelpBusy: busy)
    }

    /// LogTrail.reportLastRun: Madeira closed while the game ran in the foreground; its log is now madeira-log.prev.txt.
    /// `fields`: the open-run marker's lines; its auto-tune-offset / auto-tune-at say where that run starts.
    static func lastRunKilled(title: String, windowsPath: String?, fields: [String: String]) {
        guard enabled, let windowsPath, !windowsPath.isEmpty, let url = previousLogURL else { return }
        guard let offset = fields["auto-tune-offset"].flatMap(UInt64.init), let at = fields["auto-tune-at"].flatMap(Double.init), at > 0 else {
            LogStore.shared.log("[auto-tune] \(title): the last run's place in the log is not known; not read")
            return
        }
        judge(title: title, windowsPath: windowsPath, started: Date(timeIntervalSince1970: at), seconds: 0, windowShown: false,
              ending: .killed, log: url, offset: offset, getHelpBusy: GetHelp.fixChecks[windowsPath] != nil)
    }

    private static func judge(title: String, windowsPath: String, started: Date, seconds: Double, windowShown: Bool,
                              ending: AutoTuneCore.Ending, log url: URL, offset: UInt64, getHelpBusy busy: Bool) {
        let rules = Self.rules
        queue.async {
            let scan = AutoTuneCore.scan(fileAt: url, from: offset, rules: rules)
            DispatchQueue.main.async {
                var s = state(windowsPath)
                let record = GetHelp.record(windowsPath)
                // 0. The player took the lines out (Undo, Reset, by hand in the record): nothing to judge.
                if let trial = s.trial, !(record.map { GetHelpCore.blocks(of: $0).contains { $0.source == GetHelpCore.Source.autoTune(trial.rule).tag } } ?? false) {
                    s.tried.append(trial.rule); s.trial = nil
                    LogStore.shared.log("[auto-tune] \(trial.rule) for \(title): its lines were taken out already; not judged")
                }
                // 1. A fix that was tried: the run after its Apply judges it.
                if let trial = s.trial, started > trial.appliedAt {
                    let rule = rules.first { $0.id == trial.rule }
                    switch AutoTuneCore.verdict(trial, rule: rule, ending: ending, seconds: seconds, windowShown: windowShown, scan: scan) {
                    case .keep:
                        s.kept.append(trial.rule); s.trial = nil
                        LogStore.shared.log("[auto-tune] kept \(trial.rule) for \(title): it played \(Int(seconds)) s and the log lines are gone")
                    case .takeOut(let why):
                        GetHelp.undoAutoTune(windowsPath: windowsPath, title: title, rule: trial.rule)
                        s.tried.append(trial.rule); s.trial = nil
                        LogStore.shared.log("[auto-tune] took \(trial.rule) out for \(title): \(why)")
                    case .wait:
                        s.trial?.unclear += 1
                        LogStore.shared.log("[auto-tune] \(trial.rule) for \(title): run too short to judge (\(Int(seconds)) s)")
                    }
                }
                // 2. A new offer, after a crash, when nothing is being tried and Get Help is not checking a fix of its own.
                // An older offer does not outlive a good run or Get Help's own check (the card must not show it then).
                if s.offer != nil, ending == .played || busy { s.offer = nil; s.offerAt = nil }
                if s.trial == nil, ending != .played, let scan {
                    let helpKeys = record.map { r in
                        GetHelpCore.keys(GetHelpCore.blocks(of: r).filter { !GetHelpCore.Source(tag: $0.source).isAutoTune }.flatMap(\.added))
                    } ?? []
                    let config = GameProfile(windowsPath: windowsPath).values
                    if busy {
                        LogStore.shared.log("[auto-tune] \(title): Get Help is checking a fix of its own; no offer")
                    } else if let rule = AutoTuneCore.pick(rules, scan: scan, ending: ending, build: BuildStamp.text, config: config,
                                                           getHelpKeys: helpKeys, tried: Set(s.tried)) {
                        s.offer = rule.id; s.offerAt = Date()
                        LogStore.shared.log("[auto-tune] offer ready for \(title): \(rule.id) (\(rule.reason)) would add "
                                            + rule.lines.map { "\($0.key) = \($0.value)" }.joined(separator: "; "))
                    } else {
                        if s.offer != nil { s.offer = nil; s.offerAt = nil }
                        if rules.contains(where: { s.tried.contains($0.id) && $0.when.contains(ending.rawValue) && scan.showsSign($0) }) {
                            LogStore.shared.log("[auto-tune] \(title): the rules for this are used up; Get Help is next")
                        } else {
                            LogStore.shared.log("[auto-tune] \(title): no rule fits this run (\(scan.lines) log lines read)")
                        }
                    }
                }
                save(s, windowsPath)
            }
        }
    }

    // MARK: The card's buttons (step 3)

    /// "Try it next start": adds the offered rule's lines through Get Help's writer.
    @discardableResult
    static func tryNextStart(windowsPath: String, title: String) -> Bool {
        var s = state(windowsPath)
        guard enabled, s.trial == nil, let id = s.offer, let rule = rules.first(where: { $0.id == id }) else { return false }
        let lines = rule.lines.map { GetHelpCore.ConfigLine(key: $0.key, value: $0.value, plain: $0.plain) }
        s.offer = nil; s.offerAt = nil
        switch GetHelp.apply(lines, windowsPath: windowsPath, title: title, source: .autoTune(rule.id)) {
        case .added:
            s.trial = .init(rule: rule.id, appliedAt: Date())
            LogStore.shared.log("[auto-tune] trying \(rule.id) for \(title) at the next start")
        case .already, .failed:
            s.tried.append(rule.id)
            LogStore.shared.log("[auto-tune] \(rule.id) for \(title): nothing was added", level: .error)
        }
        save(s, windowsPath)
        return s.trial != nil
    }

    /// "Not now": the offer goes; the rule may be offered again after another crash like it.
    static func notNow(windowsPath: String) {
        var s = state(windowsPath)
        guard s.offer != nil else { return }
        s.offer = nil; s.offerAt = nil
        save(s, windowsPath)
        LogStore.shared.log("[auto-tune] offer: not now")
    }
}
