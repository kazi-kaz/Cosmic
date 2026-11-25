#!/usr/bin/env python3
"""Host check for the Wine [crash-report] block (wine/dlls/kernelbase/debug.c): compiles only the pure text helpers
(between crash-report-pure-begin and crash-report-pure-end) with the host C compiler and checks the module+offset text,
the hex formatter, the line cap, and that the switch and the call site are in the source.
Usage: check-crash-report.py [path to debug.c]   (default wine/dlls/kernelbase/debug.c)"""
import os, re, subprocess, sys, tempfile
path = sys.argv[1] if len(sys.argv) > 1 else "wine/dlls/kernelbase/debug.c"
src = open(path, encoding="utf-8").read()
fails = 0
def ok(c, m):
    global fails
    print(("PASS " if c else "FAIL ") + m); fails += (not c)
m = re.search(r"/\* crash-report-pure-begin \*/(.*?)/\* crash-report-pure-end \*/", src, re.S)
ok(bool(m), "pure helper region present")
ok('L"MADEIRA_CRASH_REPORT"' in src and "on[0] == '0') crash_report_off = TRUE;" in src and 'if (crash_report_off) return;' in src, "switch env.MADEIRA_CRASH_REPORT = 0 read once at start")
i = src.index("static BOOL start_debugger( EXCEPTION_POINTERS *epointers, HANDLE event )")
ok("crash_report( epointers );" in src[i:i + 1500], "crash_report is called at the top of start_debugger")
ok("InterlockedCompareExchange( &crash_report_done, 1, 0 )" in src, "printed once")
ok("fprintf" not in src[src.index("(crash-report)"):src.index("crash-report-pure-end")] and "HeapAlloc" not in src[src.index("crash_collect_modules"):src.index("static void crash_report(")], "no heap allocation in the report")
ok("NtReadVirtualMemory" in src and src.count("crash_read(") >= 8, "memory is read through NtReadVirtualMemory")
if m:
    harness = r'''
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
%s
int main(void) {
    struct crash_mod mods[2] = { { 0x400000ULL, 0x1c00000, "FalloutNV.exe" }, { 0x7b000000ULL, 0x2000, "kernelbase.dll" } };
    struct crash_line l = { {0}, 0 };
    crash_addr(&l, mods, 2, 0xB57AA9ULL, 8); printf("%%s|", l.s);
    l.n = 0; l.s[0] = 0; crash_addr(&l, mods, 2, 0x7b000010ULL, 8); printf("%%s|", l.s);
    l.n = 0; l.s[0] = 0; crash_addr(&l, mods, 2, 0x10ULL, 8); printf("%%s|", l.s);
    l.n = 0; l.s[0] = 0; crash_addr(&l, mods, 2, 0x401ffffULL + 0x1c00000ULL, 8); printf("%%s|", l.s);
    l.n = 0; l.s[0] = 0; crash_hex(&l, 0, 0); crash_str(&l, "/"); crash_hex(&l, 0xdeadbeefcafeULL, 16); printf("%%s|", l.s);
    l.n = 0; l.s[0] = 0; for (int i = 0; i < 1000; i++) crash_str(&l, "abcdefghij"); crash_end_line(&l); printf("%%zu", strlen(l.s));
    return 0;
}
''' % m.group(1)
    with tempfile.TemporaryDirectory() as d:
        open(d + "/t.c", "w").write(harness)
        cc = subprocess.run(["cc", "-std=gnu11", "-Wall", "-Werror", "-o", d + "/t", d + "/t.c"], capture_output=True, text=True)
        ok(cc.returncode == 0, "pure helpers compile warning-free with the host compiler" + ("" if cc.returncode == 0 else ": " + cc.stderr[:300]))
        if cc.returncode == 0:
            out = subprocess.run([d + "/t"], capture_output=True, text=True).stdout.split("|")
            ok(out[0] == "0x00b57aa9 (FalloutNV.exe+0x757aa9)", "eip in the exe: " + out[0])
            ok(out[1] == "0x7b000010 (kernelbase.dll+0x10)", "address in kernelbase: " + out[1])
            ok(out[2] == "0x00000010", "address in no module has no module text: " + out[2])
            ok(out[3] == "0x05c1ffff", "past the end of every module has no module text: " + out[3])
            ok(out[4] == "0/0000deadbeefcafe", "hex: " + out[4])
            ok(int(out[5]) <= 400, "a long line stays inside its 400-byte buffer: " + out[5])
print("fails: %d" % fails)
sys.exit(1 if fails else 0)