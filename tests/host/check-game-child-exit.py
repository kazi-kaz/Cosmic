#!/usr/bin/env python3
"""Host check for game-child-exit (LogTrail.gameChildEnd). No Swift on the host, so this
(1) checks the Swift and the bridging header carry the change and (2) runs a line-for-line
Python copy of gameChildEnd(report:windowsPath:within:) on report texts in
madeira_child_report's format (process_ios.c). Run from the repo root."""
import sys, pathlib
root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
swift = (root / "app/Madeira/LogTrail.swift").read_text()
hdr = (root / "app/Madeira/Madeira-Bridging-Header.h").read_text()
ok = True
def need(cond, what):
    global ok
    print(("PASS " if cond else "FAIL ") + what); ok &= bool(cond)
need("int madeira_child_report(char *buf, int len);" in hdr, "bridging header declares madeira_child_report")
need("else if let ended = gameChildEnd(windowsPath: windowsPath, within: total) { code = ended }" in swift, "[game-end] asks gameChildEnd before the launched code")
need(swift.index("gameChildEnd(windowsPath: windowsPath") > swift.index("wine_crash_exit_status(&status)"), "a crash of the launched program still wins")
need('MadeiraConfig.flag("MADEIRA_GAME_CHILD_EXIT")' in swift, "off switch env.MADEIRA_GAME_CHILD_EXIT")

def norm(p):
    t = p.replace("/", "\\").lower()
    for prefix in ["\\??\\", "\\\\?\\"]:
        if t.startswith(prefix): t = t[len(prefix):]
    while t.endswith("\\"): t = t[:-1]
    return t
def child_end(report, windows_path, seconds):
    folder = norm(windows_path)
    if folder.endswith(".exe") and "\\" in folder: folder = folder[:folder.rindex("\\")]
    if not folder: return None
    best = None
    for row in [r for r in report.split("\n") if r]:
        f = row.split("\t", 5)
        if len(f) != 6 or f[0] != "E" or f[1] != "0": continue
        try: status = int(f[2], 16); ago = float(f[3])
        except ValueError: continue
        if status == 0 or ago > seconds: continue
        path = norm(f[5])
        if not path.startswith(folder + "\\"): continue
        if best is None or ago < best[0]: best = (ago, status, path[path.rindex("\\") + 1:])
    if best is None: return None
    ago, status, name = best
    is_nt = status >= 0xC0000000 and status != 0xFFFFFFFF
    what = "Windows error 0x%08X" % status if is_nt else "exit code %d" % (status - (1 << 32) if status >= 1 << 31 else status)
    return "%s (%s, a program the game started)" % (what, name)

G = r"C:\Program Files (x86)\Steam\steamapps\common\Flinthook"
# Flinthook, Sentry GET-HELP-LOGS-J4: Dock host ends 0, Flinthook.exe abort_process -1 ~0.5 s before Wine ends.
flint = ("R\t0\t30.1\tC:\\windows\\system32\\explorer.exe\n"
         "E\t0\t0\t0.2\t20.0\tC:\\windows\\system32\\rundll32.exe\n"
         "E\t0\tffffffff\t15.3\t8.2\tC:\\Program Files (x86)\\Steam\\steamapps\\common\\Flinthook\\Flinthook.exe\n")
cases = [
    ("Flinthook -1", flint, G, 36, "exit code -1 (flinthook.exe, a program the game started)"),
    ("windowsPath is the exe", flint, G + r"\Flinthook.exe", 36, "exit code -1 (flinthook.exe, a program the game started)"),
    ("NT status -> Windows error", "E\t0\tc0000005\t1.0\t9.0\t\\??\\C:\\Games\\StS2\\SlayTheSpire2.exe\n", "C:/Games/StS2", 50,
     "Windows error 0xC0000005 (slaythespire2.exe, a program the game started)"),
    ("normal end stays old code", "E\t0\t0\t1.0\t9.0\t" + G + "\\Flinthook.exe\n", G, 36, None),
    ("helper ignored", "E\t1\tc0000005\t1.0\t9.0\t" + G + "\\CrashReporter.exe\n", G, 36, None),
    ("other folder ignored", "E\t0\tc0000005\t1.0\t9.0\tC:\\Program Files (x86)\\Steam\\steam.exe\n", G, 36, None),
    ("sibling folder name ignored", "E\t0\t1\t1.0\t9.0\t" + G + "2\\x.exe\n", G, 36, None),
    ("older run ignored", "E\t0\tffffffff\t400.0\t9.0\t" + G + "\\Flinthook.exe\n", G, 36, None),
    ("latest crash wins", "E\t0\t1\t20.0\t5\t" + G + "\\Launcher.exe\nE\t0\tc0000409\t2.0\t9\t" + G + "\\bin\\Game.exe\n", G, 36,
     "Windows error 0xC0000409 (game.exe, a program the game started)"),
    ("cut report (T) still parses", flint + "T\n", G, 36, "exit code -1 (flinthook.exe, a program the game started)"),
]
for name, rep, wp, secs, want in cases:
    got = child_end(rep, wp, secs)
    need(got == want, "%s -> %r" % (name, got))
need(not child_end(flint, G, 36).startswith("exit code 0"), "Flinthook no longer reads as exit code 0 (Get Help sees a crash)")
print("ALL PASS" if ok else "SOME FAILED"); sys.exit(0 if ok else 1)
