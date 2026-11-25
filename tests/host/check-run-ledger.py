#!/usr/bin/env python3
"""Host check for shared-logs-ledger: patch applies to test18 (or, with the patch merged, the tree as it is), markers/switches present, ledger line + rotation model.
Usage: python3 check-run-ledger.py <test18 app/Madeira dir parent (repo root)>   (Swift typecheck is NOT done here)"""
import subprocess, sys, tempfile, shutil, os, re
root = sys.argv[1] if len(sys.argv) > 1 else "/mnt/project-files/source/test18"
here = os.path.dirname(os.path.abspath(__file__))
fails = 0
def ok(c, m):
    global fails
    print(("PASS " if c else "FAIL ") + m); fails += (not c)
tmp = tempfile.mkdtemp()
os.makedirs(tmp + "/app/Madeira")
patch_file = here + "/shared-logs-ledger.patch"
if os.path.exists(patch_file):
    for f in ("LogTrail", "GetHelpView", "LogsView"):
        shutil.copy(f"{root}/app/Madeira/{f}.swift", tmp + "/app/Madeira/")
    r = subprocess.run(["patch", "-p1", "-s"], input=open(patch_file).read(), text=True, cwd=tmp, capture_output=True)
    ok(r.returncode == 0, "patch applies to " + root)
else:
    # the patch is merged into the tree (0.2.30 on): check the sources as they are
    repo = os.path.abspath(os.path.join(here, "..", ".."))
    for f in ("LogTrail", "GetHelpView", "LogsView"):
        shutil.copy(f"{repo}/app/Madeira/{f}.swift", tmp + "/app/Madeira/")
lt = open(tmp + "/app/Madeira/LogTrail.swift").read()
for sw in ("MADEIRA_RUN_LEDGER", "MADEIRA_KEEP_LASTGOOD", "MADEIRA_LOG_SETTINGS", "MADEIRA_LOG_LASTRUN"):
    ok(f'flag("{sw}")' in lt, f"switch {sw} read via MadeiraConfig.flag")
ok(lt.count("{") == lt.count("}"), "LogTrail.swift braces balance")
ok("run-history" in lt and "Documents/logs" in lt, "ledger kept out of Documents/logs")
gh = open(tmp + "/app/Madeira/GetHelpView.swift").read()
ok("RunLedger.extras" in gh and "previousLaunchRun" in gh, "DiscordLog adds ledger/last runs")
ok("LogLines.scan(in: log)" in lt and 'startMark = "[run-start] #' in lt, "keepRun cuts by run number, streaming")
ok("groups.removeFirst()" in lt, "summary block trims whole runs")
ok('"start failed"' in lt and 'quit == "normal" && words.contains("exit code 0")' in lt, "good/fail classification per review 2")
ok("allSatisfy" in lt, "game folder never . or ..")
# model of the ledger line and rotation (mirrors RunLedger.line / append)
def field(s): return s.replace("\t", " ").replace("\n", " ")
line = "\t".join(map(field, ["2026-11-17 09:36:27Z", "Madeira Nightly 0.2.29", "Fallout\tNV", "Steam 22380", "iPhone18,2", "a1", "b2", "crash", "56", "session", "x\ny", "yes"]))
ok(line.count("\t") == 11 and "\n" not in line, "ledger line has 12 fields, one line")
lines = []
for i in range(350): lines.append(str(i)); lines = lines[-300:]
ok(len(lines) == 300 and lines[0] == "50", "rotation keeps newest 300")
print("fails:", fails); sys.exit(1 if fails else 0)
