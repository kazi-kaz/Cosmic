// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import UIKit
import Combine

// The console look ("FLUX", stage 1): the Library tab's first page as a rail and a stage.
// A rail of covers runs down the leading edge; the game picked in it fills the page behind
// its name, when it was played, Play and Game Page. Everything else is Madeira's own
// screens as before (NewLook.swift): Apple's tab bar, the same page stack, the same game
// page, and the controller's highlight (PadHighlight.swift), whose button meanings follow
// Apple rulebook 12.31 (A activates, B goes back, the shoulders change tabs, Menu opens
// the game's page).
//
// Off: Settings › Appearance › Console look, or env.MADEIRA_FLUX_LOOK = 0 (the setting's row
// goes too). Either way the Library is the grid again.
// Design: /mnt/project-files/mockups/flux/ (Stage B "Rail left"; Cameron's pick, Nov 19 2026).

enum FluxLook {
    /// Settings › Appearance › Console look. On when it was never set.
    static let key = "madeiraFluxConsoleLook"
    /// env.MADEIRA_FLUX_LOOK = 0 takes the console look and its setting away. Read at app start.
    static let allowed = MadeiraConfig.flag("MADEIRA_FLUX_LOOK")
    /// The rail's cover width: an iPhone, and a wide screen (an iPad).
    static func railWidth(wide: Bool) -> CGFloat { wide ? 92 : 62 }
    /// The game's wide art from Steam exists (LibraryArtwork's backdrop); another game shows
    /// its cover blurred behind (NewLookBanner's rule).
    static func hasHero(_ entry: LibraryEntry) -> Bool {
        entry.coverFile == nil && (entry.steamID ?? entry.steamAppID) != nil
    }
}

/// The Library tab's first page: the console look when it is on and there is a game to show,
/// else the page as it was (`classic`, which also draws "Loading your games…" and the empty
/// library). The page's title belongs to each: the grid keeps Apple's large title; the console
/// look keeps the title for Back buttons and VoiceOver but draws none over the game's art.
struct FluxLibraryRoot<Classic: View>: View {
    let title: String
    let enableJIT: () -> Void
    let open: (LibraryEntry) -> Void
    let play: (LibraryEntry) -> Void
    /// Pull to refresh, and the tab tapped again (back to the first game), as the grid has them.
    var refresh: (() async -> Void)? = nil
    var top = 0
    @ViewBuilder var classic: () -> Classic
    @AppStorage(FluxLook.key) private var consoleLook = true
    @ObservedObject private var ready = NewLookGames.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        if FluxLook.allowed, consoleLook, !ready.all.isEmpty {
            FluxHomePage(games: ready.all, enableJIT: enableJIT, open: open, play: play, refresh: refresh, top: top)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                // Nothing in the title's place: the word would sit on the art with no background.
                .toolbar { ToolbarItem(placement: .principal) { Color.clear.frame(width: 1, height: 1).accessibilityHidden(true) } }
                // The grid reads the stores when it shows and when Madeira comes back; so does this page.
                .onAppear { NewLookLibraryPage.load() }
                .onChange(of: scenePhase) { _, phase in if phase == .active { NewLookLibraryPage.load() } }
        } else {
            classic()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.large)
        }
    }
}

/// The rail and the stage.
struct FluxHomePage: View {
    let games: [LibraryReadyGame]
    let enableJIT: () -> Void
    let open: (LibraryEntry) -> Void
    let play: (LibraryEntry) -> Void
    var refresh: (() async -> Void)? = nil
    var top = 0
    /// The game on the stage: the one tapped in the rail, or under the controller's highlight.
    /// None yet: the game played last (the rail's first).
    @State private var pickedID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var picked: LibraryReadyGame? { games.first { $0.id == pickedID } ?? games.first }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= 700
            let side: CGFloat = wide ? 28 : 16
            if let game = picked {
                ZStack(alignment: .topLeading) {
                    stage(game)
                    HStack(alignment: .bottom, spacing: wide ? 28 : 16) {
                        rail(wide: wide)
                        info(game, wide: wide)
                            .padding(.bottom, wide ? 40 : 16)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, side).padding(.trailing, side)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .bottomLeading)
                    // JIT's state and its button, where the grid's title has them.
                    NewLookStatusPill(enableJIT: enableJIT)
                        .padding(.trailing, side).padding(.top, 8)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        // The highlight on a rail cover puts that game on the stage: when it moves, and when it
        // comes back after a touch (it returns to where it was, which may not be the staged game).
        .onReceive(PadHighlight.shared.$focus.combineLatest(PadHighlight.shared.$shown)
            .map { focus, shown in shown ? focus : nil }.removeDuplicates()) { focus in
            guard let focus, focus.hasPrefix("g-") else { return }
            let id = String(focus.dropFirst(2))
            if id != pickedID, games.contains(where: { $0.id == id }) { pick(id) }
        }
        // A game that left the library (uninstalled) leaves the stage too.
        .onChange(of: games.map(\.id)) { _, ids in
            if let pickedID, !ids.contains(pickedID) { self.pickedID = nil }
        }
    }

    /// A tap on a rail cover: the stage shows it, and the highlight (hidden by the touch) moves
    /// to it too, so the controller's next A plays the game that is on the stage.
    private func tapped(_ game: LibraryReadyGame) {
        pick(game.id)
        if PadHighlight.enabled { PadHighlight.shared.move(to: game.padID, scroll: false) }
    }

    private func pick(_ id: String) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { pickedID = id }
    }

    // MARK: Stage

    /// The picked game's art over the whole page, under the bars too, and a shade of the page's
    /// own background colour behind the words so they read on any art, light or dark (Apple
    /// rulebook 9.68: text over art has its own background).
    private func stage(_ game: LibraryReadyGame) -> some View {
        let background = Color(uiColor: .systemBackground)
        return ZStack {
            background
            LibraryArtwork(entry: game.entry, backdrop: true)
                .blur(radius: FluxLook.hasHero(game.entry) ? 0 : 30)
                .id(game.id)
                .transition(.opacity)
            LinearGradient(colors: [background.opacity(0.92), background.opacity(0.55), .clear],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(colors: [.clear, background.opacity(0.7)], startPoint: .center, endPoint: .bottom)
            // Behind the bar's buttons and the JIT pill.
            LinearGradient(colors: [background.opacity(0.6), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.22))
        }
        .clipped()
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    // MARK: Rail

    /// The covers, last played first, one under another. A tap puts a game on the stage; a tap
    /// on the game already there opens its page. With a controller the highlight walks the rail
    /// (the stage follows it), A plays, X plays, Menu opens the game's page. The stage's own two
    /// buttons are for touch: the highlight cannot reach them from most covers (it only moves
    /// to what overlaps the item it is on), and A and Menu on the cover already do both.
    private func rail(wide: Bool) -> some View {
        let width = FluxLook.railWidth(wide: wide)
        let ids = games.map(\.padID)
        let current = picked?.id
        return ScrollViewReader { reader in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: wide ? 14 : 10) {
                    ForEach(games, id: \.padID) { game in
                        let on = game.id == current
                        Button {
                            if on { open(game.entry) } else { tapped(game) }
                        } label: {
                            FluxRailCover(game: game, on: on)
                        }
                        .buttonStyle(LibraryCardButtonStyle())
                        .frame(width: width)
                        .contextMenu {
                            Button { play(game.entry) } label: { Label("Play", systemImage: "play.fill") }
                            Button { open(game.entry) } label: { Label("Game Page", systemImage: "info.circle") }
                        }
                        .padItem(game.padID, cornerRadius: 12, grid: "library",
                                 play: { play(game.entry) }, menu: { open(game.entry) }) { play(game.entry) }
                    }
                }
                // Room for the highlight's outline (4 pt outside a cover) and the picked cover's growth.
                .padding(.horizontal, 8).padding(.vertical, 12)
            }
            .modifier(FluxRefresh(refresh: refresh))
            .padScrollFollow(reader)
            // The Library tab tapped again: the first game, at the top.
            .onChange(of: top) { _, _ in
                pickedID = nil
                if let first = ids.first {
                    withAnimation(reduceMotion ? nil : .default) { reader.scrollTo(first, anchor: .top) }
                }
            }
        }
        .frame(width: width + 16)
        .onAppear { PadHighlight.shared.setGrid("library", ids: ids, columns: 1) }
        .onChange(of: ids) { _, new in PadHighlight.shared.setGrid("library", ids: new, columns: 1) }
        .onDisappear { PadHighlight.shared.removeGrid("library") }
    }

    // MARK: Name and buttons

    private func info(_ game: LibraryReadyGame, wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: wide ? 16 : 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(game.entry.title).font(wide ? .largeTitle.weight(.heavy) : .title.bold())
                    .lineLimit(2).minimumScaleFactor(0.6)
                Text(game.note).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: 12) {
                // The page's one prominent button (Apple rulebook 9.3).
                Button { play(game.entry) } label: {
                    Label("Play", systemImage: "play.fill").fontWeight(.semibold).padding(.horizontal, 8)
                }
                .modifier(LookPlayStyle(overArt: true))
                Button { open(game.entry) } label: { Text("Game Page").fontWeight(.semibold) }
                    .modifier(FluxSecondButtonStyle())
            }
        }
        .frame(maxWidth: wide ? 520 : 360, alignment: .leading)
        // The name and buttons do not scroll: very large text sizes stop at the first accessibility size.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
}

/// A cover in the rail. The one on the stage is a little larger; the rest sit back.
struct FluxRailCover: View {
    let game: LibraryReadyGame
    let on: Bool
    @Environment(\.libraryCardPressed) private var pressed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        LibraryArtwork(entry: game.entry).aspectRatio(2.0 / 3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(on ? 0.5 : 0.12), lineWidth: on ? 1.5 : 0.5))
            .shadow(color: .black.opacity(on ? 0.35 : 0.2), radius: on ? 10 : 5, y: 4)
            .opacity(on ? 1 : 0.88)
            .scaleEffect(pressed ? 0.95 : (on ? 1.06 : 1))
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75), value: on)
            .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7), value: pressed)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(game.entry.title)
            .accessibilityValue(game.note)
            .accessibilityHint(on ? L("Opens the game's page") : L("Shows this game"))
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// The stage's second button (Game Page): Apple's glass button on iOS 26, the bordered button
/// before that and with Reduce Transparency. Unlike the banner's (LookArtButtonStyle) it keeps
/// the page's own light or dark colours, because the stage's shade follows them.
struct FluxSecondButtonStyle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            content.buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.large)
        } else {
            content.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
        }
    }
}

/// Pull to refresh on the rail, when the page has something to read again.
private struct FluxRefresh: ViewModifier {
    let refresh: (() async -> Void)?
    @ViewBuilder func body(content: Content) -> some View {
        if let refresh { content.refreshable { await refresh() } } else { content }
    }
}
