// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import SwiftUI
import UIKit

// The console look ("FLUX", stage 2): the rail and the stage on the Stores, Downloads and
// Settings tabs, and the game's art behind its own page. Stage 1 (FluxLook.swift) is the
// Library tab.
//
// On a wide page (an iPhone on its side, an iPad) each of those tabs is two panes: a rail of
// rows on the leading edge (the stores, the downloads, the Settings pages) and, beside it, the
// page the picked row stands for, which is the same page the row used to push. An upright
// iPhone keeps Apple's list that pushes a page (the rail has no room there). Apple's tab bar,
// the page stacks and the controller's highlight (PadHighlight.swift) are as before; a rail row
// and the page beside it are on one layer, so Left and Right walk between them and A on a row
// picks it (Apple rulebook 12.31: A activates).
//
// Off: Settings › Appearance › Console look, or env.MADEIRA_FLUX_LOOK = 0 (FluxLook.swift).
// Either way every page here is drawn exactly as it was.
// Design: /mnt/project-files/mockups/flux/ (screens-*.png; Cameron's go, Nov 19 2026).

extension FluxLook {
    /// A page this wide has room for a rail beside its stage.
    static let splitWidth: CGFloat = 640
    /// The width of a rail of rows (the Library's rail of covers is narrower: railWidth).
    static func rowRailWidth(_ page: CGFloat) -> CGFloat { min(320, max(220, page * 0.3)) }
}

// MARK: - Rail and stage

/// Two panes: a rail of rows that scrolls on its own, and the stage beside it.
struct FluxSplit<Rail: View, Stage: View>: View {
    let width: CGFloat
    @ViewBuilder var rail: () -> Rail
    @ViewBuilder var stage: () -> Stage
    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) { rail() }
                        .padding(12)
                }
                .padScrollFollow(reader)
            }
            .frame(width: FluxLook.rowRailWidth(width))
            .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
            Divider().ignoresSafeArea()
            stage().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A row of a rail: its picture, its name, a line under it and a value. The picked row has a
/// gray fill (Apple's sidebar selection); the controller's highlight is the ring, so there is
/// one highlight on the screen (Apple rulebook 13.25).
struct FluxRailRow<Leading: View>: View {
    let id: String
    let title: String
    var note: String = ""
    var value: String? = nil
    let picked: Bool
    let action: () -> Void
    @ViewBuilder var leading: () -> Leading
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                leading()
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(picked ? .semibold : .regular).foregroundStyle(Color.primary).lineLimit(2)
                    if !note.isEmpty { Text(note).font(.footnote).foregroundStyle(Color.secondary).lineLimit(2) }
                }
                Spacer(minLength: 4)
                if let value { Text(value).font(.footnote).monospacedDigit().foregroundStyle(Color.secondary).lineLimit(1) }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(picked ? Color(uiColor: .tertiarySystemFill) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(picked ? .isSelected : [])
        .padItem(id, cornerRadius: 12, inset: 0, press: action)
    }
}

/// A small title between a rail's groups.
struct FluxRailHeader: View {
    let title: String
    var body: some View {
        Text(title).font(.footnote.weight(.semibold)).foregroundStyle(Color.secondary)
            .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A page's own controller layer (B goes back a page), left out when the page is a stage beside
/// a rail: there it shares the tab's layer with the rail, so the highlight walks between them.
struct FluxPageLayer: ViewModifier {
    let name: String
    let embedded: Bool
    let back: () -> Void
    @ViewBuilder func body(content: Content) -> some View {
        if embedded { content } else { content.padLayer(name, back: back, page: true) }
    }
}

// MARK: - Stores

/// The Stores tab's first page: on a wide page with the console look on, a rail of the stores
/// and the picked store's own page beside it; else the list as it was (`classic`). The page's
/// title belongs to each, as in FluxLibraryRoot.
struct FluxStoresRoot<Classic: View>: View {
    let title: String
    /// When it changes the store's page scrolls back to the top (the open tab tapped again).
    var top = 0
    let open: (LibraryEntry) -> Void
    let add: () -> Void
    let desktop: () -> Void
    @ViewBuilder var classic: () -> Classic
    @AppStorage(FluxLook.key) private var consoleLook = true
    /// The store on the stage, kept between visits. Empty or a store that is off: the first one.
    @AppStorage("madeiraFluxStore") private var pickedRaw = ""
    // The rows' counts and "Signed in" follow the stores.
    @ObservedObject private var steam = SteamOwnedLibrary.shared
    @ObservedObject private var epic = EpicLibrary.shared
    @ObservedObject private var gog = GOGLibrary.shared
    @ObservedObject private var itch = ItchLibrary.shared
    @ObservedObject private var ea = EALibrary.shared
    @ObservedObject private var readyGames = NewLookGames.shared
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Off: the list, built as it always was (no wrapper around it).
        if FluxLook.allowed, consoleLook {
            GeometryReader { geo in
                // The largest text sizes keep the list: a rail's rows have no room for them.
                if geo.size.width >= FluxLook.splitWidth, !typeSize.isAccessibilitySize {
                    split(geo.size.width)
                        .navigationTitle(title)
                        .navigationBarTitleDisplayMode(.inline)
                } else {
                    classic()
                        .navigationTitle(title)
                        .navigationBarTitleDisplayMode(.large)
                }
            }
        } else {
            classic()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.large)
        }
    }

    private func split(_ width: CGFloat) -> some View {
        let stores = NewLookStore.shown
        let ready = readyGames.all
        let picked = stores.first(where: { $0.rawValue == pickedRaw }) ?? stores.first
        return FluxSplit(width: width) {
            ForEach(stores) { store in
                let installed = ready.filter { $0.id.hasPrefix(store.prefix) }.count
                FluxRailRow(id: "fx-st-" + store.rawValue, title: store.name,
                            note: NewLookStoresPage.line(store, installed: installed),
                            picked: store == picked, action: { pickedRaw = store.rawValue }) {
                    NewLookStoreIcon(store: store, size: 32)
                }
            }
            Divider().padding(.vertical, 6)
            // The Windows desktop opens its own page, so it is never the picked row.
            FluxRailRow(id: "fx-st-desktop", title: L("Windows Desktop"), note: L("Run installers and other Windows programs."),
                        picked: false, action: desktop) {
                NewLookBadge(symbol: "desktopcomputer", color: Color(uiColor: .systemGray))
            }
        } stage: {
            if let picked {
                NewLookScrollPage(refresh: { await SteamGamesSection.refresh() }, top: top) { inner in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(picked.name).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        NewLookStorePage(store: picked, width: inner, open: open, add: add, embedded: true)
                    }
                }
                // Each store's page is its own: its place and its popups do not carry over.
                .id(picked.rawValue)
            }
        }
    }
}

// MARK: - Settings

/// The Settings tab's first page: on a wide page with the console look on, a rail of the
/// Settings pages and the picked page beside it (first "Overview": JIT, free space, the
/// version); else the list as it was (`classic`).
struct FluxSettingsRoot<Classic: View>: View {
    let title: String
    var top = 0
    let enableJIT: () -> Void
    let startDock: (DockGame, Bool) -> Void
    @ViewBuilder var classic: () -> Classic
    @AppStorage(FluxLook.key) private var consoleLook = true
    /// The page on the stage; nil is Overview.
    @State private var picked: SettingsPages.Page?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            // Off: the list, built as it always was (no wrapper around it).
            if FluxLook.allowed, consoleLook {
                GeometryReader { geo in
                    // The largest text sizes keep the list: a rail's rows have no room for them.
                    if geo.size.width >= FluxLook.splitWidth, !typeSize.isAccessibilitySize {
                        split(geo.size.width)
                    } else {
                        classic()
                            .navigationTitle(title)
                            .navigationBarTitleDisplayMode(.large)
                    }
                }
            } else {
                classic()
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.large)
            }
        }
        // The open tab tapped again: back to Overview (the list's own first rows).
        .onChange(of: top) { _, _ in picked = nil }
    }

    private func split(_ width: CGFloat) -> some View {
        let shown = picked.flatMap { $0.shown ? $0 : nil }
        return FluxSplit(width: width) {
            FluxRailRow(id: "fx-set-overview", title: L("Overview"), picked: shown == nil, action: { picked = nil }) {
                NewLookBadge(symbol: "info.circle", color: Color(uiColor: .systemGray))
            }
            ForEach(Array(SettingsPages.groups.enumerated()), id: \.offset) { _, group in
                let pages = group.1.filter(\.shown)
                if !pages.isEmpty {
                    if let name = group.0 { FluxRailHeader(title: L(name)) }
                    ForEach(pages, id: \.self) { page in
                        FluxRailRow(id: "fx-set-" + page.key, title: L(page.title), picked: shown == page, action: { picked = page }) {
                            NewLookBadge(symbol: page.symbol, color: page.color)
                        }
                    }
                }
            }
        } stage: {
            if let shown {
                // The page sets its own name as the title.
                SettingsPageView(page: shown, startDock: startDock, embedded: true)
                    .id(shown)
            } else {
                NewLookSettingsList(top: top, enableJIT: enableJIT, open: { picked = $0 }, listsPages: false)
                    .navigationTitle(title)
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}

// MARK: - Game page

/// Behind a game's page: its art over the whole page, blurred, under a layer of the page's own
/// background colour, so every title and row reads on any art, light or dark (Apple rulebook
/// 9.68: text over art has its own background). A cover file is read once, off the main thread,
/// and again only when the cover changes (`revision`): the page itself redraws at every switch.
struct FluxGameBackdrop: View {
    let entry: LibraryEntry
    /// Goes up when the game's cover file is replaced (its name stays the same).
    var revision = 0
    @State private var cover: UIImage?
    var body: some View {
        let base = Color(uiColor: .systemGroupedBackground)
        ZStack {
            base
            GeometryReader { geo in
                Group {
                    if let cover {
                        Image(uiImage: cover).resizable().scaledToFill()
                    } else if entry.coverFile == nil, let id = entry.steamID ?? entry.steamAppID {
                        AsyncImage(url: SteamCatalog.hero(id)) { image in
                            image.resizable().scaledToFill()
                        } placeholder: { Color.clear }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height).clipped()
            }
            .blur(radius: 30)
            base.opacity(0.72)
        }
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: (entry.coverFile ?? "") + "#\(revision)") {
            guard let name = entry.coverFile else { cover = nil; return }
            let path = LibraryModel.documents
                .appendingPathComponent("madeira-art/" + URL(fileURLWithPath: name).lastPathComponent).path
            let image = await Task.detached(priority: .userInitiated) { UIImage(contentsOfFile: path) }.value
            if !Task.isCancelled { cover = image }
        }
    }
}

/// The game page's list on an upright iPhone: with the console look on, the art shows behind it.
struct FluxGameList: ViewModifier {
    let on: Bool
    let entry: LibraryEntry
    var revision = 0
    @ViewBuilder func body(content: Content) -> some View {
        if on {
            content.scrollContentBackground(.hidden)
                .background { FluxGameBackdrop(entry: entry, revision: revision) }
        } else {
            content
        }
    }
}
