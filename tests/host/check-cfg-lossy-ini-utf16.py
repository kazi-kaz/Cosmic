#!/usr/bin/env python3
"""Host check for cfg-lossy-ini-utf16 (run from a source tree with the patch applied).
Source checks always; a Swift fixture only when swiftc exists (--require-swift fails without one)."""
from pathlib import Path
import argparse, shutil, subprocess, sys, tempfile
ap = argparse.ArgumentParser(); ap.add_argument('--require-swift', action='store_true'); a = ap.parse_args()
root = Path(__file__).resolve().parents[2] if (Path(__file__).resolve().parents[2] / 'app/Madeira').exists() else Path('.')
app = root / 'app/Madeira'; fails = 0
def check(c, l):
    global fails; print(('PASS: ' if c else 'FAIL: ') + l); fails += (not c)
mc = (app/'MadeiraConfig.swift').read_text(); gi = (app/'GameIniFiles.swift').read_text()
gp = (app/'GameProfiles.swift').read_text(); di = (app/'DockInstallers.swift').read_text()
check('[cfg-lossy-decode]' in mc and 'String(decoding: data, as: UTF8.self)' in mc, 'MadeiraConfig.readText decodes lossy')
check('String(contentsOf: u, encoding: .utf8)' not in mc, 'MadeiraConfig no longer reads madeira.cfg with the strict decode')
check('readText(u).map(parse)' in mc and 'readText(profileURL)' in mc and 'let text = readText(u) ?? ""' in mc, 'cfg read, profile read and set() use readText')
check('MadeiraConfig.readText(u)' in gp and 'MadeiraConfig.readText(URL(fileURLWithPath: path))' in di, "game's own cfg readers use readText")
check('[ini-utf16]' in gi and 'utf16LE, utf16BE' in gi and 'utf16BigEndian' in gi, 'IniFileText knows UTF-16')
swiftc = shutil.which('swiftc')
if not swiftc:
    print('SKIP: swiftc not found (Swift fixture)'); fails += a.require_swift
else:
    src = gi[:gi.index('/// The .ini files each game has added')]
    body = src[src.index("/// A file's bytes as text"):]
    main = r'''
import Foundation
func rt(_ d: [UInt8]) -> String { let t = IniFileText(data: Data(d)); return t == nil ? "nil" : "\(t!.kind),\(t!.bom),\(t!.data(t!.text) == Data(d))" }
let le: [UInt8] = [0xFF,0xFE,0x61,0,0x3D,0,0xE9,0,0x0A,0]
print("le=" + rt(le))
print("be=" + rt([0xFE,0xFF,0,0x61,0,0x3D,0,0xE9,0,0x0A]))
print("noBomLE=" + rt([0x61,0,0x3D,0,0x31,0,0x0A,0]))
print("noBomBE=" + rt([0,0x61,0,0x3D,0,0x31,0,0x0A]))
print("odd=" + rt([0xFF,0xFE,0x61,0,0x3D]))
print("latin=" + rt([0x61,0x3D,0xE9,0x0A]))
print("bom8=" + rt([0xEF,0xBB,0xBF,0x61,0x3D,0x31,0x0A]))
print("text=\(IniFileText(data: Data(le))!.text == "a=é\n")")
'''
    with tempfile.TemporaryDirectory() as t:
        (Path(t)/'IniText.swift').write_text('import Foundation\n' + body)
        (Path(t)/'main.swift').write_text(main)
        r = subprocess.run([swiftc, '-o', t+'/x', t+'/IniText.swift', t+'/main.swift'], capture_output=True, text=True)
        check(r.returncode == 0, 'fixture compiles\n' + r.stderr[-800:])
        if r.returncode == 0:
            o = subprocess.run([t+'/x'], capture_output=True, text=True).stdout
            exp = ['le=utf16LE,true,true','be=utf16BE,true,true','noBomLE=utf16LE,false,true','noBomBE=utf16BE,false,true','odd=nil',
                   'latin=latin1,false,true','bom8=utf8,true,true','text=true']
            for e in exp: check(e in o.split('\n'), e)
print('FAIL' if fails else 'PASS'); sys.exit(1 if fails else 0)
