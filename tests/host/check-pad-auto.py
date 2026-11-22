#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""[pad-auto] env.MADEIRA_PAD_MODE unset = Automatic: a game folder with SDL2.dll / SDL3.dll or a Godot 4 game
gets player 1 as a generic HID gamepad, every other game XInput. Compiles the real folder scan out of
GamepadInput.swift with swiftc and runs it on throw-away game folders (SKIP without swiftc), plus source checks.
Off: env.MADEIRA_PAD_MODE = xinput or env.MADEIRA_PAD_AUTO = 0; the game's own line still wins. Run from the repo root."""
import os, re, shutil, struct, subprocess, sys, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
src = (ROOT / "app/Madeira/GamepadInput.swift").read_text()
fail = 0
def req(c, w):
    global fail
    print(("ok   " if c else "FAIL ") + w); fail += (not c)

# --- source checks
req('return (padAutoEnabled() ? "auto" : "xinput", "default")' in src, "nothing chosen = auto, or xinput when MADEIRA_PAD_AUTO = 0")
req('MadeiraConfig.gameValue("env.MADEIRA_PAD_AUTO")' in src and '["0", "off", "false", "no"].contains(v.lowercased())' in src, "env.MADEIRA_PAD_AUTO = 0 is the off switch (game's file, cfg, environment)")
i = src.index('if let v = MadeiraConfig.gameValue(padModeKey)')
req(i < src.index('return (padAutoEnabled()'), "an explicit mode (game's file, cfg, env) is read before the automatic choice")
req('[pad-auto] picked generic HID: ' in src and '[pad-auto] picked XInput: ' in src, "log lines [pad-auto] picked generic HID / XInput name what and why")
req('mode = ("generic", "auto")' in src and 'mode = ("xinput", "auto")' in src, "auto resolves to generic or xinput before the HID code")
req(src.index('if mode.value == "auto"') < src.index('guard ["hid", "dualsense", "generic"].contains(mode.value)'), "choice made before the mode guard")
cv = (ROOT / "app/Madeira/ContentView.swift").read_text()
req(cv.index("GamepadInput.sessionGameFolder =") < cv.index("GamepadInput.shared.beginPadSession()"), "game folder is set before beginPadSession")
cat = (ROOT / "app/Madeira/ConfigCatalog.generated.swift").read_text()
req('("", "Automatic (recommended)"), ("xinput", "XInput (always)")' in cat, "Controller API picker: Automatic (recommended) + XInput (always)")
req('key: "env.MADEIRA_PAD_AUTO"' in cat and 'defaultValue: "1"' in cat.split('key: "env.MADEIRA_PAD_AUTO"')[1].split("\n")[0], "env.MADEIRA_PAD_AUTO in the catalog, default 1")

# --- run the real scan
swiftc = shutil.which("swiftc")
if not swiftc:
    print("SKIP: no swiftc (source checks only)")
    print("PASS" if not fail else "FAILED"); sys.exit(1 if fail else 0)
a = src.index("    static func gameFolder(relativePath:")
b = src.index("    /// ml2106: what of a game's controller output")
body = src[a:b]
# cut the tail of the config helper block: keep from gameFolder to the end of godotPackVersion
end = body.index("        return u32(head, 4)\n    }\n") + len("        return u32(head, 4)\n    }\n")
body = body[:end]
# the doc comment of autoPadReason sits inside; drop the leading text up to first "static func autoPadReason" is fine
harness = "import Foundation\nenum G {\n" + body + "}\n" + r'''
let args = CommandLine.arguments
let r = G.autoPadReason(folder: URL(fileURLWithPath: args[1]))
print(r ?? "none")
let f = G.gameFolder(relativePath: args[2], startsDirectly: args[3] == "1", drive: URL(fileURLWithPath: "/d"))
print(f?.path ?? "nil")
'''
tmp = Path(tempfile.mkdtemp())
(tmp / "main.swift").write_text(harness)
r = subprocess.run([swiftc, "-O", str(tmp / "main.swift"), "-o", str(tmp / "h")], capture_output=True, text=True)
req(r.returncode == 0, "scan compiles" + ("" if r.returncode == 0 else ": " + r.stderr[-400:]))
if r.returncode == 0:
    def run(setup, rel="g/Game/game.exe", direct="0"):
        d = tmp / ("f%d" % len(list(tmp.iterdir())))
        d.mkdir()
        setup(d)
        o = subprocess.run([str(tmp / "h"), str(d), rel, direct], capture_output=True, text=True).stdout.split("\n")
        return o[0], o[1]
    def w(p, data=b"x"):
        p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(data)
    pck = lambda v: b"GDPC" + struct.pack("<I", v) + b"\0" * 32
    req(run(lambda d: w(d / "game.exe"))[0] == "none", "plain game folder: XInput")
    req("SDL2.dll" in run(lambda d: w(d / "SDL2.dll"))[0], "SDL2.dll next to the exe: generic HID")
    req("sdl3.dll" in run(lambda d: w(d / "bin/x64/sdl3.dll"))[0], "sdl3.dll two folders down, any case: generic HID")
    req(run(lambda d: w(d / "SDL2.dll.bak"))[0] == "none", "SDL2.dll.bak is not SDL2.dll")
    req("Godot 4" in run(lambda d: w(d / "SlayTheSpire2.pck", pck(2)))[0], "Godot 4 .pck (format 2): generic HID")
    req("Godot 4" in run(lambda d: w(d / "g.pck", pck(3)))[0], "Godot 4 .pck (format 3): generic HID")
    req(run(lambda d: w(d / "g.pck", pck(1)))[0] == "none", "Godot 3 .pck (format 1): XInput")
    req(run(lambda d: w(d / "g.pck", b"notgodot" * 4))[0] == "none", "a .pck that is not Godot: XInput")
    def appended(v):
        def s(d):
            pk = pck(v); w(d / "game.exe", b"MZ" + b"\0" * 100 + pk + struct.pack("<Q", len(pk)) + b"GDPC")
        return s
    req("pack inside" in run(appended(2))[0], "Godot 4 pack appended to the exe: generic HID")
    req(run(appended(1))[0] == "none", "Godot 3 pack appended to the exe: XInput")
    r = run(lambda d: (w(d / "SDL2.dll"), w(d / "FNA.dll")))[0]
    req(r.startswith("!") and "FNA" in r, "SDL2.dll with FNA.dll: XInput (denied)")
    req(run(lambda d: (w(d / "SDL2.dll"), w(d / "x/MonoGame.Framework.dll")))[0].startswith("!"), "SDL2.dll with MonoGame.Framework.dll: XInput (denied)")
    req("Godot 4" in run(lambda d: (w(d / "g.pck", pck(2)), w(d / "FNA.dll")))[0], "Godot 4 still wins over FNA.dll")
    req(run(lambda d: None, "windows/system32/explorer.exe", "0")[1] == "nil", "the Desktop entry (system32) gives no folder")
    g = run(lambda d: None, "Program Files (x86)/Steam/steamapps/common/Game", "0")[1]
    req(g == "/d/Program Files (x86)/Steam/steamapps/common/Game", "a Steam entry's relativePath is already the folder")
    req(run(lambda d: None, "Program Files (x86)/Steam/steamapps/common", "0")[1] == "nil", "a folder that holds several games gives no folder: XInput")
    req(run(lambda d: None, "g/Game/game.exe", "0")[1] == "/d/g/Game", "an .exe path gives its folder")
    shutil.rmtree(tmp, ignore_errors=True)
print("PASS" if not fail else "FAILED")
sys.exit(1 if fail else 0)
