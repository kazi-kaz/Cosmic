#!/usr/bin/env python3
"""(remote-recs) RemoteRecs.swift host check. Run from a source tree that has the wiring patch applied
(copy this file to tests/host/, RemoteRecs.swift to app/Madeira/). Static checks always; with swiftc
(--require-swift on the PC or macOS) it compiles RemoteRecs.swift against small stubs and tests parse,
replacement rules and the refusal cases."""
import argparse, shutil, subprocess, sys, tempfile
from pathlib import Path
ap = argparse.ArgumentParser(); ap.add_argument('--require-swift', action='store_true'); args = ap.parse_args()
R = Path(__file__).resolve().parents[2]; app = R / 'app' / 'Madeira'
src = (app / 'RemoteRecs.swift').read_text(); fails = 0
def check(ok, what):
    global fails
    print(('ok   ' if ok else 'FAIL ') + what); fails += 0 if ok else 1
apply_src = (app / 'GameRecommendationsApply.swift').read_text()
check('RemoteRecs.replacement(base: base, steamAppID: steamAppID) ?? base' in apply_src, 'the recommendation lookup asks RemoteRecs')
check('RemoteRecs.refresh()' in (app / 'MadeiraApp.swift').read_text(), 'refresh at start-up')
check('MadeiraConfig.flag("MADEIRA_REMOTE_RECS")' in src, 'off switch read with MadeiraConfig.flag (default on)')
check('"env.MADEIRA_REMOTE_RECS"' in (R / 'build' / 'tools' / 'gen-config-catalog.py').read_text(), 'switch is in the catalog generator')
check('SharedConfigs.verify(data, signature: sig)' in src and 'new.made < kept.made' in src, 'signature checked; an older file is refused')
check('RemoteRecs.swift' in (R / 'app' / 'Madeira.xcodeproj' / 'project.pbxproj').read_text(), 'RemoteRecs.swift is in the Xcode project')
swiftc = shutil.which('swiftc')
if not swiftc:
    print('SKIP swift part (no swiftc)'); sys.exit(1 if fails or args.require_swift else 0)
stubs = r'''import Foundation
enum MadeiraConfig { static func flag(_ n: String, fallback: Bool = true) -> Bool { true } }
final class LogStore { static let shared = LogStore(); enum Level { case info, error }; func log(_ m: String, level: Level = .info) {} }
enum GetHelp { static let enabled = true; static var key: String? { nil } }
enum GetHelpCore { static let server = URL(string: "https://example.invalid")! }
enum SharedConfigs {
  struct Line: Codable, Equatable { let key: String; let value: String }
  static let publicKey = ""
  static func verify(_ d: Data, signature: String) -> Bool { false }
  static func safe(_ l: Line) -> Bool { !l.key.isEmpty && !l.value.isEmpty && !l.value.contains("\n") && !l.key.contains(" ") }
}
struct GameRecommendation: Equatable { let id: String; let title: String; let version: Int; let config: String
  var avx: Bool? = nil; var nvidia: Bool? = nil; var olderNvidia: Bool? = nil; var wineVCRT: Bool? = nil; var fastSync: Bool? = nil
  var semaphoreFastPath: Bool? = nil; var fpsMode: Int? = nil; var smallRAMConfig: String? = nil
  var resolution: String? = nil; var display: String? = nil; var launchMode: String? = nil; var startServices: Bool? = nil }
enum GameRecommendations { static let standard = GameRecommendation(id: "standard", title: "s", version: 1, config: "a = 1") }
'''
main = r'''import Foundation
var bad = 0
func check(_ ok: Bool, _ w: String) { print((ok ? "ok   " : "FAIL ") + w); if !ok { bad += 1 } }
func file(_ recs: String, made: String = "2026-11-17T17:00:00.000Z", kind: String = "recs", format: Int = 1) -> Data {
  Data(#"{"format":\#(format),"kind":"\#(kind)","made":"\#(made)","recs":[\#(recs)]}"#.utf8) }
let a = #"{"id":"fnv","title":"Fallout NV","version":9,"lines":[{"key":"pool","value":"512"}],"reason":"r","fps_mode":3,"avx":false}"#
let n = #"{"id":"remote-x","title":"New Game","version":1,"app_ids":[123],"lines":[{"key":"pool","value":"256"}],"reason":"r"}"#
let p = RemoteRecs.parse(file(a + "," + n))
check(p?.recs.count == 2, "good file parses")
check(RemoteRecs.parse(file(a, format: 2)) == nil, "other format refused")
check(RemoteRecs.parse(file(a, kind: "killlist")) == nil, "other kind refused")
check(RemoteRecs.parse(file(a, made: "yesterday")) == nil, "bad made refused")
check(RemoteRecs.parse(file(a + "," + a)) == nil, "repeated id refuses the file")
check(RemoteRecs.parse(file(a.replacingOccurrences(of: "512", with: "5\\n12"))) == nil, "newline in a value refuses the file")
check(RemoteRecs.parse(file(a.replacingOccurrences(of: #""avx":false"#, with: #""fps_mode":9"#).replacingOccurrences(of: #""fps_mode":3,"#, with: ""))) == nil, "bad fps mode refused")
check(RemoteRecs.parse(file(n.replacingOccurrences(of: #""app_ids":[123],"#, with: ""))) == nil, "remote- without app_ids refused")
check(RemoteRecs.parse(file(a.replacingOccurrences(of: #""id":"fnv""#, with: #""id":"fnv","app_ids":[1]"#))) == nil, "app_ids on a built-in id refused")
let recs = p!.recs
let std = GameRecommendations.standard.id
let builtOld = GameRecommendation(id: "fnv", title: "Fallout NV", version: 5, config: "old = 1")
let r1 = RemoteRecs.replacement(base: builtOld, steamAppID: nil, in: recs, standardID: std)
check(r1?.version == 9 && r1?.config == "pool = 512" && r1?.fpsMode == 3 && r1?.avx == false, "newer remote list replaces the built-in one")
let builtNew = GameRecommendation(id: "fnv", title: "Fallout NV", version: 9, config: "new = 1")
check(RemoteRecs.replacement(base: builtNew, steamAppID: nil, in: recs, standardID: std) == nil, "equal version: built-in wins")
check(RemoteRecs.replacement(base: GameRecommendation(id: "fnv", title: "x", version: 12, config: "z"), steamAppID: nil, in: recs, standardID: std) == nil, "built-in newer: built-in wins")
var rich = builtOld; rich.smallRAMConfig = "swap = 1"; rich.resolution = "1280x720"; rich.nvidia = true; rich.avx = true
let r2 = RemoteRecs.replacement(base: rich, steamAppID: nil, in: recs, standardID: std)
check(r2?.smallRAMConfig == "swap = 1" && r2?.resolution == "1280x720" && r2?.nvidia == true && r2?.avx == false, "unsaid fields stay from the built-in list; said ones change")
let st = GameRecommendations.standard
check(RemoteRecs.replacement(base: st, steamAppID: 123, in: recs, standardID: std)?.config == "a = 1\npool = 256", "a remote- list keeps the standard lines first")
check(RemoteRecs.replacement(base: st, steamAppID: 123, in: recs, standardID: std)?.id == "remote-x", "standard-list game with a remote list takes it")
check(RemoteRecs.replacement(base: st, steamAppID: 999, in: recs, standardID: std) == nil, "other game keeps the standard list")
check(RemoteRecs.replacement(base: builtOld, steamAppID: 123, in: recs, standardID: std)?.id == "fnv", "a built-in list for the game beats a remote- app id list")
check(RemoteRecs.replacement(base: nil, steamAppID: nil, in: recs, standardID: std) == nil, "no base and no app id: nothing")
check(RemoteRecs.replacement(base: builtOld, steamAppID: nil, in: nil, standardID: std) == nil, "no file: nothing")
exit(bad == 0 ? 0 : 1)
'''
d = Path(tempfile.mkdtemp())
(d / 'stubs.swift').write_text(stubs); (d / 'main.swift').write_text(main)
r = subprocess.run([swiftc, '-parse-as-library' if False else '-O', str(d / 'stubs.swift'), str(app / 'RemoteRecs.swift'), str(d / 'main.swift'), '-o', str(d / 't')], capture_output=True, text=True)
if r.returncode: print(r.stdout + r.stderr); sys.exit(1)
r = subprocess.run([str(d / 't')], capture_output=True, text=True); print(r.stdout, end='')
sys.exit(1 if fails or r.returncode else 0)
