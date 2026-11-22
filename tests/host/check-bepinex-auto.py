#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""[bepinex-auto] A game folder modded with BepInEx gets winhttp=n,b (and the other Doorstop proxy names)
in WINEDLLOVERRIDES at launch (WineProcessBridge.m). Compiles the real scan + wrapper out of the source
and runs them against throw-away game folders. Off: env.MADEIRA_BEPINEX_AUTO = 0. Run from the repo root."""
import os, re, shutil, subprocess, sys, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
src = (ROOT / "app/Madeira/WineProcessBridge.m").read_text()
fail = 0
def req(c, w):
    global fail
    print(("ok   " if c else "FAIL ") + w); fail += (not c)

b0 = src.index("/* bepinex-auto begin */")
b1 = src.index("/* C:\\windows\\<farm>: links whose bundle file is gone.")
code = src[b0:b1]
off = re.search(r"static int madeira_cfg_off_word\(const char \*v\)\s*\{.*?\n\}", src, re.S).group(0)
req('MADEIRA_BEPINEX_AUTO' in code and 'madeira_cfg_off_word(sw)' in code, "off switch env.MADEIRA_BEPINEX_AUTO = 0 is read")
cv = (ROOT / "app/Madeira/ContentView.swift").read_text()
req('setenv("MADEIRA_BEPINEX_DIRS"' in cv and cv.index('setenv("MADEIRA_BEPINEX_DIRS"') < cv.index("runWineFullSequence(profile: profile)", cv.index('setenv("MADEIRA_BEPINEX_DIRS"')),
    "a Dock start names the game's folders before its session starts")
req(re.search(r'DockInstallers\.installsOnly \{\s*unsetenv\("MADEIRA_BEPINEX_DIRS"\)', cv) is not None, "an installs-only Dock session names none")
req(re.search(r'JIT not enabled[^\n]*\n\s*unsetenv\("MADEIRA_BEPINEX_DIRS"\)', cv) is not None, "a Dock start that stops at the JIT check clears the folder list")
req("if let launchProgram = steamEntry?.program {" in cv, "the program's folder is the one Steam's launch entry names")
req(src.count("madeira_bepinex_auto(g_prefix_path, madeira_exe);") == 1, "called once before __wine_main (after the working-folder chdir)")
req(src.index("madeira_bepinex_auto(g_prefix_path, madeira_exe);") < src.index("__wine_main(argc, argv);"), "call comes before __wine_main")
req("env.MADEIRA_BEPINEX_AUTO" in (ROOT / "app/Madeira/ConfigCatalog.generated.swift").read_text(), "switch is in the config catalog")
req('"[WineProc] [bepinex-auto]' in code, "log line [bepinex-auto]")

harness = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <dirent.h>
#include <unistd.h>
''' + off + code + r'''
int main(int argc, char **argv) {
    /* argv[1] = prefix, argv[2] = exe (C:\ path), env set by the caller; prints WINEDLLOVERRIDES afterwards */
    madeira_bepinex_auto(argv[1], argv[2]);
    const char *w = getenv("WINEDLLOVERRIDES");
    printf("RESULT=%s\n", w ? w : "(unset)");
    madeira_bepinex_restore();   /* the session's end */
    w = getenv("WINEDLLOVERRIDES");
    printf("AFTER=%s\n", w ? w : "(unset)");
    return 0;
}
'''
cc = shutil.which("gcc") or shutil.which("clang")
if not cc:
    print("skip compiled part (no gcc/clang)"); sys.exit(1 if fail else 0)
tmp = Path(tempfile.mkdtemp())
(tmp / "h.c").write_text(harness)
r = subprocess.run([cc, "-Wall", "-Werror=implicit-function-declaration", "-o", str(tmp / "h"), str(tmp / "h.c")], capture_output=True, text=True)
req(r.returncode == 0, "scan and wrapper compile" + ("" if r.returncode == 0 else ": " + r.stderr[:400]))
if r.returncode:
    sys.exit(1)

def game(name, files, dirs=()):
    g = tmp / ("g_" + name) / "drive_c" / "Games" / "Foo"
    g.mkdir(parents=True)
    for f in files: (g / f).write_text("x")
    for d in dirs: (g / d).mkdir()
    return str(tmp / ("g_" + name))

def run(prefix, exe=r"C:\Games\Foo\Foo.exe", env=None):
    e = {k: v for k, v in os.environ.items() if not k.startswith(("WINEDLLOVERRIDES", "MADEIRA_"))}
    e.update(env or {})
    o = subprocess.run([str(tmp / "h"), prefix, exe], capture_output=True, text=True, env=e)
    run.after = re.search(r"AFTER=(.*)", o.stdout).group(1)
    return re.search(r"RESULT=(.*)", o.stdout).group(1), o.stderr

p = game("a", ["Foo.exe", "winhttp.dll", "doorstop_config.ini"], ["BepInEx"])
res, err = run(p)
req(res == "winhttp=n,b", "winhttp.dll + BepInEx folder + doorstop_config.ini: winhttp=n,b")
req(run.after == "(unset)", "session end: was unset before, unset again")
req("[bepinex-auto]" in err and "winhttp" in err, "logged")
res, _ = run(p, env={"WINEDLLOVERRIDES": "video64="})
req(res == "video64=;winhttp=n,b", "joins the game's own list")
req(run.after == "video64=", "session end: WINEDLLOVERRIDES is back to what it was (no leak to the next game)")
res, _ = run(p, env={"WINEDLLOVERRIDES": "winhttp=n,b;video64="})
req(res == "winhttp=n,b;video64=", "Mods page's own winhttp entry is not doubled")
res, _ = run(p, env={"WINEDLLOVERRIDES": "winhttp=d"})
req(res == "winhttp=d", "the player's own winhttp entry wins (even =d)")
res, _ = run(p, env={"WINEDLLOVERRIDES": "version,winhttp=b"})
req(res == "version,winhttp=b", "a comma list that names winhttp wins")
res, err = run(p, env={"MADEIRA_BEPINEX_AUTO": "0"})
req(res == "(unset)" and "left alone" in err, "MADEIRA_BEPINEX_AUTO=0: nothing added, logged")
res, _ = run(p, env={"MADEIRA_BEPINEX_AUTO": "off", "WINEDLLOVERRIDES": "video64="})
req(res == "video64=", "MADEIRA_BEPINEX_AUTO=off: the list is untouched")
res, _ = run(p, env={"MADEIRA_BEPINEX_AUTO": "1"})
req(res == "winhttp=n,b", "MADEIRA_BEPINEX_AUTO=1 is on")

p = game("b", ["Foo.exe", "WINHTTP.DLL"], ["bepinex"])
res, _ = run(p)
req(res == "winhttp=n,b", "names matched without case")

p = game("c", ["Foo.exe", "winhttp.dll"])
res, _ = run(p)
req(res == "(unset)", "winhttp.dll alone (no BepInEx folder, no doorstop_config.ini): untouched")

p = game("d", ["Foo.exe"], ["BepInEx"])
res, _ = run(p)
req(res == "(unset)", "BepInEx folder but no proxy dll: untouched")

p = game("e", ["Foo.exe", "version.dll", "winhttp.dll"], ["MelonLoader", "BepInEx"])
res, _ = run(p)
req(res == "(unset)", "a MelonLoader folder: left to MelonLoader's own list")

p = game("f", ["Foo.exe", "version.dll"], ["MelonLoader"])
res, _ = run(p)
req(res == "(unset)", "MelonLoader only: untouched")

p = game("g", ["Foo.exe", "version.dll", "doorstop_config.ini"])
res, _ = run(p)
req(res == "version=n,b", "doorstop with a version.dll proxy: version=n,b")

p = game("h", ["Foo.exe", "winmm.dll", "dinput8.dll", "d3d9.dll", "dxgi.dll"], ["BepInEx"])
res, _ = run(p)
req(res == "winmm=n,b;dinput8=n,b", "winmm and dinput8 proxies; d3d9/dxgi are never touched")

p = game("hh", ["Foo.exe", "winhttp.dll", "dinput8.dll", "winmm.dll", "version.dll"], ["BepInEx"])
res, _ = run(p)
req(res == "winhttp=n,b", "winhttp.dll present: only winhttp (an ASI loader's dinput8 / another mod's winmm, version stay builtin)")
for own in ("video64= ; winhttp=d", "winhttp.dll=d", "video64=;WINHTTP.DLL=n,b"):
    res, _ = run(p, env={"WINEDLLOVERRIDES": own})
    req(res == own, "the player's own entry %r is recognised (spaces, .dll, case)" % own)

p = game("i", ["Foo.exe", "winhttp.dll"], ["BepInEx"])
res, _ = run(p, exe=r"D:\Games\Foo\Foo.exe")
req(res == "(unset)", "a D:\\ program is left alone")
res, _ = run(p, exe="Foo.exe")
req(res == "(unset)", "a bare program name is left alone")
res, _ = run(p, exe=r"C:\Games\Missing\Foo.exe")
req(res == "(unset)", "a missing folder is left alone")
# Madeira Dock: the program is explorer.exe, the app names the game's folders (host paths, one per line).
host = str(tmp / "g_a" / "drive_c" / "Games" / "Foo")
plain = str(tmp / "g_c" / "drive_c" / "Games" / "Foo")
res, err = run(str(tmp), exe="explorer.exe", env={"MADEIRA_BEPINEX_DIRS": host})
req(res == "winhttp=n,b" and "in " + host in err, "Dock: explorer.exe + the game's folder: winhttp=n,b, the folder is in the log line")
req(run.after == "(unset)", "Dock: restored at the session's end")
res, _ = run(str(tmp), exe="explorer.exe", env={"MADEIRA_BEPINEX_DIRS": plain + "\n" + host})
req(res == "winhttp=n,b", "Dock: the first folder is not BepInEx, the second is: used")
res, _ = run(str(tmp), exe="explorer.exe", env={"MADEIRA_BEPINEX_DIRS": plain})
req(res == "(unset)", "Dock: no BepInEx in any folder: untouched")
res, _ = run(str(tmp), exe="explorer.exe", env={"MADEIRA_BEPINEX_DIRS": host, "MADEIRA_BEPINEX_AUTO": "0", "WINEDLLOVERRIDES": "video64="})
req(res == "video64=", "Dock: env.MADEIRA_BEPINEX_AUTO = 0 leaves it out")
res, _ = run(str(tmp), exe="explorer.exe", env={"MADEIRA_BEPINEX_DIRS": host, "WINEDLLOVERRIDES": "winhttp=d"})
req(res == "winhttp=d", "Dock: the game's own winhttp entry wins")
res, _ = run(str(tmp), exe="explorer.exe", env={"MADEIRA_BEPINEX_DIRS": "relative/dir"})
req(res == "(unset)", "Dock: a relative folder is ignored")
res, _ = run(str(tmp), exe="cmd.exe", env={"MADEIRA_BEPINEX_DIRS": host})
req(res == "(unset)", "the folders are used only with explorer.exe")
res, _ = run(str(tmp / "g_c"), exe=r"C:\Games\Foo\Foo.exe", env={"MADEIRA_BEPINEX_DIRS": host})
req(res == "(unset)", "a C:\\ program is scanned by itself: a stale folder list is not used")
shutil.rmtree(tmp, ignore_errors=True)
sys.exit(1 if fail else 0)
