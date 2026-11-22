// SPDX-License-Identifier: GPL-3.0-or-later
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import UIKit
import SwiftUI
import GameController
import os

// madeira-log-trail: what the player did and what Madeira did, in a few hundred short lines.
//
// A session log is mostly Wine, FEX and DXMT, and it never said which button was pressed,
// what had the focus, which screen was open or how long each start step took (Cameron, Nov 7:
// the Wave 10 game card bug left only "[menu-pad] open ready:steam:632360" behind). These
// lines fill that in. Each kind has a cap per app run, so a long session stays small:
//
//   [pad]        a controller press while Madeira's menus own the pad, and where the ring went
//   [focus]      iOS's own focus moving (a controller or keyboard can drive it beside Madeira's)
//   [screen]     a named page or sheet opening or closing, and any alert or sheet on top
//   [tap]        a tap in Madeira's menus: what was under the finger, and on which screen
//   [app]        Madeira going to the background, coming back, and iOS memory warnings
//   [step]       each start and quit step of a game, in seconds since Play
//   [game-start] the state a game started in: config, memory, JIT, controller
//   [game-end]   how it ended: the reason, the exit code, memory, the steps in one line
//   [last-run]   at the next start: the previous run ended while a game was running
//
// An [ERR] line that Madeira writes itself also says what was going on ("during: ...").
// env.MADEIRA_LOG_TRAIL = 0 turns all of this off.
enum LogTrail {
    static let enabled = MadeiraConfig.flag("MADEIRA_LOG_TRAIL")

    enum Kind: String { case pad, focus, screen, tap, app, step, tapDiag = "tap-diag" }
    /// A tap that hit a bare hosting view: what is under the finger (env.MADEIRA_TAP_DIAG = 0 turns it off).
    static let tapDiag = MadeiraConfig.flag("MADEIRA_TAP_DIAG")
    /// Lines per kind per app run. A run of a few games stays at a few hundred lines.
    private static let caps: [Kind: Int] = [.pad: 250, .focus: 120, .screen: 150, .tap: 120, .app: 60, .step: 160, .tapDiag: 40]
    private static let lock = NSLock()
    private static var used: [Kind: Int] = [:]
    private static var capped = Set<Kind>()

    /// Writes one trail line, unless its kind has used up its lines for this run.
    static func write(_ kind: Kind, _ message: String) {
        guard enabled else { return }
        lock.lock()
        let count = used[kind, default: 0], cap = caps[kind] ?? 100
        if count >= cap {
            let first = capped.insert(kind).inserted
            lock.unlock()
            if first { LogStore.shared.log("[log-trail] no more [\(kind.rawValue)] lines this run (\(cap) written; the log stays small)") }
            return
        }
        used[kind] = count + 1
        lock.unlock()
        LogStore.shared.log(message)
    }

    // MARK: Start

    private static var installed = false
    /// From the app's first appearance (MadeiraApp), on the main thread.
    @MainActor static func install() {
        guard enabled, !installed else { return }
        installed = true
        let device = UIDevice.current
        LogRuns.device = "\(device.model) \(device.systemName) \(device.systemVersion)"
        LogRuns.writeHeader()
        reportLastRun()
        let center = NotificationCenter.default
        center.addObserver(forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main) { note in
            let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext
            MainActor.assumeIsolated { focusMoved(context) }
        }
        center.addObserver(forName: UIFocusSystem.movementDidFailNotification, object: nil, queue: .main) { note in
            let context = note.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey] as? UIFocusUpdateContext
            let heading = context.map { headingName($0.focusHeading) } ?? "?"
            MainActor.assumeIsolated {
                write(.focus, "[focus] system focus could not move \(heading) from \(describe(context?.previouslyFocusedItem)) on \(screen)")
            }
        }
        let lifecycle: [(Notification.Name, String)] = [
            (UIApplication.willResignActiveNotification, "inactive (Control Center, a notification, the app switcher or a lock)"),
            (UIApplication.didEnterBackgroundNotification, "in the background"),
            (UIApplication.willEnterForegroundNotification, "back in the foreground"),
            (UIApplication.didBecomeActiveNotification, "active"),
            (UIApplication.willTerminateNotification, "closing (iOS asked it to end)"),
        ]
        for (name, words) in lifecycle {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { appState(name, words) }
            }
        }
        center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            lock.lock(); warnings += 1; let n = warnings; lock.unlock()
            write(.app, "[app] iOS memory warning #\(n): \(Memory.footprintMB) MB in use, \(Memory.availableMB) MB left before iOS ends Madeira" + during())
        }
        center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { note in
            let pad = note.object as? GCController
            write(.pad, "[pad] controller connected: \(pad?.vendorName ?? "?") (\(pad?.productCategory ?? "?"))")
        }
        center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { note in
            let pad = note.object as? GCController
            write(.pad, "[pad] controller disconnected: \(pad?.vendorName ?? "?")" + during())
        }
        watchWindow()
        // What is on top (alerts, sheets): looked at twice a second, logged when it changes.
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { checkOnTop() } }
        RunLoop.main.add(timer, forMode: .common)
        LogStore.shared.log("[log-trail] on: [pad] [focus] [screen] [tap] [app] [step] [game-start] [game-end] lines (env.MADEIRA_LOG_TRAIL = 0 turns them off)")
    }

    @MainActor private static var keyWindow: UIWindow? {
        UIApplication.shared.phoneScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
    }

    @MainActor private static var watchedWindow: UIWindow?
    /// The tap watch goes on the key window; tried again when Madeira becomes active.
    @MainActor private static func watchWindow() {
        guard let window = keyWindow, window !== watchedWindow else { return }
        watchedWindow = window
        window.addGestureRecognizer(LogTrailTapWatch(target: nil, action: nil))
    }

    @MainActor private static func appState(_ name: Notification.Name, _ words: String) {
        if name == UIApplication.didBecomeActiveNotification { watchWindow() }
        if name == UIApplication.didEnterBackgroundNotification { session.note(background: Date()) }
        if name == UIApplication.willEnterForegroundNotification { session.note(background: nil) }
        write(.app, "[app] Madeira is \(words)" + (session.title.map { " (\($0) running)" } ?? ""))
    }

    // MARK: Focus

    @MainActor private static func focusMoved(_ context: UIFocusUpdateContext?) {
        guard let context else { return }
        write(.focus, "[focus] system focus -> \(describe(context.nextFocusedItem)) (from \(describe(context.previouslyFocusedItem)), "
              + "\(headingName(context.focusHeading))) on \(screen)")
    }

    static func headingName(_ heading: UIFocusHeading) -> String {
        var parts: [String] = []
        if heading.contains(.up) { parts.append("up") }
        if heading.contains(.down) { parts.append("down") }
        if heading.contains(.left) { parts.append("left") }
        if heading.contains(.right) { parts.append("right") }
        if heading.contains(.next) { parts.append("next") }
        if heading.contains(.previous) { parts.append("previous") }
        return parts.isEmpty ? "no direction" : parts.joined(separator: "+")
    }

    /// "UIButton \"Play\" at 120,400 70x44 in PresentationHostingController": the item's type, the
    /// nearest label, where it is in the window and the page that holds it.
    @MainActor static func describe(_ item: UIFocusItem?) -> String {
        guard let item else { return "nothing" }
        var text = shortType(item)
        let view = item as? UIView
        if let label = label(of: item as? NSObject, view: view) { text += " \"\(label)\"" }
        if let view, let window = view.window {
            let r = view.convert(view.bounds, to: window)
            text += " at \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))"
        } else {
            let r = item.frame
            text += " frame \(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))"
        }
        if let page = owner(of: view) { text += " in \(page)" }
        return text
    }

    /// The first accessibility label on the item or the views around it (UIKit's, at no cost:
    /// SwiftUI's own accessibility tree is never asked for, so it is never built).
    @MainActor static func label(of object: NSObject?, view: UIView?) -> String? {
        if let own = object?.accessibilityLabel, !own.isEmpty { return clip(own) }
        var next = view?.superview, hops = 0
        while let current = next, hops < 6 {
            if let found = current.accessibilityLabel, !found.isEmpty { return clip(found) }
            next = current.superview; hops += 1
        }
        return nil
    }

    /// The view controller a view is in, by its short type name.
    @MainActor static func owner(of view: UIView?) -> String? {
        var responder: UIResponder? = view
        while let current = responder {
            if let controller = current as? UIViewController { return controllerName(controller) }
            responder = current.next
        }
        return nil
    }

    static func shortType(_ value: Any) -> String {
        let name = String(describing: type(of: value))
        return String(name.prefix { $0 != "<" })
    }

    static func clip(_ text: String, _ length: Int = 48) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > length ? String(flat.prefix(length)) + "…" : flat
    }

    // MARK: Screens

    /// Named pages and sheets that are open (logScreen), the newest last.
    @MainActor private static var screens: [String] = []
    /// The page in front: the newest named one, else the library.
    @MainActor static var screen: String { screens.last ?? (session.title != nil ? "the game" : "the library") }

    @MainActor static func opened(_ name: String) {
        screens.append(name)
        write(.screen, "[screen] open \(name)")
    }
    @MainActor static func closed(_ name: String) {
        if let index = screens.lastIndex(of: name) { screens.remove(at: index) }
        write(.screen, "[screen] close \(name) (now \(screen))")
    }

    @MainActor private static var lastOnTop = ""
    /// Alerts and sheets over the app's root, as one line when the set changes.
    @MainActor private static func checkOnTop() {
        guard let root = keyWindow?.rootViewController else { return }
        var chain: [String] = []
        var next = root.presentedViewController
        while let controller = next, chain.count < 6 {
            chain.append(controllerName(controller))
            next = controller.presentedViewController
        }
        let text = chain.joined(separator: " > ")
        guard text != lastOnTop else { return }
        let was = lastOnTop
        lastOnTop = text
        if text.isEmpty { write(.screen, "[screen] on top: nothing now (was \(was))") }
        else { write(.screen, "[screen] on top: \(text)") }
    }

    /// A view controller in words: an alert with its title, message and buttons; a SwiftUI sheet
    /// as "sheet"; anything else by its type.
    @MainActor static func controllerName(_ controller: UIViewController) -> String {
        if let alert = controller as? UIAlertController {
            var text = alert.preferredStyle == .actionSheet ? "menu" : "alert"
            if let title = alert.title, !title.isEmpty { text += " \"\(clip(title, 60))\"" }
            if let message = alert.message, !message.isEmpty { text += " \"\(clip(message, 90))\"" }
            let buttons = alert.actions.compactMap(\.title)
            if !buttons.isEmpty { text += " [\(buttons.joined(separator: " | "))]" }
            return text
        }
        let type = shortType(controller)
        if type.contains("HostingController") { return type.hasPrefix("Presentation") ? "sheet" : "page" }
        if controller is UIActivityViewController { return "share sheet" }
        if controller is UIDocumentPickerViewController { return "file picker" }
        return type
    }

    // MARK: Taps

    @MainActor static func tapped(at point: CGPoint, in window: UIWindow) {
        guard session.title == nil || session.inMenu else { return }   // a game's own touches are not menus
        let hit = window.hitTest(point, with: nil)
        var text = "[tap]"
        if let label = label(of: hit, view: hit) { text += " \"\(label)\"" }
        if let hit { text += " " + shortType(hit) }
        let size = window.bounds.size
        text += " at \(Int(point.x)),\(Int(point.y))"
        if size.width > 0, size.height > 0 {
            text += " (\(Int(point.x / size.width * 100))%,\(Int(point.y / size.height * 100))%)"
        }
        text += " on \(screen)"
        if !lastOnTop.isEmpty { text += ", over \(lastOnTop)" }
        write(.tap, text)
        // A tap that landed on a bare hosting view: say what the window looks like and which views
        // sit under the finger (frames in window points), so a dead edge can be told apart from a
        // control drawn where UIKit does not hit-test it. SwiftUI controls are not UIViews: the list
        // shows UIKit and platform containers.
        if tapDiag, let hit, shortType(hit).hasSuffix("HostingView") {
            let traits = window.traitCollection
            var under: [String] = []
            var visited = 0
            func walk(_ view: UIView, depth: Int) {
                guard depth < 14, visited < 600, !view.isHidden, view.alpha > 0.01 else { return }
                visited += 1
                if view !== window {
                    let frame = view.convert(view.bounds, to: window)
                    if frame.contains(point), view.isUserInteractionEnabled,
                       frame.width < size.width - 1 || frame.height < size.height - 1 {
                        under.append("\(shortType(view)) \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))")
                    }
                }
                for sub in view.subviews { walk(sub, depth: depth + 1) }
            }
            walk(window, depth: 0)
            let shown = under.suffix(8).joined(separator: " | ")
            let more = under.count > 8 ? " (+\(under.count - 8) outer)" : ""
            let insets = window.safeAreaInsets
            let root = window.rootViewController.map { shortType($0) } ?? "-"
            let sizes = "h-size=\(traits.horizontalSizeClass.rawValue) v-size=\(traits.verticalSizeClass.rawValue) idiom=\(traits.userInterfaceIdiom.rawValue)"
            let edges = "dir=\(window.effectiveUserInterfaceLayoutDirection.rawValue) insets=\(Int(insets.top)),\(Int(insets.left)),\(Int(insets.bottom)),\(Int(insets.right))"
            write(.tapDiag, "[tap-diag] window \(Int(size.width))x\(Int(size.height)) \(sizes) \(edges) rootVC=\(root) under: \(shown.isEmpty ? "-" : shown)\(more)")
        }
    }

    // MARK: Controller

    /// The ring's place now, for a press's before and after.
    @MainActor static var ring: String {
        guard PadHighlight.enabled else { return "off" }
        let pad = PadHighlight.shared
        guard let focus = pad.focus else { return pad.shown ? "on nothing" : "hidden" }
        return (pad.shown ? focus : "hidden (was \(focus))") + (pad.layerName == PadLayer.root ? "" : " in \(pad.layerName)")
    }

    static let buttonNames: [String: String] = [
        "up": "up", "down": "down", "left": "left", "right": "right", "accept": "A", "back": "B", "add": "Y", "play": "X",
        "menu": "Menu", "search": "View", "previous": "L1", "next": "R1", "pageUp": "L2", "pageDown": "R2",
    ]

    /// A press that became a command (LibraryController): logged after the command ran, with the
    /// ring before and after it.
    @MainActor static func pressed(_ command: String, ownsMenus: Bool, before: String) {
        guard enabled else { return }
        let button = ownsMenus ? (buttonNames[command] ?? command) : "View+Menu"
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let after = ring
                let moved = after == before ? "ring \(before)" : "ring \(before) -> \(after)"
                let sheets = PadHighlight.shared.sheets
                write(.pad, "[pad] \(button) (\(command)): \(moved) on \(screen)" + (sheets > 0 ? ", \(sheets) sheet(s) open" : ""))
            }
        }
    }

    /// Buttons that are no command in the menus (X, the stick clicks), so a press that did
    /// nothing still shows.
    static func pressedUnused(_ pressed: UInt32) {
        let names: [(UInt32, String)] = [(0x4000, "X"), (0x40, "L3"), (0x80, "R3")]
        for (mask, name) in names where pressed & mask != 0 {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { write(.pad, "[pad] \(name): no menu command on \(screen)") }
            }
        }
    }

    // MARK: A game's start and end

    /// One game from Play to Wine's end. The steps are also kept in a small file, so a run
    /// that ends in a crash still has them at the next start ([last-run]).
    final class Session {
        var title: String?
        /// (get-help) The game's Windows path: its own config, for Get Help's offer.
        var windowsPath: String?
        var started = Date()
        var steps: [(String, Double)] = []
        var reason: String?
        var exitDetail: String?
        var lastError: String?
        var crash: String?
        var dockResult: String?
        var inMenu = false
        var backAt: Date?
        var background: Date?
        var warningsAtStart = 0
        /// The session itself began (LibraryModel.begin), not only Play: only then is a run
        /// that ends early a game that was running.
        var began = false

        func note(background date: Date?) { LogTrail.lock.lock(); background = date; LogTrail.lock.unlock(); saveMarker() }

        /// Documents/madeira-trail-open.txt while a game runs.
        static var markerURL: URL? {
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent("madeira-trail-open.txt")
        }
        func stepsLine() -> String {
            steps.map { "\($0.0) \(String(format: "%.1f", $0.1))" }.joined(separator: " · ")
        }
        func saveMarker() {
            LogTrail.lock.lock()
            guard let title, began, backAt == nil else { LogTrail.lock.unlock(); return }
            var lines = ["game=\(title)", "started=\(LogTrail.clock(started))", "steps=\(stepsLine())"]
            if let windowsPath { lines.append("path=\(windowsPath)") }
            if let background { lines.append("background=\(LogTrail.clock(background))") }
            if let lastError { lines.append("last-error=\(lastError)") }
            LogTrail.lock.unlock()
            lines += AutoTune.markerLines()   // (auto-tune) where this run starts in the log
            guard let url = Self.markerURL else { return }
            try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        static func clearMarker() { if let url = markerURL { try? FileManager.default.removeItem(at: url) } }
    }
    static let session = Session()
    /// (log-fixes) Whether `title` is still running (its Wine not finished): Get Help's upload
    /// waits for the end of the run before it sends the logs.
    static func isRunning(_ title: String) -> Bool { lock.lock(); defer { lock.unlock() }; return session.title == title }
    private static var warnings = 0

    static func clock(_ date: Date) -> String {
        // [plain-time] HH:mm:ss in local time from localtime_r: a new DateFormatter per call crashed
        // inside ICU (Sentry 9J/9N/AX/E3). Same text. Off: env.MADEIRA_PLAIN_TIME = 0.
        if plainTime { return PlainTime.text(date, utc: false, withDate: false) }
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: date)
    }
    static let plainTime = MadeiraConfig.flag("MADEIRA_PLAIN_TIME", fallback: true)

    /// The last run ended while a game ran: say so, with the steps it got to.
    private static func reportLastRun() {
        guard let url = Session.markerURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        Session.clearMarker()
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            fields[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        var words = "[last-run] Madeira closed while \(fields["game"] ?? "a game") was running (started \(fields["started"] ?? "?"))"
        words += fields["background"].map { ", in the background since \($0): iOS ended it there, or it was swiped away" }
            ?? ": a crash or iOS ending it for memory (it never got back to the library)"
        if let steps = fields["steps"], !steps.isEmpty { words += "; steps: \(steps)" }
        if let error = fields["last-error"] { words += "; last error: \(error)" }
        LogStore.shared.log(words, level: .error)
        // (get-help) Not after the background: iOS ending it there, or a swipe, is no game problem.
        if fields["background"] == nil, let game = fields["game"] {
            GetHelpCenter.stopped(title: game, windowsPath: fields["path"], why: "Madeira closed while it ran")
            AutoTune.lastRunKilled(title: game, windowsPath: fields["path"], fields: fields)   // (auto-tune)
        }
        LogRuns.previousRun(String(words.dropFirst("[last-run] ".count)))
        FlightRecorder.lastRunDied()   // (flight-recorder)
        RunLedger.unknownEnd(game: fields["game"] ?? "?", words: String(words.dropFirst("[last-run] ".count)))   // (run-ledger)
    }

    /// Play in the library (ContentView.launchLibraryEntry): the clock starts.
    static func play(_ entry: LibraryEntry) {
        guard enabled else { return }
        lock.lock()
        session.title = entry.title; session.windowsPath = entry.windowsPath; session.started = Date(); session.steps = [("play", 0)]
        session.reason = nil; session.exitDetail = nil; session.lastError = nil; session.crash = nil
        session.dockResult = nil; session.inMenu = false; session.backAt = nil; session.background = nil
        session.warningsAtStart = warnings; session.began = false
        lock.unlock()
        var store = "a game you added"
        if let id = entry.steamAppID { store = "Steam \(id)" }
        else if let id = entry.epicAppName { store = "Epic \(id)" }
        else if let id = entry.gogProductID { store = "GOG \(id)" }
        else if let id = entry.itchGameID { store = "itch \(id)" }
        else if let id = entry.eaOfferID { store = "EA \(id)" }
        write(.step, "[step] \(entry.title): play (\(store), \(entry.windowsPath))")
        AutoTune.play()   // (auto-tune) where this run starts in the log
        LogRuns.start(title: entry.title, store: store, windowsPath: entry.windowsPath, settings: RunLedger.settingsText(entry))
    }

    /// The session begins (LibraryModel.begin): the state it starts in.
    static func began(_ entry: LibraryEntry, dock: Bool) {
        guard enabled else { return }
        lock.lock()
        // A start that did not come through Play (a Dock start, a shortcut's held game) starts the clock here.
        let fresh = session.title != entry.title || Date().timeIntervalSince(session.started) > 180
        if fresh {
            session.title = entry.title; session.windowsPath = entry.windowsPath; session.started = Date(); session.steps = []
            session.reason = nil; session.exitDetail = nil; session.lastError = nil; session.crash = nil
            session.dockResult = nil; session.backAt = nil; session.background = nil
            session.warningsAtStart = warnings
        }
        session.inMenu = false; session.began = true
        lock.unlock()
        if fresh { AutoTune.play() }   // (auto-tune) a start without Play: its run starts here in the log
        if !LogRuns.began(title: entry.title) {   // a start without Play: its run starts here
            LogRuns.start(title: entry.title, store: dock ? "Madeira Dock" : "", windowsPath: entry.windowsPath, settings: RunLedger.settingsText(entry))
            LogRuns.began(title: entry.title)
        }
        step("session")
        let config = GameProfile(windowsPath: entry.windowsPath).values
        let configWords = config.isEmpty ? "no game config" : "game config \(config.count) line(s): "
            + config.keys.sorted().prefix(12).joined(separator: ", ")
        let pads = GCController.controllers().map { $0.vendorName ?? "?" }
        let process = ProcessInfo.processInfo
        let jit = SigningStatus.current.debugged ? "on" : "off"
        LogStore.shared.log("[game-start] \(entry.title)\(dock ? " (Madeira Dock)" : ""): \(configWords) | "
            + "memory \(Memory.footprintMB) MB in use, \(Memory.availableMB) MB left | JIT \(jit) | "
            + "thermal \(DeviceLoadDiagnostics.thermalName(process.thermalState)), low power \(process.isLowPowerModeEnabled ? 1 : 0) | "
            + "controller \(pads.isEmpty ? "none" : pads.joined(separator: ", ")), touch controls \(entry.touchControls ? "on" : "off") | "
            + "resolution \(entry.resolution), fps mode \(entry.fpsMode)")
    }

    /// One start or quit step, in seconds since Play.
    static func step(_ name: String, at date: Date = Date()) {
        guard enabled else { return }
        lock.lock()
        guard let title = session.title else { lock.unlock(); return }
        let seconds = max(0, date.timeIntervalSince(session.started))
        if session.steps.count >= 40 || session.steps.contains(where: { $0.0 == name }) { lock.unlock(); return }
        session.steps.append((name, seconds))
        lock.unlock()
        write(.step, "[step] \(title) +\(String(format: "%.2f", seconds))s \(name)")
        session.saveMarker()
        LogRuns.stepped(name, seconds: seconds)
    }

    /// Why the game is ending, when Madeira knows (Quit game, Stop, a failed start).
    static func ending(_ reason: String) {
        lock.lock()
        let first = session.reason == nil
        if first { session.reason = reason }
        lock.unlock()
        if first { step("asked to end") }
    }

    /// The in-game menu opened or closed: taps there are menus again.
    static func inGameMenu(_ open: Bool) { lock.lock(); session.inMenu = open; lock.unlock() }

    /// Back in the library (LibraryModel.finish). The end line waits for Wine to finish, at
    /// most 90 s, so it can carry the exit code.
    @MainActor static func backInLibrary() {
        guard enabled else { return }
        lock.lock()
        guard session.title != nil, session.backAt == nil else { lock.unlock(); return }
        session.backAt = Date()
        lock.unlock()
        Session.clearMarker()   // back in the library: whatever happens next is no crash in a game
        step("library")
        let since = Date()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
            let done = wine_process_is_running() == 0 && wineserver_is_running() == 0
            guard done || Date().timeIntervalSince(since) > 90 else { return }
            timer.invalidate()
            if done { step("wine ended") }
            finished(wineDone: done)
        }
    }

    private static func finished(wineDone: Bool) {
        lock.lock()
        guard let title = session.title else { lock.unlock(); return }
        let reason = session.reason, crash = session.crash, dock = session.dockResult, error = session.lastError
        let steps = session.stepsLine(), total = Date().timeIntervalSince(session.started)
        let newWarnings = warnings - session.warningsAtStart
        let shown = session.steps.first { $0.0.hasPrefix("game shown") || $0.0 == "Steam screen ended (game-window)" }
        let windowsPath = session.windowsPath
        session.title = nil; session.inMenu = false
        lock.unlock()
        Session.clearMarker()
        var why: String
        if let reason { why = reason }
        else if shown == nil { why = "it stopped before its window showed" }
        else { why = "it closed by itself" }
        var code = "exit code not reported"
        var status: UInt32 = 0
        if wine_crash_exit_status(&status) != 0 { code = String(format: "Windows error 0x%08X", status) }
        else if let ended = gameChildEnd(windowsPath: windowsPath, within: total) { code = ended }
        else if wine_launched_exit_code(&status) != 0 { code = "exit code \(status)" + (status == 0 ? " (normal)" : "") }
        var line = "[game-end] \(title): \(why); \(code)"
        if let dock { line += "; Madeira Dock result \(dock)" }
        if let crash { line += "; Wine: \(crash)" }
        if !wineDone { line += "; Wine still running 90 s after the library came back" }
        let pool = JITPoolMeter.current
        line += " | memory \(Memory.footprintMB) MB now, peak \(Memory.peakMB) MB, \(newWarnings) iOS memory warning(s)"
        if let mb = pool.sizeMB { line += " | JIT pool \(mb) MB, \(pool.used >> 20) MB used" + (pool.exhausted > 0 ? ", ran out \(pool.exhausted)x" : "") }
        line += " | \(String(format: "%.0f", total)) s in all: \(steps)"
        if let error { line += " | last error: \(error)" }
        LogStore.shared.log(line, level: why == "it closed by itself" && code.hasPrefix("exit code 0") ? .info : .error)
        // (get-help) The game stopped by itself: a Windows error, an exit code other than 0, or no
        // window at all. Not when the player quit or stopped it (reason).
        if reason == nil, code.hasPrefix("Windows error") || (code.hasPrefix("exit code ") && !code.hasPrefix("exit code 0"))
            || why == "it stopped before its window showed" {
            GetHelpCenter.stopped(title: title, windowsPath: windowsPath, why: "\(why); \(code)")
        }
        // (fix-check) A run since Get Help's Apply: ask whether the fix worked (GetHelpView.swift).
        let stoppedByItself = reason == nil && (code.hasPrefix("Windows error") || (code.hasPrefix("exit code ") && !code.hasPrefix("exit code 0"))
            || why == "it stopped before its window showed")
        GetHelpCenter.gameFinished(windowsPath: windowsPath, started: Date().addingTimeInterval(-total), seconds: total,
                                   ended: stoppedByItself ? "crash" : (reason != nil ? "quit" : "normal"))
        // (rate-after-run) Only a clean run: no Windows error or exit code other than 0 (even if the player pressed Stop), a window showed, no Wine crash.
        let badEnd = code.hasPrefix("Windows error") || (code.hasPrefix("exit code ") && !code.hasPrefix("exit code 0"))
        if !badEnd, crash == nil, shown != nil { GetHelpCenter.ratePrompt(title: title, windowsPath: windowsPath, seconds: total) }
        // (auto-tune) Read this run's log: judge a fix being tried, or get an offer ready after a crash.
        AutoTune.ended(title: title, windowsPath: windowsPath, started: Date().addingTimeInterval(-total), seconds: total,
                       windowShown: shown != nil, ending: stoppedByItself ? .crashed : .played)
        LogRuns.ended(why + ", " + code + (dock.map { ", Madeira Dock result \($0)" } ?? "") + (crash.map { ", Wine: \($0)" } ?? ""), seconds: total,
                      quit: reason.map { $0.hasPrefix("the start failed") ? "start failed" : (shown == nil ? "user, no window" : "user") }
                          ?? (stoppedByItself ? "crash" : "normal"))
    }

    /// (game-child-exit) In a Madeira Dock or launcher session the program the app started (the Dock host,
    /// a launcher) is not the game: it ends with 0 while the game itself, a child process, crashed. The
    /// [game-end] line then said "exit code 0 (normal)" for real crashes (Flinthook exit -1, Slay the Spire 2,
    /// Isaac, Castle in the Clouds). ntdll keeps the last ends of child processes (process_ios.c,
    /// madeira_child_report); this takes the one that ended last with a status other than 0, from the game's
    /// own folder, not a helper or crash reporter, during this run. nil when there is none: the old code is
    /// used. env.MADEIRA_GAME_CHILD_EXIT = 0 turns it off.
    static let childExitEnabled = MadeiraConfig.flag("MADEIRA_GAME_CHILD_EXIT")
    static func gameChildEnd(windowsPath: String?, within seconds: TimeInterval) -> String? {
        guard childExitEnabled, let windowsPath, !windowsPath.isEmpty else { return nil }
        var buf = [CChar](repeating: 0, count: 16384)
        guard madeira_child_report(&buf, Int32(buf.count)) > 0 else { return nil }
        return gameChildEnd(report: String(cString: buf), windowsPath: windowsPath, within: seconds)
    }
    /// The parsing half, apart so the host check can feed it a report text.
    static func gameChildEnd(report: String, windowsPath: String, within seconds: TimeInterval) -> String? {
        func norm(_ p: String) -> String {
            var t = p.replacingOccurrences(of: "/", with: "\\").lowercased()
            for prefix in ["\\??\\", "\\\\?\\"] where t.hasPrefix(prefix) { t.removeFirst(prefix.count) }
            while t.hasSuffix("\\") { t.removeLast() }
            return t
        }
        var folder = norm(windowsPath)
        if folder.hasSuffix(".exe"), let cut = folder.lastIndex(of: "\\") { folder = String(folder[..<cut]) }
        guard !folder.isEmpty else { return nil }
        var best: (ago: Double, status: UInt32, name: String)?
        for row in report.split(separator: "\n") {
            let f = row.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false)
            // E <helper> <status hex> <seconds since the end> <seconds it lived> <path>
            guard f.count == 6, f[0] == "E", f[1] == "0", let status = UInt32(f[2], radix: 16), status != 0,
                  let ago = Double(f[3]), ago <= seconds else { continue }
            let path = norm(String(f[5]))
            guard path.hasPrefix(folder + "\\") else { continue }
            if best == nil || ago < best!.ago {
                best = (ago, status, String(path[path.index(after: path.lastIndex(of: "\\")!)...]))
            }
        }
        guard let best else { return nil }
        let isNT = best.status >= 0xC0000000 && best.status != 0xFFFFFFFF
        let what = isNT ? String(format: "Windows error 0x%08X", best.status) : "exit code \(Int32(bitPattern: best.status))"
        return "\(what) (\(best.name), a program the game started)"
    }

    // MARK: Reading the log

    /// Every line of madeira-log.txt passes here (LogTail, a background queue): Wine's and the
    /// app's start lines become steps. One `contains` per pattern, only while a game runs.
    static func see(_ line: String) {
        guard enabled else { return }
        lock.lock(); let running = session.title != nil; lock.unlock()
        guard running else { return }
        // The trail's own lines quote the patterns below.
        if line.contains("[step] ") || line.contains("[game-") || line.contains("[log-trail]") || line.contains("[last-run]") { return }
        if let r = line.range(of: "] [ERR] ") {
            let text = clip(String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces), 160)
            lock.lock(); session.lastError = text; lock.unlock()
        }
        if let r = line.range(of: "wine: Unhandled ") {
            lock.lock(); if session.crash == nil { session.crash = clip("Unhandled " + line[r.upperBound...], 140) }; lock.unlock()
        }
        if let r = line.range(of: "[dock-status] host-ended result=") {
            let result = String(line[r.upperBound...].prefix { $0 != " " })
            lock.lock(); session.dockResult = result; lock.unlock()
        }
        for (pattern, name) in steps where line.contains(pattern) {
            var label = name
            if name.hasSuffix("(") {   // the reason follows "reason=" in the line
                let reason = line.range(of: "reason=").map { String(line[$0.upperBound...].prefix { $0 != " " }) } ?? "?"
                label = name + reason + ")"
            }
            step(label, at: time(of: line) ?? Date())
        }
    }

    /// Lines that mark a step (the code that writes them: tests/host/check-log-trail.py).
    static let steps: [(String, String)] = [
        ("[jit-on-play] JIT is on", "JIT on"),
        ("[madeira-dock] starting the host", "Dock host"),
        ("Running full Wine sequence", "Wine sequence"),
        ("JIT pool ready", "JIT pool ready"),
        ("JIT pool allocation FAILED", "JIT pool FAILED"),
        ("[launch] wineserver ready", "wineserver ready"),
        ("Wine process thread launched", "Wine started"),
        ("[launch-view] dismissed reason=", "game shown ("),
        ("[steam-launch-view] end reason=", "Steam screen ended ("),
        ("[frontend] graceful close requested", "close asked (Alt+F4)"),
        ("[dock-status] host-ended", "Dock ended"),
        ("Wine finished after", "Wine finished"),
    ]

    /// "[00:10:48.331] ..." as a date today (yesterday, for a line from before midnight).
    static func time(of line: String) -> Date? {
        guard line.hasPrefix("["), line.count > 13 else { return nil }
        let t = line.dropFirst().prefix(12)
        let parts = t.split(whereSeparator: { $0 == ":" || $0 == "." }).compactMap { Int($0) }
        guard parts.count == 4 else { return nil }
        let now = Date()
        var c = Calendar.current.dateComponents([.year, .month, .day], from: now)
        c.hour = parts[0]; c.minute = parts[1]; c.second = parts[2]; c.nanosecond = parts[3] * 1_000_000
        guard var date = Calendar.current.date(from: c) else { return nil }
        if date.timeIntervalSince(now) > 3600 { date.addTimeInterval(-86400) }
        return date
    }

    // MARK: Context for errors

    /// " (during: Stardew Valley, after JIT pool ready +4.3 s)", or the screen in the library.
    static func during() -> String {
        lock.lock(); defer { lock.unlock() }
        if let title = session.title {
            if let last = session.steps.last {
                return " (during: \(title), after \(last.0) +\(String(format: "%.1f", last.1)) s)"
            }
            return " (during: \(title))"
        }
        return ""
    }
}

/// Memory as iOS counts it for Madeira.
enum Memory {
    static var footprintMB: Int { Int(vmInfo()?.phys_footprint ?? 0) >> 20 }
    static var peakMB: Int { Int(vmInfo()?.ledger_phys_footprint_peak ?? 0) >> 20 }
    static var availableMB: Int { Int(os_proc_available_memory()) >> 20 }
    private static func vmInfo() -> task_vm_info_data_t? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info : nil
    }
}

/// Sees each tap on the window and never takes it: taps, scrolls and buttons work as before.
final class LogTrailTapWatch: UIGestureRecognizer {
    private var start: CGPoint?
    private var startTime = Date()
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touches.count == 1, let touch = touches.first, let view else { state = .failed; return }
        start = touch.location(in: view); startTime = Date()
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let start, let touch = touches.first, let view else { return }
        let p = touch.location(in: view)
        if abs(p.x - start.x) > 12 || abs(p.y - start.y) > 12 { state = .failed }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let start, let window = view as? UIWindow, Date().timeIntervalSince(startTime) < 1 {
            MainActor.assumeIsolated { LogTrail.tapped(at: start, in: window) }
        }
        state = .failed
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }
    override func reset() { super.reset(); start = nil }
}

/// A named page or sheet for the log ([screen] open / close).
struct LogScreen: ViewModifier {
    let name: String
    func body(content: Content) -> some View {
        content
            .onAppear { LogTrail.opened(name) }
            .onDisappear { LogTrail.closed(name) }
    }
}

extension View {
    /// Names this page or sheet in the log: "[screen] open game page: Stardew Valley".
    func logScreen(_ name: String) -> some View { modifier(LogScreen(name: name)) }
}

// madeira-log-summary: the top of madeira-log.txt says what happened, before the full log.
//
// A fixed-size block (LogRuns.headerBytes) is the first thing in the file: the build, the
// device, madeira.cfg, and one line per game run (game, how long it ran, how it ended), each
// with the game's own config. It is rewritten in place as games start, step and end; Wine and
// the app keep appending below it (O_APPEND), so nothing else in the file moves. The block has
// no [tag] lines, so nothing that reads the log mistakes it for a log line.
//
// LogRuns.lastRunText(game:) is one game's last run, cut from the log for Get Help: the block,
// then that run's Madeira lines, Wine's error lines and the run's last lines. Each run is
// marked in the log by [run-start] #N <game> and [run-end] #N.
enum LogRuns {
    static let enabled = LogTrail.enabled && MadeiraConfig.flag("MADEIRA_LOG_SUMMARY")
    static let headerBytes = 4096
    static let firstLine = "=== Madeira log summary: what happened, then the full log below ==="
    static let lastLine = "=== end of summary ==="

    struct Run {
        var number: Int
        var title: String
        var store: String
        var config: String
        /// (log-settings) "32-bit · controller keys · display 1408x648 fit ...": the Game details settings that decide how the game runs.
        var settings = ""
        /// (debug-logging) "Debug logging Medium · game config 3fa81c2e (14 lines)", test bundle with a level only.
        var debug: String?
        var started: Date
        var began = false
        var lastStep: String?
        var ended: String?
        var seconds: Double?
    }
    private static let lock = NSLock()
    private static var runs: [Run] = []
    private static var previous: String?
    private static var count = 0
    private static let started = Date()
    /// "iPad iPadOS 27.0.1", set on the main thread at the app's first appearance (LogTrail.install).
    static var device = "device not read yet"

    /// "pool = 896; env.DOTNET_X = 0" from the game's own config file, or "none".
    static func configText(_ windowsPath: String) -> String {
        let values = GameProfile(windowsPath: windowsPath).values
        return values.isEmpty ? "none" : values.keys.sorted().map { "\($0) = \(values[$0] ?? "")" }.joined(separator: "; ")
    }

    /// A run starts (Play, or a session that began without Play). Returns its number.
    static func start(title: String, store: String, windowsPath: String, settings: String = "") {
        guard enabled else { return }
        let config = configText(windowsPath)
        lock.lock()
        // A Play that never began a session (held for a restart, an error before the start).
        if let last = runs.indices.last, runs[last].ended == nil, !runs[last].began {
            runs[last].ended = "did not start (held, or stopped before the session)"
        }
        count += 1
        let number = count
        let debug = DebugLogging.stamp(windowsPath: windowsPath)
        runs.append(Run(number: number, title: title, store: store, config: config, settings: settings, debug: debug, started: Date()))
        lock.unlock()
        LogStore.shared.log("[run-start] #\(number) \(title)")
        if let debug { LogStore.shared.log("[debug-log] #\(number) \(debug)") }
        writeHeader()
    }

    /// The session itself began for the newest run of `title`; true when there was one.
    @discardableResult static func began(title: String) -> Bool {
        guard enabled else { return false }
        lock.lock()
        guard let i = runs.lastIndex(where: { $0.title == title && $0.ended == nil }) else { lock.unlock(); return false }
        runs[i].began = true
        lock.unlock()
        writeHeader()
        return true
    }

    static func stepped(_ name: String, seconds: Double) {
        guard enabled else { return }
        lock.lock()
        guard let i = runs.indices.last, runs[i].ended == nil else { lock.unlock(); return }
        runs[i].lastStep = "\(name) +\(String(format: "%.1f", seconds)) s"
        lock.unlock()
        writeHeader()
    }

    static func ended(_ words: String, seconds: Double, quit: String = "?") {
        guard enabled else { return }
        lock.lock()
        guard let i = runs.indices.last, runs[i].ended == nil else { lock.unlock(); return }
        runs[i].ended = words; runs[i].seconds = seconds
        let number = runs[i].number
        let run = runs[i]
        lock.unlock()
        if run.began { FlightRecorder.runEnded(started: run.started) }   // (flight-recorder) before [run-end], inside the run
        LogStore.shared.log("[run-end] #\(number)")
        writeHeader()
        RunLedger.ended(run: run, words: words, seconds: seconds, quit: quit)   // (run-ledger)
    }

    /// The previous app run ended in a game ([last-run]).
    static func previousRun(_ words: String) {
        guard enabled else { return }
        lock.lock(); previous = words; lock.unlock()
        writeHeader()
    }

    static func duration(_ seconds: Double) -> String {
        seconds < 90 ? "\(Int(seconds.rounded())) s" : seconds < 5400 ? "\(Int((seconds / 60).rounded())) min"
            : String(format: "%.1f h", seconds / 3600)
    }

    /// The block's text, padded to `headerBytes` (the oldest runs leave first when it is full).
    static func headerText() -> String {
        lock.lock()
        let runs = self.runs, previous = self.previous
        lock.unlock()
        let cfg = MadeiraConfig.all().sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }.joined(separator: "; ")
        var top = [firstLine,
                   "Build: \(BuildStamp.text) · \(device) · Madeira opened \(LogTrail.clock(started))",
                   "madeira.cfg: " + LogTrail.clip(cfg.isEmpty ? "none" : cfg, 600)]
        if let previous { top.append("Previous run: " + LogTrail.clip(previous, 400)) }
        top.append(runs.isEmpty ? "Game runs: none yet" : "Game runs (\(runs.count)):")
        var groups: [[String]] = []   // (review 7) one group per run, trimmed whole
        for run in runs {
            var lines: [String] = []
            var line = "  \(run.number). \(run.title)" + (run.store.isEmpty ? "" : " (\(run.store))") + ", started \(LogTrail.clock(run.started)): "
            if let ended = run.ended {
                line += (run.seconds.map { "ran \(duration($0)), " } ?? "") + ended
            } else {
                line += "running" + (run.lastStep.map { ", last step \($0)" } ?? "")
            }
            lines.append(LogTrail.clip(line, 400))
            if !run.settings.isEmpty { lines.append("     settings: " + LogTrail.clip(run.settings, 200)) }   // (log-settings)
            lines.append("     its config: " + LogTrail.clip(run.config, 400))
            if let debug = run.debug { lines.append("     " + LogTrail.clip(debug, 200)) }
            groups.append(lines)
        }
        let end = [lastLine, "(The full log follows.)"]
        func joined(_ body: [String]) -> String { (top + body + end).joined(separator: "\n") + "\n" }
        while joined(groups.flatMap { $0 }).utf8.count > headerBytes - 2, groups.count >= 2 { groups.removeFirst() }
        var text = joined(groups.flatMap { $0 })
        while text.utf8.count > headerBytes - 2 { text.removeLast(); }
        let pad = headerBytes - 1 - text.utf8.count
        return text + String(repeating: " ", count: max(0, pad)) + "\n"
    }

    private static let fileLock = NSLock()
    /// The block alone, as the log file's first bytes (LogStore.init and clear()).
    static func initialHeader() -> String { enabled ? headerText() : "" }

    /// Rewrites the block in place, only while the file still starts with it (a cleared or
    /// replaced log is left alone, so no log line is ever written over).
    static func writeHeader() {
        guard enabled else { return }
        let text = headerText()
        guard let data = text.data(using: .utf8), data.count == headerBytes else { return }
        let url = LogStore.shared.logURL
        fileLock.lock(); defer { fileLock.unlock() }
        guard let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: firstLine.utf8.count),
              String(decoding: head, as: UTF8.self) == firstLine,
              ((try? handle.seekToEnd()) ?? 0) >= UInt64(headerBytes) else { return }
        try? handle.seek(toOffset: 0)
        try? handle.write(contentsOf: data)
    }

    // MARK: One run, for Get Help

    /// One game's last run, small enough to send: the summary block, then from that run's
    /// [run-start] to its [run-end] (or the end of the file): every line Madeira wrote, Wine's
    /// error lines (at most `wineErrors`), and the run's last `tailLines` lines; cut in the
    /// middle past `maxBytes`. `game` nil: the last run of any game. Looks in this run's log,
    /// then the previous app run's, then the last log that had a game. Reads files of tens
    /// of MB: call it off the main thread. nil when no run is found.
    static func lastRunText(game: String? = nil, maxBytes: Int = 200_000, tailLines: Int = 200, wineErrors: Int = 300) -> String? {
        let docs = LogStore.shared.logURL.deletingLastPathComponent()
        for name in ["madeira-log.txt", "madeira-log.prev.txt", LogSummary.gameLogName] {
            if let text = lastRun(in: docs.appendingPathComponent(name), game: game, maxBytes: maxBytes,
                                  tailLines: tailLines, wineErrors: wineErrors) {
                return text
            }
        }
        return nil
    }

    static func lastRun(in url: URL, game: String?, maxBytes: Int, tailLines: Int, wineErrors: Int) -> String? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return slice(text.split(separator: "\n", omittingEmptySubsequences: false), game: game,
                     maxBytes: maxBytes, tailLines: tailLines, wineErrors: wineErrors)
    }

    /// The cutting itself, on the log's lines (host-tested in Python: check-log-trail.py mirrors it).
    static func slice(_ lines: [Substring], game: String?, maxBytes: Int, tailLines: Int, wineErrors: Int) -> String? {
        // The summary block: the file's first lines up to its last line.
        var header: [Substring] = []
        if lines.first.map({ $0.hasPrefix(firstLine) }) == true, let end = lines.firstIndex(where: { $0.hasPrefix(lastLine) }) {
            header = Array(lines[...end])
        }
        // The last [run-start] (of `game`).
        var startIndex: Int?, number: String?
        for i in lines.indices.reversed() {
            guard let r = lines[i].range(of: "[run-start] #") else { continue }
            let rest = lines[i][r.upperBound...]
            let n = rest.prefix { $0.isNumber }
            let title = rest.dropFirst(n.count + 1)
            if let game, title.trimmingCharacters(in: .whitespaces) != game { continue }
            startIndex = i; number = String(n); break
        }
        guard let startIndex, let number else { return nil }
        let endMarker = "[run-end] #\(number)"
        var endIndex = lines.count - 1
        for i in startIndex..<lines.count where lines[i].contains(endMarker) { endIndex = i; break }
        let run = lines[startIndex...endIndex]
        let tailStart = max(startIndex, endIndex - tailLines + 1)
        var out: [Substring] = header
        if !header.isEmpty { out.append("") }
        out.append("--- One game run: Madeira's lines, Wine's errors, and its last \(tailLines) lines ---")
        var errors = 0
        var crashLines = 0
        // (crash-capture) Wine's "[crash-report]" block is kept line for line (80 lines at most); it has no
        // time stamp, so without this rule it would be cut with the other Wine lines.
        let keepCrash = MadeiraConfig.flag("MADEIRA_REPORT_CRASH_BLOCK")
        for i in run.indices {
            let line = lines[i]
            let madeira = line.hasPrefix("[") && line.dropFirst().prefix(12).filter({ $0 == ":" }).count == 2
            let wineError = line.contains(":err:") || line.contains("wine: ") || line.contains("Unhandled ")
            if keepCrash, crashLines < 80, line.contains("[crash-report]") { out.append(line); crashLines += 1; continue }
            if i >= tailStart || madeira { out.append(line) }
            else if wineError, errors < wineErrors { out.append(line); errors += 1 }
        }
        var result = out.joined(separator: "\n") + "\n"
        if result.utf8.count > maxBytes {
            let keep = maxBytes / 2
            let head = String(result.prefix(keep))
            let tail = String(result.suffix(keep))
            result = head + "\n--- (cut here: the run's lines were over \(maxBytes / 1000) KB) ---\n" + tail
        }
        return result
    }
}

/// [plain-time] Clock text without Foundation's DateFormatter (ICU), for LogTrail.clock and
/// CrashReports.stamp: "HH:mm:ss" or "yyyy-MM-dd HH:mm:ss", local time or UTC.
enum PlainTime {
    static func text(_ date: Date, utc: Bool, withDate: Bool) -> String {
        var t = time_t(date.timeIntervalSince1970.rounded(.down))
        var parts = tm()
        if utc { gmtime_r(&t, &parts) } else { localtime_r(&t, &parts) }
        let hms = String(format: "%02d:%02d:%02d", parts.tm_hour, parts.tm_min, parts.tm_sec)
        guard withDate else { return hms }
        return String(format: "%04d-%02d-%02d ", parts.tm_year + 1900, parts.tm_mon + 1, parts.tm_mday) + hms
    }
}

// MARK: (run-ledger, keep-lastgood, log-settings, log-lastrun) one change, four switches
//
// env.MADEIRA_RUN_LEDGER = 0      no run-ledger.txt (one tab-separated line per game launch)
// env.MADEIRA_KEEP_LASTGOOD = 0   no run-history/<game>/good.txt and fail.txt
// env.MADEIRA_LOG_SETTINGS = 0    no "settings:" line under each game run in the log's summary block
// env.MADEIRA_LOG_LASTRUN = 0     shared logs do not get the previous Madeira launch's last game run
//
// Files live in Documents/run-history/ (NOT Documents/logs: Get Help reads every .txt there as a
// game log). Everything written is scrubbed (PrivacyScrub). Nothing here changes the game's launch.
enum RunLedger {
    static let ledgerOn = MadeiraConfig.flag("MADEIRA_RUN_LEDGER")
    static let keepOn = MadeiraConfig.flag("MADEIRA_KEEP_LASTGOOD")
    static let settingsOn = MadeiraConfig.flag("MADEIRA_LOG_SETTINGS")
    static let lastRunOn = MadeiraConfig.flag("MADEIRA_LOG_LASTRUN")
    static let ledgerName = "run-ledger.txt"
    static let maxLines = 300
    static let keepCap = 20 * 1024 * 1024
    static let runCap = 2 * 1024 * 1024
    static let shareCap = 600 * 1024
    private static let lock = NSLock()
    private static let queue = DispatchQueue(label: "madeira.run-ledger", qos: .utility)

    static var folder: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("run-history", isDirectory: true)
    }

    /// "32-bit · controller keys · display 1408x648 fit · launch desktop · fps 1": the Game details settings.
    static func settingsText(_ e: LibraryEntry) -> String {
        guard settingsOn else { return "" }
        return ["\(e.bits)-bit", "controller \(e.controllerMode ?? "game's own")", "display \(e.resolution) \(e.display ?? "fit")",
                "launch \(e.launchMode ?? "direct")", "fps mode \(e.fpsMode)"].joined(separator: " \u{B7} ")
    }

    static func field(_ s: String) -> String {
        PrivacyScrub.line(s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " "))
    }

    /// One ledger line (pure: check-run-ledger.py mirrors it).
    static func line(_ f: [String]) -> String { f.map(field).joined(separator: "\t") }

    static func stamp() -> String { PlainTime.text(Date(), utc: true, withDate: true) + "Z" }

    static let header = "# run ledger, one line per game launch, tab separated: time(UTC) | build | game | store | device | "
        + "madeira.cfg hash | game cfg hash | quit by | seconds | last step | end | ended"

    /// A run reached its [run-end].
    static func ended(run: LogRuns.Run, words: String, seconds: Double, quit: String) {
        if ledgerOn {
            let cfg = MadeiraConfig.all().sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }.joined(separator: "; ")
            append(line([stamp(), BuildStamp.text, run.title, run.store, LogRuns.device, DebugLogging.configHash(cfg),
                         DebugLogging.configHash(run.config), quit, String(Int(seconds.rounded())), run.lastStep ?? "-", words, "yes"]))
        }
        if keepOn { keepRun(title: run.title, number: run.number, words: words, seconds: seconds, quit: quit) }
    }

    /// The previous app run ended in a game without a [run-end] ([last-run]).
    static func unknownEnd(game: String, words: String) {
        guard ledgerOn else { return }
        append(line([stamp(), BuildStamp.text, game, "-", "-", "-", "-", "unknown", "-", "-", words, "unknown"]))
    }

    private static func append(_ text: String) {
        queue.async {
            guard let dir = folder else { return }
            lock.lock(); defer { lock.unlock() }
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(ledgerName)
            var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") }
            lines.append(text)
            if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
            try? ([header] + lines).joined(separator: "\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// The last `count` ledger lines, for shared logs and Get Help.
    static func tailText(_ count: Int = 40, game: String? = nil) -> String? {
        guard ledgerOn, let dir = folder, let text = try? String(contentsOf: dir.appendingPathComponent(ledgerName), encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n").map(String.init)
        // (review 6) A share for one game lists only that game's launches; Settings (no game named) lists all.
        let want = game.map(field)
        let body = lines.filter { !$0.hasPrefix("#") && (want == nil || $0.split(separator: "\t", omittingEmptySubsequences: false).dropFirst(2).first.map(String.init) == want) }.suffix(count)
        return body.isEmpty ? nil : "\n\n## Run ledger (last \(body.count) game launches, newest last; \(lines.first ?? ""))\n" + body.joined(separator: "\n") + "\n"
    }

    // MARK: last good and last fail run per game

    static func gameFolder(_ title: String) -> URL? {
        let name = ClaudeHelp.safeName(title)
        return folder?.appendingPathComponent(name.allSatisfy { $0 == "." } ? "Game" : name, isDirectory: true)   // (review 8) never "." or ".."
    }

    /// Cuts the run from madeira-log.txt a moment later (the [run-end] line is written by then), scrubs it and
    /// keeps it as good.txt (60 s or more, and a user quit or exit code 0) or fail.txt.
    static func keepRun(title: String, number: Int, words: String, seconds: Double, quit: String) {
        queue.asyncAfter(deadline: .now() + 3) {
            guard let docs = ClaudeHelp.documents, let dir = gameFolder(title) else { return }
            let log = docs.appendingPathComponent("madeira-log.txt")
            // (review 1, 3) The run is found by its number, and the log is streamed: only the kept head and
            // tail are held, and only those lines are scrubbed.
            let startMark = "[run-start] #\(number) \(title)", endMark = "[run-end] #\(number)"
            let half = runCap / 2
            var head: [String] = [], tail: [String] = [], tailStart = 0, headBytes = 0, tailBytes = 0
            var inRun = false, dropped = 0
            LogLines.scan(in: log) { l in
                if !inRun { if l.hasSuffix(startMark) { inRun = true; head = [l]; headBytes = l.utf8.count + 1 }; return true }
                if tail.isEmpty, headBytes + l.utf8.count + 1 <= half { head.append(l); headBytes += l.utf8.count + 1 }
                else {
                    tail.append(l); tailBytes += l.utf8.count + 1
                    while tailBytes > half, tailStart < tail.count { tailBytes -= tail[tailStart].utf8.count + 1; tailStart += 1; dropped += 1 }
                    if tailStart > 4096 { tail.removeFirst(tailStart); tailStart = 0 }
                }
                return !l.hasSuffix(endMark)
            }
            guard inRun else { return }
            // (review 2) Good = 60 s or more and the player quit with a window up, or it ended itself with exit code 0.
            let good = seconds >= 60 && (quit == "user" || (quit == "normal" && words.contains("exit code 0")))
            var out = [PrivacyScrub.line("# \(title), run #\(number), \(good ? "good" : "failed"): \(words), \(Int(seconds.rounded())) s, \(BuildStamp.text)")]   // (review 4) scrubbed
            out += head.map(PrivacyScrub.line)
            if dropped > 0 { out.append("--- (cut here: \(dropped) lines of the middle left out, the run was over \(runCap / 1_000_000) MB) ---") }
            out += tail[tailStart...].map(PrivacyScrub.line)
            let text = out.joined(separator: "\n") + "\n"
            lock.lock(); defer { lock.unlock() }
            let fm = FileManager.default
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? text.write(to: dir.appendingPathComponent(good ? "good.txt" : "fail.txt"), atomically: true, encoding: .utf8)
            prune()
        }
    }

    /// Oldest game folders go first until run-history is under keepCap.
    private static func prune() {
        guard let dir = folder else { return }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        var games = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys)) ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
        func size(_ u: URL) -> Int {
            ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
                .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        }
        func when(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
        var total = games.reduce(0) { $0 + size($1) }
        games.sort { when($0) < when($1) }
        while total > keepCap, let oldest = games.first {
            total -= size(oldest); try? fm.removeItem(at: oldest); games.removeFirst()
        }
    }

    // MARK: what a shared log gets added

    /// "## Last good run" / "## Last failed run" for `title`, each cut to shareCap (newest end kept).
    static func gameRuns(title: String?, skipping firstLine: String? = nil) -> String {
        guard keepOn, let title, !title.isEmpty, let dir = gameFolder(title) else { return "" }
        var out = ""
        for (name, head) in [("fail.txt", "Last failed run"), ("good.txt", "Last good run")] {
            guard let text = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8), !text.isEmpty else { continue }
            // (review 5) The shared log is this same run: do not add it twice.
            if let firstLine, text.split(separator: "\n", maxSplits: 2).dropFirst().first.map(String.init) == PrivacyScrub.line(firstLine) { continue }
            let cut = text.utf8.count > shareCap
            out += "\n\n## \(head) of \(title) (kept by Madeira" + (cut ? ", start cut to \(shareCap / 1000) KB" : "") + ")\n"
                + (cut ? String(text.suffix(shareCap)) : text)
        }
        return out
    }

    /// (log-lastrun) The previous Madeira launch's last game run, for a shared log that has none of it
    /// (this launch's log, or a share made after Madeira was opened again).
    static func previousLaunchRun() -> String {
        guard lastRunOn, let docs = ClaudeHelp.documents else { return "" }
        let prev = docs.appendingPathComponent("madeira-log.prev.txt")
        guard let text = LogRuns.lastRun(in: prev, game: nil, maxBytes: 300_000, tailLines: 200, wineErrors: 300) else { return "" }
        return "\n\n## Last game run of the previous Madeira launch (madeira-log.prev.txt)\n" + PrivacyScrub.text(text)
    }

    /// Bytes a share can add after the full log: reserve them so the file stays near its cap.
    static func extras(title: String?, log: URL? = nil) -> String {
        var first: String?
        if let log { LogLines.scan(in: log) { first = $0; return false } }
        return (tailText(game: title) ?? "") + gameRuns(title: title, skipping: first)
    }
}

// MARK: - (flight-recorder) Wine's ring of extra traces, copied into the log when a run ends
//
// Cameron, Nov 21: "is there like an ultimate perfect log that we can make every time? ... you always
// have to add stuff to it". Wine (dlls/ntdll/unix/debug.c, flight_take) formats a few extra trace
// channels (by default DLL loads and the loader's, process and thread code's warnings) into a fixed
// ring in Library/Caches/flight-recorder.bin instead of the log, so they cost no log writes and no
// LogStore parsing. The file outlives a crash or an iOS kill; it is not in Documents (no Files app,
// no backup). When a game run ends (Stop, quit, a crash, the game closing), its last 60 s go into
// madeira-log.txt just before [run-end], so every shared log and Get Help report carries them. After
// Madeira itself died mid-game ([last-run]), they go at the end of madeira-log.prev.txt.
//
// Lines are scrubbed (PrivacyScrub), repeats are counted, at most 256 KB (newest) go in. The log's
// own readers skip "] [flight] " lines (LogStore.shouldDropLine, HelpReport.noiseTags, LogSummary).
// Off switch: env.MADEIRA_FLIGHT = 0 (Wine adds no channels; nothing is copied).
// Also: env.MADEIRA_FLIGHT_CHANNELS = trace+seh,trace+module (only trace+/warn+ entries) for more,
//       env.MADEIRA_FLIGHT_MB = <1-64> for the ring's size (default 8). Wine reads these once per
//       Madeira launch.
// Layout (keep in step with debug.c): 4096-byte header {magic "MFR1", slot size, slots, version,
// next (UInt64 @16), opened_ms (UInt64 @24)}, then slots of 512 bytes {seq (0 = being written), ms,
// len (UInt16 @16), text @20}.
enum FlightRecorder {
    static var enabled: Bool { MadeiraConfig.flag("MADEIRA_FLIGHT") }
    static let window: TimeInterval = 60
    static let maxBytes = 256 * 1024
    static let fileName = "flight-recorder.bin"
    static let tag = "] [flight] "

    static var url: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent(fileName)
    }

    struct Line { let seq: UInt64; let ms: UInt64; let text: String }

    /// The finished lines written from `fromMS` to `toMS`, oldest first, and the ring's header numbers.
    /// A plain read (not mapped): Wine may replace the file at the next start.
    static func lines(fromMS: UInt64, toMS: UInt64) -> (lines: [Line], written: UInt64, opened: UInt64, newest: UInt64) {
        guard let url, let data = try? Data(contentsOf: url), data.count >= 4096 else { return ([], 0, 0, 0) }
        return data.withUnsafeBytes { raw in
            func u32(_ at: Int) -> UInt32 { raw.loadUnaligned(fromByteOffset: at, as: UInt32.self) }
            func u64(_ at: Int) -> UInt64 { raw.loadUnaligned(fromByteOffset: at, as: UInt64.self) }
            guard u32(0) == 0x3152464d, u32(4) == 512, u32(12) == 1 else { return ([], 0, 0, 0) }
            let slots = Int(u32(8)), written = u64(16), opened = u64(24)
            guard slots > 0, 4096 + slots * 512 <= raw.count else { return ([], 0, 0, 0) }
            var out: [Line] = []
            var newest: UInt64 = 0
            for i in 0..<slots {
                let at = 4096 + i * 512
                let seq = u64(at)
                // A slot holds line seq-1 at index (seq-1) % slots; anything else is torn or stale.
                guard seq != 0, seq <= written, Int((seq - 1) % UInt64(slots)) == i else { continue }
                let ms = u64(at + 8)
                newest = max(newest, ms)
                guard ms >= fromMS, ms <= toMS else { continue }   // time first: only these are decoded
                let len = min(Int(raw.loadUnaligned(fromByteOffset: at + 16, as: UInt16.self)), 492)
                let bytes = UnsafeRawBufferPointer(rebasing: raw[(at + 20)..<(at + 20 + len)])
                out.append(Line(seq: seq, ms: ms, text: String(decoding: bytes, as: UTF8.self)))
            }
            out.sort { $0.seq < $1.seq }
            return (out, written, opened, newest)
        }
    }

    static func ms(_ date: Date) -> UInt64 { UInt64(max(0, date.timeIntervalSince1970 * 1000)) }

    /// The block for the log, "" when off or nothing is in the window. `died`: the run's end is the
    /// ring's newest line, and nothing older than the launch that wrote it.
    static func block(from: Date?, to: Date = Date(), died: Bool = false, why: String) -> String {
        guard enabled else { return "" }
        var toMS = ms(to) + 2000
        var fromMS = from.map(ms) ?? 0
        if died {
            // First pass for the newest line and the launch it came from.
            let probe = lines(fromMS: UInt64.max, toMS: UInt64.max)
            guard probe.newest > 0 else { return "" }
            toMS = probe.newest
            fromMS = max(fromMS, probe.opened)
        }
        fromMS = max(fromMS, toMS > UInt64(window * 1000) ? toMS - UInt64(window * 1000) : 0)
        let (picked, written, _, _) = lines(fromMS: fromMS, toMS: toMS)
        guard !picked.isEmpty else { return "" }
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.dateFormat = "HH:mm:ss.SSS"
        // Newest first, so the cap keeps the end; reversed at the end.
        var body: [String] = []
        var size = 0, shown = 0, cut = 0
        var last: String?
        var repeats = 0
        func flushRepeat() {
            if repeats > 0 { body.append("    (the line below \(repeats) more time\(repeats == 1 ? "" : "s"))"); repeats = 0 }
        }
        for line in picked.reversed() {
            if size >= maxBytes { cut += 1; continue }
            let stamp = "[\(clock.string(from: Date(timeIntervalSince1970: Double(line.ms) / 1000)))" + tag
            // A slot can hold several lines of one trace: each gets the tag.
            for part in line.text.split(separator: "\n", omittingEmptySubsequences: true).reversed() {
                let text = PrivacyScrub.line(String(part))
                if text == last { repeats += 1; continue }
                flushRepeat()
                last = text
                let out = stamp + text
                body.append(out)
                size += out.utf8.count + 1
            }
            shown += 1
        }
        flushRepeat()
        var head = "=== Flight recorder (\(why)): Wine's extra traces, up to the last \(Int(window)) s, \(shown) lines"
        if cut > 0 { head += ", \(cut) older lines left out (256 KB cap)" }
        head += "; \(written) lines recorded since the ring was made ==="
        return ([head] + body.reversed() + ["=== end of flight recorder ==="]).joined(separator: "\n") + "\n"
    }

    /// Appends `text` to a log file with O_APPEND, so Wine's own appends are never overwritten.
    static func append(_ text: String, to url: URL) {
        guard !text.isEmpty else { return }
        let fd = open(url.path, O_WRONLY | O_APPEND)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let data = Data(text.utf8)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// A run ended: its last 60 s into madeira-log.txt (before its [run-end] line). Only the
    /// lines in the window are decoded and at most 256 KB scrubbed, so this stays short.
    static func runEnded(started: Date) {
        let text = block(from: started.addingTimeInterval(-5), why: "the end of this game run")
        guard !text.isEmpty else { LogStore.shared.log("[flight-recorder] nothing recorded for this run"); return }
        LogStore.shared.flushRepeats()   // a held-back repeat count belongs before the block
        append(text, to: LogStore.shared.logURL)
        LogStore.shared.log("[flight-recorder] \(text.utf8.count) bytes copied into the log")
    }

    /// Madeira died while a game ran: the ring's last 60 s go to the end of madeira-log.prev.txt.
    static func lastRunDied() {
        guard enabled, let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let prev = docs.appendingPathComponent("madeira-log.prev.txt")
        DispatchQueue.global(qos: .utility).async {
            guard FileManager.default.fileExists(atPath: prev.path) else { return }
            let text = block(from: nil, died: true, why: "the last 60 s before Madeira closed")
            guard !text.isEmpty else { return }
            append("\n" + text, to: prev)
            LogStore.shared.log("[flight-recorder] the previous run's last 60 s (\(text.utf8.count) bytes) were added to madeira-log.prev.txt")
        }
    }
}
