#!/usr/bin/env python3
"""Host check: spawn_process (iOS branch, build/ntdll-unix/process_ios.c) must not
putenv() the caller's malloc'd winedebug string. On iOS the child is a thread in the
same process and create_process frees winedebug right after, so putenv left a freed
pointer in the app's environment. The iOS branch must copy it with setenv().
Part 1: source checks. Part 2: a host model of the old and new code."""
import os, re, subprocess, sys, tempfile
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
SRC = os.path.join(ROOT, "build", "ntdll-unix", "process_ios.c")
fails = 0
def check(ok, what):
    global fails
    print(("PASS: " if ok else "FAIL: ") + what)
    if not ok: fails += 1

text = open(SRC).read()
m = re.search(r"static NTSTATUS spawn_process\(.*?\n#ifdef WINE_IOS\n(.*?)\n#else\n", text, re.S)
check(m is not None, "iOS branch of spawn_process found")
ios = re.sub(r"/\*.*?\*/", "", m.group(1), flags=re.S) if m else ""
check("putenv" not in ios, "iOS branch has no putenv")
check('setenv( "WINEDEBUG", val + 1, 1 )' in ios, "iOS branch copies WINEDEBUG with setenv")
check(ios.find("setenv") < ios.find("pthread_create"), "set before the child thread starts")
check(re.search(r"free\( winedebug \);", text) is not None, "create_process still frees its copy (so the copy matters)")

model = r'''
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(int argc, char **argv)
{
    int use_setenv = atoi(argv[1]);
    char *winedebug = malloc(64);
    strcpy(winedebug, "WINEDEBUG=err+all,err-virtual");
    unsetenv("WINEDEBUG");
    if (use_setenv) { const char *v = strchr(winedebug, '='); setenv("WINEDEBUG", v + 1, 1); }
    else putenv(winedebug);
    memset(winedebug, 'X', 63); winedebug[63] = 0;   /* what reuse after free looks like */
    free(winedebug);
    const char *got = getenv("WINEDEBUG");
    printf("%s\n", got && !strcmp(got, "err+all,err-virtual") ? "intact" : "broken");
    return 0;
}
'''
with tempfile.TemporaryDirectory() as d:
    c = os.path.join(d, "m.c"); exe = os.path.join(d, "m")
    open(c, "w").write(model)
    r = subprocess.run(["cc", "-w", "-o", exe, c], capture_output=True, text=True)
    check(r.returncode == 0, "model compiles")
    if r.returncode == 0:
        old = subprocess.run([exe, "0"], capture_output=True, text=True).stdout.strip()
        new = subprocess.run([exe, "1"], capture_output=True, text=True).stdout.strip()
        check(old == "broken", "model: old code (putenv, then free) leaves the environment pointing at freed memory (got %s)" % old)
        check(new == "intact", "model: new code (setenv) keeps WINEDEBUG intact after the free (got %s)" % new)
print("check-ios-winedebug-env: " + ("PASS" if not fails else "%d FAILED" % fails))
sys.exit(1 if fails else 0)
