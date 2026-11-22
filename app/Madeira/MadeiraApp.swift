import AVFoundation
import Foundation
import SwiftUI

/// Runs SwiftUI's own App.main(). A generic function, so it calls the App extension's
/// implementation and not MadeiraApp.main() below.
@MainActor private func runDefaultAppMain<T: App>(_ app: T.Type) { T.main() }

@main
struct MadeiraApp: App {
    /// [main-stack-move] first thing in the process: with `main-stack-move = 1` in madeira.cfg the
    /// main thread continues on a stack below the executable window and the old stack is freed
    /// (JITAllocator.c), so a fixed-base program over ~730 MB (Civilization VII) can load. Off
    /// otherwise: this is then exactly SwiftUI's own main().
    @MainActor static func main() {
        if madeira_main_stack_move_wanted() != 0 {
            _ = madeira_run_on_new_stack { MainActor.assumeIsolated { runDefaultAppMain(MadeiraApp.self) } }
        }
        runDefaultAppMain(MadeiraApp.self)
    }

    @UIApplicationDelegateAdaptor(MadeiraAppDelegate.self) private var appDelegate

    init() {
        // (kill-list) switches the team turned off for this build, from the signed kept file; before anything reads a switch.
        KillList.apply()
        // [main-stack-move] crash guard (JITAllocator.c): still alive a few seconds after opening, so the
        // next start may move the stack again. Logs what the move did when it was asked for.
        let msmNote = String(cString: madeira_stack_move_note())
        if msmNote != "off" { LogStore.shared.log("[main-stack-move] \(msmNote)", level: msmNote.hasPrefix("moved") ? .success : .error) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { madeira_stack_move_survived() }
        // A TV or AirPlay screen: watch its scene directly (MadeiraApp.swift ExternalDisplay).
        ExternalDisplay.watch()
        // Opt-in iPhone pointer experiments (PhonePointer.m): before any scene exists.
        madeira_phone_pointer_setup()
        // madeira-bcd: the Metal Performance HUD's performance insights (the
        // notes that stack up left of its panel: shader compiles, similar render
        // passes, blit encoders) cover the game. Off unless madeira.cfg says
        // env.MTL_HUD_INSIGHTS_ENABLED = 1, which is exported later and wins.
        setenv("MTL_HUD_INSIGHTS_ENABLED", "0", 0)
        // Host pads as Windows.Gaming.Input gamepads (upstream's opt-in provider, willfaust/wine #40):
        // on by default here; madeira.cfg env.MADEIRA_WGI_HOST_PADS = 0 is exported later and wins.
        setenv("MADEIRA_WGI_HOST_PADS", "1", 0)
        // ml1172: read the screen on the main thread; library entries, whose
        // default Resolution comes from it, are also made on other threads.
        _ = ResolutionChoices.screen
        // A sign-in an installer left goes into the Keychain before anything else runs
        // (SigningRefresh.swift), only while the refresh is switched on.
        if SigningRefresh.enabled { SigningAccountStore.takeIn() }
        // Use one profile before Wine or Steam Cloud reads the prefix.
        ProfileUnification.run()
        // Games and downloads keep going when Madeira leaves the screen (BackgroundRun.swift).
        BackgroundRun.shared.start()
        // Read the cached library before the first grid page is built.
        if LibraryGridArm.enabled, SteamOwnedLibrary.enabled { SteamOwnedLibrary.shared.start() }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .background(InteractionFrameRateInstaller())   // touch frame-rate request (New library grid)
                .modifier(ClaimGamepadEvents())
                .modifier(FoldableFillsWindow())   // iPhone Duo: no dead column beside the library
                .onAppear {
                    ExternalDrives.shared.mountAll()
                    GamepadInput.shared.start()
                    HardwareInput.shared.start()
                    JITNetworkShortcut.shared.restoreLeftover()   // also starts its network path monitor
                    WineGeckoModel.shared.installAutomatically()  // on Wi-Fi, so Wine never asks (WineGecko.swift)
                    AchievementWatcher.shared.start()             // unlock banners from Steam's stats files (SteamAchievements.swift)
                    ClaudeHelp.install()                          // the fixes guide beside madeira-log.txt (ClaudeHelp.swift)
                    LogTrail.install()                            // presses, focus, screens, taps, start steps (LogTrail.swift)
                    CrashReports.start()                          // crashes, freezes and own errors go to the team (CrashReports.swift)
                    GetHelpUpload.resendLate()                    // (late-zip) Get Help zips Madeira closed before sending (GetHelpView.swift)
                    SharedConfigs.refresh()                       // (shared-configs) approved settings from other players (SharedConfigs.swift)
                    RemoteRecs.refresh()                          // (remote-recs) newest game lists from the Get Help server (RemoteRecs.swift)
                    KillList.refresh()                            // (kill-list) newest signed list of switches to keep off (KillList.swift)
                }
                // madeira://jit-network/... (the Madeira JIT shortcut returning, JITNetwork.swift),
                // else a shared game setup (a .madeirasetup file or madeira://setup?d=..., GameSetupShare.swift),
                // else madeira://play?exe=... (Home Screen shortcuts, SavesAndShortcuts.swift).
                .onOpenURL { url in
                    if JITNetworkShortcut.shared.handle(url) || GameSetupInbox.shared.handle(url) { return }
                    ShortcutRouter.shared.handle(url)
                }
        }
    }
}

/// iPhone Duo (iPhone19,4), unfolded: iOS reports an 84 pt safe-area column on the
/// right of the window. ContentView stopped at it, so the column lay outside the
/// view that claims game-controller events (ClaimGamepadEvents) and taps and the
/// pad did nothing in the library there. The whole window is given to the app on
/// that model, as upstream Madeira does (willfaust/Madeira pull request 624 by
/// Lee Simpson; this is that modifier). Every other model is left exactly as it
/// was. env.MADEIRA_DUO_FILL_WINDOW=0 in madeira.cfg turns it off.
struct FoldableFillsWindow: ViewModifier {
    static let models: Set<String> = ["iPhone19,4"]
    static let active: Bool = {
        guard MadeiraConfig.flag("MADEIRA_DUO_FILL_WINDOW") else { return false }
        let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
        return models.contains(simulated ?? DeviceDiagnostics.machine())
    }()

    func body(content: Content) -> some View {
        if Self.active { content.ignoresSafeArea() } else { content }
    }
}

// MARK: External display (AirPlay, HDMI / USB-C)

/// Without an external-display scene iOS only mirrors the phone, and the game's
/// presenting layer (MetalHostView, a window-level CAMetalLayer view) did not
/// come through mirroring: the TV stayed black or the game did not fill it.
/// `env.MADEIRA_EXTERNAL_DISPLAY_FIX = 0` (madeira.cfg or the environment) goes
/// back to plain mirroring. On by default.
enum ExternalDisplay {
    static var enabled: Bool { MadeiraConfig.flag("MADEIRA_EXTERNAL_DISPLAY_FIX") }
    /// A second screen holds the game's view; the phone's layout must leave it be.
    @MainActor static var active = false
    @MainActor private static var window: UIWindow?

    /// Scene notices reach us whether or not iOS used ExternalDisplaySceneDelegate,
    /// and a scene-based app never gets applicationDidBecomeActive.
    static func watch() {
        guard enabled else { return }
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIScreen.didConnectNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { LogStore.shared.log("[display] screen plugged in: screens \(UIScreen.screens.count), scenes \(UIApplication.shared.connectedScenes.map { $0.session.role.rawValue })") }
        }
        nc.addObserver(forName: UIScene.willConnectNotification, object: nil, queue: .main) { n in
            MainActor.assumeIsolated {
                guard let ws = n.object as? UIWindowScene, ws.session.role == .windowExternalDisplayNonInteractive else { return }
                LogStore.shared.log("[display] external scene notice: connecting")
                connect(ws)
            }
        }
        nc.addObserver(forName: UIScene.didActivateNotification, object: nil, queue: .main) { n in
            MainActor.assumeIsolated {
                adoptExisting()
                if let ws = n.object as? UIWindowScene, ws.session.role == .windowApplication { registerAccessory(in: ws) }
            }
        }
        nc.addObserver(forName: UIScene.didDisconnectNotification, object: nil, queue: .main) { n in
            MainActor.assumeIsolated {
                guard let ws = n.object as? UIWindowScene, ws.session.role == .windowExternalDisplayNonInteractive else { return }
                disconnect()
            }
        }
    }

    /// iOS 27 offers the external-display scene only to an app that registered a scene
    /// accessory on a presented view controller (the Info.plist manifest and
    /// configurationForConnecting no longer trigger it). The registration must stay alive.
    @MainActor private static var registration: AnyObject?

    @MainActor static func registerAccessory(in scene: UIWindowScene) {
        guard enabled, registration == nil else { return }
        guard #available(iOS 27.0, *) else {
            LogStore.shared.log("[display] TV accessory not registered: iOS below 27")
            return
        }
        guard let vc = scene.keyWindow?.rootViewController else {
            LogStore.shared.log("[display] TV accessory not registered: no root view controller yet")
            return
        }
        let cfg = UISceneConfiguration(name: "External Display", sessionRole: .windowExternalDisplayNonInteractive)
        cfg.delegateClass = ExternalDisplaySceneDelegate.self
        registration = vc.registerSceneAccessory(UISceneAccessory.externalNonInteractive(sceneConfiguration: cfg))
        LogStore.shared.log("[display] TV accessory registered (iOS 27)")
    }

    /// An external-display scene that connected before the delegate handled it.
    @MainActor static func adoptExisting() {
        guard enabled, !active else { return }
        let found = UIApplication.shared.connectedScenes.first { $0.session.role == .windowExternalDisplayNonInteractive }
        LogStore.shared.log("[display] scenes at activation: \(UIApplication.shared.connectedScenes.count), external: \(found == nil ? "none" : "yes")")
        if let ws = found as? UIWindowScene { connect(ws) }
    }

    @MainActor static func connect(_ scene: UIWindowScene) {
        guard !active else { return }
        let w = UIWindow(windowScene: scene)
        w.backgroundColor = .black
        w.rootViewController = ExternalDisplayController()
        w.isHidden = false
        window = w
        active = true
        LogStore.shared.log("[display] external screen connected \(Int(scene.screen.bounds.width))x\(Int(scene.screen.bounds.height)): game view moved there")
        logLatencyFacts(scene, why: "connected")
        // Again once the game view has been laid out there and sound has settled on its output.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak scene] in
            MainActor.assumeIsolated {
                guard active, let scene else { return }
                logLatencyFacts(scene, why: "5 s later")
            }
        }
    }

    /// Log only (tv-lag): what iOS says about the second screen and where sound
    /// goes, so a report of slow controls on a TV shows whether the picture
    /// travels by cable or by AirPlay, the TV's own delay as iOS knows it, and
    /// the refresh rate the game view is drawn at. Changes nothing.
    /// env.MADEIRA_TV_LAG_LOG=0 in madeira.cfg turns the lines off.
    @MainActor static func logLatencyFacts(_ scene: UIWindowScene, why: String) {
        guard MadeiraConfig.flag("MADEIRA_TV_LAG_LOG") else { return }
        let screen = scene.screen
        let mode = screen.currentMode?.size ?? .zero
        let best = screen.preferredMode?.size ?? .zero
        let session = AVAudioSession.sharedInstance()
        let ports: String = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        let host = MetalHostView.shared
        let drawable: CGSize = host.metalLayer.drawableSize
        let onSecond: String = host.window?.windowScene === scene ? "yes" : "not yet"
        let scale: Double = Double(screen.scale)
        let fps: Int = screen.maximumFramesPerSecond
        let screenMs: Double = screen.calibratedLatency * 1000
        let soundMs: Double = session.outputLatency * 1000
        let format = "[tv-lag] %@: screen mode %dx%d (best %dx%d) scale %.1f, up to %d fps, screen delay iOS reports %.0f ms (0 = unknown or none), sound out [%@] delay %.0f ms, game layer %dx%d on the second screen %@"
        LogStore.shared.log(String(format: format, why, Int(mode.width), Int(mode.height), Int(best.width), Int(best.height),
                                   scale, fps, screenMs, ports, soundMs, Int(drawable.width), Int(drawable.height), onSecond))
    }

    @MainActor static func disconnect() {
        guard active else { return }
        active = false
        window = nil
        let host = MetalHostView.shared
        host.removeFromSuperview()
        if let phone = MetalBackedView.keyboardTarget?.window {
            phone.addSubview(host)
            winios_compositor_set_host(Unmanaged.passUnretained(phone).toOpaque(), 0)   // desktop/Dock sessions
        }
        MetalBackedView.refreshDisplayMode(reason: "external-gone")
        LogStore.shared.log("[display] external screen gone: game view back on the phone")
    }
}

/// Black screen holding the game's view, shaped like the guest display (Fit).
final class ExternalDisplayController: UIViewController {
    override func viewDidLoad() { view.backgroundColor = .black }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let host = MetalHostView.shared
        if host.superview !== view { host.removeFromSuperview(); view.addSubview(host) }
        var gw: Int32 = 0, gh: Int32 = 0
        winios_screen_size(&gw, &gh)
        host.frame = GameSurfaceLayout.rect(guest: CGSize(width: CGFloat(gw), height: CGFloat(gh)),
                                            bounds: view.bounds, mode: .fit)
        // Steam/Dock and desktop sessions draw through the winios compositor, not this host view.
        winios_compositor_set_host(Unmanaged.passUnretained(view).toOpaque(), 1)
    }
}

@objc(ExternalDisplaySceneDelegate)   // the name Info.plist's UIApplicationSceneManifest uses
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        Task { @MainActor in ExternalDisplay.connect(ws) }
    }
    func sceneDidDisconnect(_ scene: UIScene) {
        Task { @MainActor in ExternalDisplay.disconnect() }
    }
}

final class MadeiraAppDelegate: NSObject, UIApplicationDelegate {
    // (landscape-on-start) Which orientations the app allows right now: all, or landscape only while a game runs.
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        GameOrientation.mask
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let external = connectingSceneSession.role == .windowExternalDisplayNonInteractive
        LogStore.shared.log("[display] scene asked for: role \(connectingSceneSession.role.rawValue), fix \(ExternalDisplay.enabled ? "on" : "off")")
        let config = UISceneConfiguration(name: external ? "External Display" : nil, sessionRole: connectingSceneSession.role)
        if external, ExternalDisplay.enabled {
            config.delegateClass = ExternalDisplaySceneDelegate.self
        }
        return config
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        ExternalDisplay.adoptExisting()
    }
}

extension UIApplication {
    /// The phone's own scenes: an external-display scene is not a place for
    /// the controls, banners or overlays that look for "the" scene.
    var phoneScenes: [UIScene] {
        connectedScenes.filter { $0.session.role != .windowExternalDisplayNonInteractive }
    }
}

// MARK: Landscape on game start

/// (landscape-on-start) A game can switch the phone to landscape when it starts, and the
/// phone goes back to turning freely when the game ends. The app asks iOS for the rotation
/// (the supported-orientations mask plus a geometry update), which iOS honours even with the
/// Portrait Orientation Lock on; iOS never rotates an app that does not ask.
/// Settings: app-wide `madeira.landscapeOnStart` (Settings › Appearance › In games), and a
/// per-game choice in Game details › Display (`LibraryEntry.landscape`: "on", "off", nil =
/// follow the app-wide setting). `env.MADEIRA_LANDSCAPE_ON_START = 0` turns the feature off.
enum GameOrientation {
    static let key = "madeira.landscapeOnStart"
    static var enabled: Bool { MadeiraConfig.flag("MADEIRA_LANDSCAPE_ON_START") }
    static var appWide: Bool { UserDefaults.standard.bool(forKey: key) }
    /// Read by MadeiraAppDelegate on every rotation decision.
    nonisolated(unsafe) static var mask: UIInterfaceOrientationMask = .allButUpsideDown

    /// A game's choice: "on", "off", or nil for the app-wide setting.
    static func wanted(perGame: String?) -> Bool {
        guard enabled else { return false }
        switch perGame {
        case "on": return true
        case "off": return false
        default: return appWide
        }
    }

    @MainActor static func gameStarted(perGame: String?) {
        guard wanted(perGame: perGame) else { return }
        mask = .landscape
        apply(.landscape)
        fputs("[orientation] landscape for this game (\(perGame ?? "app setting"))\n", stderr)
    }

    @MainActor static func gameEnded() {
        guard mask != .allButUpsideDown else { return }
        mask = .allButUpsideDown
        apply(.allButUpsideDown)
    }

    @MainActor private static func apply(_ target: UIInterfaceOrientationMask) {
        for scene in UIApplication.shared.phoneScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            ws.windows.first(where: \.isKeyWindow)?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            // Landscape: rotate now. Back to free: no rotation asked, the phone turns as held.
            guard target == .landscape else { continue }
            ws.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { error in
                fputs("[orientation] rotation not done: \(error.localizedDescription)\n", stderr)
            }
        }
    }
}
