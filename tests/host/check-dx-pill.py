#!/usr/bin/env python3
"""(dx-pill) The DirectX pill shows the DirectX DLLs Wine loaded in a game's last run.

Compiles the app's own DirectXPill.swift (Foundation only) with swiftc and runs it on
made-up log text: exact names only (d3d9-emulated, dxgi, d3dx9_43, d3dcompiler_47 do not
count), any case, every API found, lowest first, a run with none gives no pill, the scan
starts at the run's offset and reads a rotated (shorter) log from its start. Also checks
the source: env.MADEIRA_DX_PILL gates the pill and both the start and end hooks, the file
is in the Xcode project. Without swiftc only the source checks run.

Optional: pass real log files to print what the pill would say for each.
"""
from pathlib import Path
import shutil, subprocess, sys, tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
src = app / 'DirectXPill.swift'
lib = (app / 'Library.swift').read_text(encoding='utf-8')
proj = (root / 'app/Madeira.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
failures = 0


def check(condition, label):
    global failures
    print(('PASS ' if condition else 'FAIL ') + label)
    if not condition:
        failures += 1


check(proj.count('DirectXPill.swift') == 6 and proj.count('A1000D71 /* DirectXPill.swift in Sources */') == 2,'DirectXPill.swift is in the Xcode project (file, build file, group, sources)')
check('static let enabled = MadeiraConfig.flag("MADEIRA_DX_PILL")' in lib, 'env.MADEIRA_DX_PILL is the switch, on by default')
check('if DirectXPill.enabled, let dx = entry.loadedDirectX { texts.append(dx) }' in lib, 'the pill shows only with the switch on and a stored value')
check('if DirectXPill.enabled { dxLogStart = DirectXPill.logSize() }' in lib, 'the run start offset is taken only with the switch on')
check('if DirectXPill.enabled, let id = current { noteDirectX(id, from: dxLogStart) }' in lib, 'the end-of-run scan runs only with the switch on')
check('entry.loadedDirectX = next[i].loadedDirectX' in lib, 'an older copy of an entry never overwrites the stored value')
share = (app / 'GameSetupShare.swift').read_text(encoding='utf-8')
check('"loadedDirectX",' in share.split('static let localKeys')[1].split(']')[0],
      'a shared setup leaves out this device\'s DirectX pill (GameSetup.localKeys)')
check('graphicsAPI' not in lib.split('static func formatTexts')[1].split('static func sizeText')[0],
      'no pill is read from the program (graphicsAPI) again')

MAIN = r'''
import Foundation
let args = CommandLine.arguments
if args.count > 2, args[1] == "--files" {
    for p in args[2...] { print("FILE \(p) => \(DirectXPill.scan(URL(fileURLWithPath: p), from: 0) ?? "(no pill)")") }
    exit(0)
}
func t(_ s: String) -> String { DirectXPill.text(DirectXPill.ranks(in: s)) ?? "nil" }
print("A " + t("D 130 Load module d3d9.dll (d3d9.dll-23c8601a8ec1e345): 7276FD0000\nD 130 Load module d3d9-emulated.dll (x): 1\n"))
print("B " + t("D 38 Load module DXGI.dll (dxgi.dll-x): 1\nD 1 Load module d3dx9_43.dll (x): 1\nD 1 Load module d3dcompiler_47.dll (x): 1\nD 1 Load module d3d10core.dll (x): 1\nD 1 Load module d3d11on12.dll (x): 1\nD 1 Load module opengl32.dll (x): 1"))
print("C " + t("D 1 LOAD MODULE D3D12.DLL (x): 1\nD 1 load module d3d11.dll (x): 1"))
print("D " + t("D 2 Load module ddraw.dll (x): 1\nD 2 Load module d3d9.dll (x): 1\nD 2 Load module d3d8.dll (x): 1\nD 2 Load module d3d10_1.dll (x): 1\nD 2 Load module d3d10.dll (x): 1"))
print("E " + t("D 3 Load module d3d9.dll"))
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dxpill-\(getpid())")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let f = dir.appendingPathComponent("log.txt")
var big = "D 1 Load module d3d11.dll (x): 1\n"
let start = UInt64(big.utf8.count)
for i in 0..<60000 { big += "[00:00:00.000] [INFO] filler line \(i) xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n" }
big += "D 9 Load module d3d9.dll (d3d9.dll-1): 2\n"
try! big.write(to: f, atomically: true, encoding: .utf8)
print("F " + (DirectXPill.scan(f, from: start) ?? "nil"))
print("G " + (DirectXPill.scan(f, from: 0) ?? "nil"))
print("H " + (DirectXPill.scan(f, from: UInt64(big.utf8.count) + 100) ?? "nil"))
try! "nothing here\n".write(to: f, atomically: true, encoding: .utf8)
print("I " + (DirectXPill.scan(f, from: 0) ?? "nil"))
print("J " + (DirectXPill.scan(dir.appendingPathComponent("missing.txt"), from: 0) ?? "nil"))
try? FileManager.default.removeItem(at: dir)
'''
WANT = {'A': 'DX9', 'B': 'nil', 'C': 'DX11 + DX12', 'D': 'DDraw + DX8 + DX9 + DX10', 'E': 'DX9',
        'F': 'DX9', 'G': 'DX9 + DX11', 'H': 'DX9 + DX11', 'I': 'nil', 'J': 'nil'}
LABEL = {'A': 'd3d9 counts, d3d9-emulated does not', 'B': 'dxgi, d3dx9, d3dcompiler, d3d10core, d3d11on12, opengl32 give no pill',
         'C': 'any case; every API found, lowest first', 'D': 'DDraw, DX8, DX9 and d3d10/d3d10_1 as one DX10',
         'E': 'a last line without a line end counts', 'F': 'the scan starts at the run offset (an earlier run\'s d3d11 is left out)',
         'G': 'a 3+ MB log read in pieces finds lines in its first and last piece',
         'H': 'a log shorter than the offset (rotated) is read from its start', 'I': 'a run with no DirectX DLL gives no pill (old value kept)',
         'J': 'a missing log gives no pill'}

swiftc = shutil.which('swiftc')
if not swiftc:
    print('SKIP swiftc not found: parser not run')
else:
    with tempfile.TemporaryDirectory() as tmp:
        main = Path(tmp) / 'main.swift'
        main.write_text(MAIN, encoding='utf-8')
        exe = Path(tmp) / 'dxpill'
        r = subprocess.run([swiftc, '-O', str(src), str(main), '-o', str(exe)], capture_output=True, text=True)
        check(r.returncode == 0, 'DirectXPill.swift compiles' + ('' if r.returncode == 0 else ': ' + r.stderr[-600:]))
        if r.returncode == 0:
            out = subprocess.run([str(exe)], capture_output=True, text=True).stdout
            got = dict(line.split(' ', 1) for line in out.splitlines() if ' ' in line)
            for k, want in WANT.items():
                check(got.get(k) == want, f'{LABEL[k]}: {got.get(k)!r}' + ('' if got.get(k) == want else f' (want {want!r})'))
            if len(sys.argv) > 1:
                print(subprocess.run([str(exe), '--files', *sys.argv[1:]], capture_output=True, text=True).stdout, end='')

print('FAIL' if failures else 'PASS', f'check-dx-pill ({failures} failure(s))')
sys.exit(1 if failures else 0)
