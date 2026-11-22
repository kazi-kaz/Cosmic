#!/usr/bin/env python3
"""(shared-configs) SharedConfigs.swift: approved settings other players said work.

Checks without a compiler: the file is in the Xcode project, its switch is in the
catalog, the start-up refresh and the GameRecommendations hook are there, and the
public key is empty (off) or 32 bytes of base64. With swiftc (--require-swift on the
PC or macOS CI): the game key matches the server's (results.ts gameKey), files with
unsafe lines or another format are refused, the recommendation text keeps the
standard list first, and (with CryptoKit) only the server's signature passes."""
import argparse, base64, os, re, shutil, subprocess, sys, tempfile
from pathlib import Path

ap = argparse.ArgumentParser(); ap.add_argument('--require-swift', action='store_true'); args = ap.parse_args()
R = Path(__file__).resolve().parents[2]
app = R / 'app' / 'Madeira'
src = (app / 'SharedConfigs.swift').read_text()
fails = 0
def check(ok, what):
    global fails
    print(('ok   ' if ok else 'FAIL ') + what)
    fails += 0 if ok else 1

pbx = (R / 'app' / 'Madeira.xcodeproj' / 'project.pbxproj').read_text()
gen = (app / 'ConfigCatalog.generated.swift').read_text()
check(pbx.count('SharedConfigs.swift') == pbx.count('SharedConfigsView.swift') == pbx.count('GetHelp.swift') == 6,
      'SharedConfigs.swift and SharedConfigsView.swift are in the Xcode project (file, build file, group, sources)')
view = (app / 'SharedConfigsView.swift').read_text()
check('.modifier(SharedConfigsNotice())' in (app / 'Library.swift').read_text(), 'the library asks Keep or Undo')
check('Button("Undo") { finish(undo: true) }' in view and 'GameRecommendations.undoShared(windowsPath: a.windowsPath' in view,
      'Undo puts the standard list back')
check('model.current == nil' in view and 'help.open == nil' in view, 'the question waits until no game or Get Help is showing')
check('if kind != .reset, SharedConfigs.isShared(rec) { SharedConfigs.applied(' in (app / 'GameRecommendationsApply.swift').read_text(),
      'only a shared list written by itself asks (not Reset to Recommended)')
check('"title": "Shared settings from other players"' in (R / 'build' / 'tools' / 'gen-config-catalog.py').read_text()
      and 'title: "Shared settings from other players"' in gen, 'Settings › All settings has the switch with its title')
gen = (app / 'ConfigCatalog.generated.swift').read_text()
check('key: "env.MADEIRA_SHARED_CONFIGS"' in gen, 'env.MADEIRA_SHARED_CONFIGS is in the settings catalog')
check('MadeiraConfig.flag("MADEIRA_SHARED_CONFIGS")' in src, 'the switch is read with MadeiraConfig.flag (default on)')
check('SharedConfigs.refresh()' in (app / 'MadeiraApp.swift').read_text(), 'refresh at start-up')
apply_src = (app / 'GameRecommendationsApply.swift').read_text()
check('if rec?.id == standard.id, let shared = SharedConfigs.recommendation(title: entry.title) { return shared }' in apply_src,
      'only a game with the standard list takes a shared one')
check('appendingPathComponent("shared/configs")' in src and '"x-madeira-signature"' in src, 'GET /shared/configs with its signature header')
check('verify(data, signature: sig), let configs = parse(data)' in src, 'a download is kept only when its signature checks')
check('if verify(data, signature: sig) { found = parse(data) }' in src, 'the kept file is checked again when read')
check('infoDictionary?["MadeiraSharedConfigsKey"]' in src and 'Data(base64Encoded: key)?.count == 32' in src,
      'the public key comes from the build\'s Info.plist (MadeiraSharedConfigsKey), only a 32-byte key counts')
check(not re.search(r'MadeiraSharedConfigsKey</key>\s*<string>', (app / 'Info.plist').read_text()) if (app / 'Info.plist').exists() else True,
      'no key committed in Info.plist (the build script adds it)')

stubs = r'''import Foundation
enum MadeiraConfig { static func flag(_ name: String, fallback: Bool = true) -> Bool { true } }
final class LogStore { static let shared = LogStore(); enum Level { case info, error }; func log(_ m: String, level: Level = .info) {} }
enum GetHelp { static let enabled = true; static var key: String? { nil } }
enum GetHelpCore { static let server = URL(string: "https://example.invalid")! }
struct GameRecommendation: Equatable { let id: String; let title: String; let version: Int; let config: String }
enum GameRecommendations { static let standard = GameRecommendation(id: "standard", title: "s", version: 3, config: "env.MADEIRA_EC_HOOK_TRACE = 0") }
'''
main = r'''import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif
var bad = 0
func check(_ ok: Bool, _ what: String) { print((ok ? "ok   " : "FAIL ") + what); if !ok { bad += 1 } }
let S = SharedConfigs.self
// Expected values from the server's own gameKey (node, results.ts).
let keys: [(String, String)] = [("Red Dead Redemption 2", "red-dead-redemption-2"), ("  Slay the Spire 2 ", "slay-the-spire-2"),
    ("Ratchet & Clank - Rift Apart", "ratchet-clank-rift-apart"), ("Pokémon-Like!!", "pok-mon-like"), ("---", "unknown"),
    ("Final Fantasy VII: Remake Intergrade", "final-fantasy-vii-remake-intergrade"),
    (String(repeating: "A", count: 70) + " b", String(repeating: "a", count: 60))]
for (t, k) in keys { check(S.gameKey(t) == k, "game key of \(t.prefix(30)) is \(k.prefix(30))") }
let good = #"{"format":1,"made":"x","configs":[{"game":"Shared Game","game_key":"shared-game","lines":[{"key":"pool","value":"512"},{"key":"env.MADEIRA_X","value":"1"}]}]}"#
let cfgs = S.parse(Data(good.utf8))
check(cfgs?["shared-game"]?.lines.count == 2, "a good file parses")
check(S.parse(Data(good.replacingOccurrences(of: #""format":1"#, with: #""format":2"#).utf8)) == nil, "another format is refused")
let nl = good.replacingOccurrences(of: #""value":"512""#, with: #""value":"512\nexe = x""#)
check(S.parse(Data(nl.utf8))?["shared-game"] == nil, "a value with a new line drops that game")
let badKey = good.replacingOccurrences(of: #""key":"pool""#, with: #""key":"po ol""#)
check(S.parse(Data(badKey.utf8))?["shared-game"] == nil, "a key with a space drops that game")
let rec = S.recommendation(title: "Shared Game", configs: cfgs, standard: GameRecommendations.standard)
check(rec?.id == "shared-shared-game" && S.isShared(rec), "recommendation id")
check(rec?.config.hasPrefix(GameRecommendations.standard.config + "\n# Shared settings") == true
      && rec?.config.hasSuffix("pool = 512\nenv.MADEIRA_X = 1") == true, "standard list first, then the shared lines")
check(S.recommendation(title: "Other Game", configs: cfgs, standard: GameRecommendations.standard) == nil, "no list for another game")
check(S.configs() == nil, "no public key: off")
S.applied(title: "A", windowsPath: "C:\\a.exe"); S.applied(title: "A", windowsPath: "C:\\a.exe"); S.applied(title: "B", windowsPath: "C:\\b.exe")
check(S.nextPending?.title == "A", "Keep or Undo: first game first, once")
S.answered(S.nextPending!)
check(S.nextPending?.title == "B", "then the next one")
S.answered(S.nextPending!)
check(S.nextPending == nil, "none left")
#if canImport(CryptoKit)
let priv = Curve25519.Signing.PrivateKey()
let pub = priv.publicKey.rawRepresentation.base64EncodedString()
let data = Data(good.utf8)
let sig = try! priv.signature(for: data).base64EncodedString()
check(S.verify(data, signature: sig, key: pub), "the server's signature passes")
check(!S.verify(Data(good.replacingOccurrences(of: "512", with: "999").utf8), signature: sig, key: pub), "a changed file fails")
check(!S.verify(data, signature: sig, key: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()), "another key fails")
#else
print("SKIP: CryptoKit unavailable; signature checks run on macOS")
check(!S.verify(Data(), signature: "", key: ""), "without CryptoKit nothing passes")
#endif
if bad > 0 { print("FAILED \(bad)"); exit(1) }
print("PASS: shared configs core")
'''
compiler = shutil.which('swiftc')
if compiler:
    with tempfile.TemporaryDirectory(prefix='madeira-shared-') as d:
        t = Path(d); (t / 'Stubs.swift').write_text(stubs); (t / 'main.swift').write_text(main)
        r = subprocess.run([compiler, str(app / 'SharedConfigs.swift'), str(t / 'Stubs.swift'), str(t / 'main.swift'), '-o', str(t / 'shared')])
        check(r.returncode == 0, 'SharedConfigs.swift compiles')
        if r.returncode == 0:
            check(subprocess.run([str(t / 'shared')]).returncode == 0, 'Swift checks pass')
elif args.require_swift:
    raise SystemExit('Swift compiler required for check-shared-configs')
else:
    print('SKIP: Swift compiler unavailable locally; run with --require-swift on the PC or macOS CI')
if fails:
    print('FAILED'); sys.exit(1)
print('PASS')
