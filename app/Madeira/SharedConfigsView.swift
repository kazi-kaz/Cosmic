// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md
//
//  madeira-shared-configs: the library's "Madeira used shared settings for <game>"
//  question, Keep or Undo, after Madeira wrote settings other players said work
//  into a game's own config by itself (SharedConfigs.swift). It waits until no
//  game, error or Get Help question is showing, like Get Help's offers.

import SwiftUI

struct SharedConfigsNotice: ViewModifier {
    @ObservedObject private var model = LibraryModel.shared
    @ObservedObject private var help = GetHelpCenter.shared
    @State private var asking: SharedConfigs.Applied?

    func body(content: Content) -> some View {
        content
            // On a view of its own, so it does not take the place of the library's other alerts.
            .background {
                Color.clear
                    .alert(String(format: L("Madeira used shared settings for %@"), asking?.title ?? ""),
                           isPresented: Binding(get: { asking != nil && model.error == nil && model.current == nil && help.open == nil
                                                    && help.offer == nil && help.fixAsk == nil && help.worksAsk == nil },
                                                set: { _ in })) {   // the buttons answer
                        Button("Keep", role: .cancel) { finish(undo: false) }
                        Button("Undo") { finish(undo: true) }
                    } message: {
                        Text("Other players said these settings make this game work, and Madeira approved them. They are in this game's config only. Undo puts back Madeira's standard settings.")
                    }
            }
            .onAppear(perform: next)
            .onReceive(NotificationCenter.default.publisher(for: SharedConfigs.appliedNotification).receive(on: RunLoop.main)) { _ in next() }
    }

    private func next() {
        if asking == nil { asking = SharedConfigs.nextPending }
    }

    private func finish(undo: Bool) {
        guard let a = asking else { return }
        asking = nil
        SharedConfigs.answered(a)
        if undo { GameRecommendations.undoShared(windowsPath: a.windowsPath, title: a.title) }
        else { LogStore.shared.log("[shared-configs] \(a.title): keep") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { next() }
    }
}
