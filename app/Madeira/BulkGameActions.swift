//
//  BulkGameActions.swift (bulk-actions, Nov 17 2026): Settings › Advanced › "All games".
//  Reset All Games to Recommended: the per-game Reset to Recommended
//  (GameRecommendations.reset) run over every library entry that HAS a recommendation.
//  Verify All Game Files: the stores' own "Repair installed files" (a repair compares
//  every file with the store build) run one game at a time, in list order.
//  Off switch: env.MADEIRA_BULK_ACTIONS = 0 in madeira.cfg hides the section.
//  Never writes madeira.cfg; a game's own config and switches are what reset replaces.
//
import SwiftUI

@MainActor final class BulkVerify: ObservableObject {
    static let shared = BulkVerify()
    static var enabled: Bool { MadeiraConfig.flag("MADEIRA_BULK_ACTIONS") }

    struct Item: Identifiable { let id: String; let title: String; let start: @MainActor () -> Void; let pause: @MainActor () -> Void; let state: @MainActor () -> St }
    enum St { case none, running, paused, failed }
    enum Outcome { case fine, failed, skipped }

    @Published private(set) var running = false
    @Published private(set) var index = 0
    @Published private(set) var total = 0
    @Published private(set) var current = ""
    @Published private(set) var done: [(title: String, result: Outcome)] = []
    @Published private(set) var upNext: [String] = []
    private var task: Task<Void, Never>?
    private var currentPause: (@MainActor () -> Void)?

    /// Every installed game Madeira downloaded itself, in a stable order (Steam, Epic, GOG, EA).
    static func items() -> [Item] {
        var out: [Item] = []
        let steam = SteamOwnedLibrary.shared
        for g in SteamGamesModel.shared.games where g.installed && SteamInstallPaths.isManaged(library: g.library) {
            out.append(Item(id: "steam-\(g.id)", title: g.name, start: { steam.repair(g.id) }, pause: { steam.pause(g.id) }, state: { switch steam.downloads[g.id]?.state { case nil: return .none; case .paused?: return .paused; case .failed?: return .failed; default: return .running } }))
        }
        let epic = EpicLibrary.shared
        for (k, g) in epic.installed.sorted(by: { $0.value.title < $1.value.title }) {
            out.append(Item(id: "epic-\(k)", title: g.title, start: { epic.repair(k) }, pause: { epic.pause(k) }, state: { switch epic.downloads[k]?.state { case nil: return .none; case .paused?: return .paused; case .failed?: return .failed; default: return .running } }))
        }
        let gog = GOGLibrary.shared
        for (k, g) in gog.installed.sorted(by: { $0.value.title < $1.value.title }) {
            out.append(Item(id: "gog-\(k)", title: g.title, start: { gog.repair(k) }, pause: { gog.pause(k) }, state: { switch gog.downloads[k]?.state { case nil: return .none; case .paused?: return .paused; case .failed?: return .failed; default: return .running } }))
        }
        let ea = EALibrary.shared
        for (k, g) in ea.installed.sorted(by: { $0.value.title < $1.value.title }) {
            out.append(Item(id: "ea-\(k)", title: g.title, start: { ea.repair(k) }, pause: { ea.pause(k) }, state: { switch ea.downloads[k]?.state { case nil: return .none; case .paused?: return .paused; case .failed?: return .failed; default: return .running } }))
        }
        return out
    }

    func start() {
        guard !running else { return }
        let items = Self.items()
        guard !items.isEmpty else { return }
        running = true; total = items.count; index = 0; done = []
        LogStore.shared.log("[bulk-verify] start games=\(items.count)")
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            for (i, item) in items.enumerated() {
                if Task.isCancelled { break }
                self.index = i + 1; self.current = item.title
                self.upNext = items.dropFirst(i + 1).prefix(3).map(\.title)
                // Already queued or downloading (its own install or update): left alone, not counted as checked.
                guard item.state() == .none else { self.done.append((item.title, .skipped)); LogStore.shared.log("[bulk-verify] \(item.title): already has a download (skipped)"); continue }
                self.currentPause = item.pause
                item.start()
                // A store that refuses (signed out, save sync busy) adds no download: skipped.
                guard item.state() != .none else { self.done.append((item.title, .skipped)); LogStore.shared.log("[bulk-verify] \(item.title): not started (skipped)"); continue }
                while item.state() == .running, !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000_000) }
                if Task.isCancelled { break }
                let end = item.state()
                self.done.append((item.title, end == .failed ? .failed : end == .paused ? .skipped : .fine))
                self.currentPause = nil
                // Paused part-way (a game started, or Madeira went to the background): stop here, do not pause the rest.
                if end == .paused { LogStore.shared.log("[bulk-verify] paused at \(item.title); run stopped"); break }
                LogStore.shared.log("[bulk-verify] \(item.title): finished \(i + 1)/\(items.count)")
            }
            self.running = false; self.current = ""; self.upNext = []
            LogStore.shared.log("[bulk-verify] end checked=\(self.done.count)/\(items.count) cancelled=\(Task.isCancelled ? 1 : 0)")
        }
    }

    /// Stop: the running game's repair is paused where it is (its files stay); the rest are not started.
    func stop() {
        task?.cancel()
        currentPause?()
    }
}

enum BulkReset {
    /// Library entries that have a recommendation; the rest are left alone.
    @MainActor static func eligible() -> [LibraryEntry] {
        LibraryModel.shared.entries.filter {
            guard $0.desktop != true, let rec = GameRecommendations.recommendation(for: $0) else { return false }
            return rec.id != GameRecommendations.standard.id && !SharedConfigs.isShared(rec)   // a list of the game's own only
        }
    }
    @MainActor @discardableResult static func run() -> Int {
        let list = eligible()
        for var entry in list {
            GameRecommendations.reset(&entry)
            LibraryModel.shared.save(entry)
        }
        LogStore.shared.log("[bulk-reset] reset=\(list.count) games to Recommended (global madeira.cfg untouched)")
        return list.count
    }
}

struct BulkGameActionsSection: View {
    @ObservedObject private var verify = BulkVerify.shared
    @State private var confirmReset = false
    @State private var confirmVerify = false
    @State private var showProgress = false
    @State private var resetCount = 0
    @State private var verifyCount = 0
    @State private var resetDone: Int?

    var body: some View {
        if BulkVerify.enabled {
            Section {
                Button("Reset All Games to Recommended…") { resetCount = BulkReset.eligible().count; resetDone = nil; confirmReset = true }
                    .disabled(verify.running)
                Button(verify.running ? "Verifying… (\(verify.index) of \(verify.total))" : "Verify All Game Files…") {
                    if verify.running { showProgress = true } else { verifyCount = BulkVerify.items().count; confirmVerify = true }
                }
            } header: { Text("All games") } footer: {
                Text(resetDone != nil ? "Reset \(resetDone ?? 0) games to Recommended." : "Reset puts every game that has its own Recommended list back to it; your own lines in those games are replaced. Verify checks every installed game one after another and re-downloads what is missing or changed, and updates a game to the latest build. It is slow.")
            }
            .confirmationDialog("Reset \(resetCount) games to Recommended?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset \(resetCount) Games", role: .destructive) { resetDone = BulkReset.run() }
            } message: {
                Text("Each of these games' own settings file and switches (AVX, NVIDIA, resolution) are replaced by the Recommended list. Lines you added yourself in those games are lost. Not touched: games with no Recommended list, your global settings, saves and downloads.")
            }
            .confirmationDialog("Verify \(verifyCount) games?", isPresented: $confirmVerify, titleVisibility: .visible) {
                Button("Start Verifying") { verify.start(); showProgress = true }
            } message: {
                Text("This is slow, from minutes to hours for big games. Keep Madeira open in front the whole time: iOS slows or stops downloads when you switch away. Keep the screen on and the device plugged in. Verify also updates games to the latest build and puts back files you changed. Games are checked one at a time, and you can stop at any point.")
            }
            .sheet(isPresented: $showProgress) { BulkVerifyProgress() }
        }
    }
}

struct BulkVerifyProgress: View {
    @ObservedObject private var verify = BulkVerify.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if verify.running {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Game \(verify.index) of \(verify.total)").font(.headline)
                            Text(verify.current)
                            ProgressView(value: Double(max(verify.index - 1, 0)), total: Double(max(verify.total, 1)))
                        }
                    } footer: { Text("Keep Madeira open and in front.") }
                }
                Section {
                    ForEach(Array(verify.done.enumerated()), id: \.offset) { _, d in
                        Label(d.title + (d.result == .skipped ? " · not started" : d.result == .failed ? " · could not finish" : " · checked"),
                              systemImage: d.result == .fine ? "checkmark.circle" : d.result == .failed ? "exclamationmark.triangle" : "minus.circle")
                    }
                    if !verify.upNext.isEmpty { Text("Next: " + verify.upNext.joined(separator: ", ")).foregroundStyle(.secondary) }
                }
                if verify.running { Button("Stop", role: .destructive) { verify.stop() } }
            }
            .navigationTitle("Verify All")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
