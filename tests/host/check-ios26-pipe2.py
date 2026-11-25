#!/usr/bin/env python3
"""Host check for the iOS 26 pipe2 guard in build/ntdll-unix/server_ios.c.

pipe2 is iOS 27+ and weak-linked, so on iOS 26 calling it jumps to 0.
server_pipe() must only call pipe2 inside __builtin_available(iOS 27.0, *)
and otherwise fall back to pipe() + FD_CLOEXEC.
Part 1: source checks. Part 2: compile server_pipe() on the host with
__builtin_available modelled as a flag and pipe2 as a stub that records calls.
"""
import os, re, subprocess, sys, tempfile

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
SRC = os.path.join(ROOT, "build", "ntdll-unix", "server_ios.c")
fails = 0
def check(ok, what):
    global fails
    print(("PASS: " if ok else "FAIL: ") + what)
    if not ok: fails += 1

text = open(SRC).read()
m = re.search(r"\nint server_pipe\( int fd\[2\] \)\n\{.*?\n\}\n", text, re.S)
check(m is not None, "server_pipe() found")
if not m:
    sys.exit(1)
body = m.group(0)
code = re.sub(r"/\*.*?\*/", "", body, flags=re.S)

check("__builtin_available( iOS 27.0, * )" in code, "pipe2 call is guarded by __builtin_available(iOS 27.0, *)")
g = code.find("__builtin_available"); c = code.find("pipe2( fd")
check(0 <= g < c, "the guard comes before the pipe2 call")
check(re.search(r"#ifdef WINE_IOS\s*\n\s*if \(__builtin_available", code) is not None, "the guard is iOS-only (WINE_IOS)")
check(re.search(r"#ifdef WINE_IOS\s*\n\s*else have_pipe2 = FALSE;", code) is not None, "iOS 26 turns pipe2 off and falls through")
check(code.count("pipe2(") == 1, "server_pipe has exactly one pipe2 call")
check("if (!(ret = pipe( fd )))" in code and code.count("FD_CLOEXEC") == 2, "pipe() + FD_CLOEXEC fallback kept")
others = [l for l in re.sub(r"/\*.*?\*/", "", text, flags=re.S).split("\n") if "pipe2(" in l and "pipe2( fd, O_CLOEXEC ))) return ret" not in l]
check(not others, "no other pipe2 call in server_ios.c")

model = r'''
#include <stdio.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
typedef int BOOL;
#define TRUE 1
#define FALSE 0
#define HAVE_PIPE2 1
#define WINE_IOS 1
static int avail, pipe2_calls;
#define __builtin_available(...) avail
static int fake_pipe2( int fd[2], int flags )
{
    pipe2_calls++;
    if (pipe( fd )) return -1;
    if (flags & O_CLOEXEC) { fcntl( fd[0], F_SETFD, FD_CLOEXEC ); fcntl( fd[1], F_SETFD, FD_CLOEXEC ); }
    return 0;
}
#define pipe2 fake_pipe2
%s
int main( int argc, char **argv )
{
    int fd[2], i, ok = 1;
    avail = atoi( argv[1] );
    for (i = 0; i < 3; i++)
    {
        if (server_pipe( fd ) != 0) ok = 0;
        if (!(fcntl( fd[0], F_GETFD ) & FD_CLOEXEC) || !(fcntl( fd[1], F_GETFD ) & FD_CLOEXEC)) ok = 0;
        close( fd[0] ); close( fd[1] );
    }
    printf( "%%d %%d\n", ok, pipe2_calls );
    return 0;
}
''' % body
with tempfile.TemporaryDirectory() as d:
    c_path = os.path.join(d, "m.c"); exe = os.path.join(d, "m")
    open(c_path, "w").write(model)
    r = subprocess.run(["cc", "-Wall", "-o", exe, c_path], capture_output=True, text=True)
    check(r.returncode == 0, "model compiles" + ("" if r.returncode == 0 else ": " + r.stderr[:400]))
    if r.returncode == 0:
        o26 = subprocess.run([exe, "0"], capture_output=True, text=True).stdout.split()
        o27 = subprocess.run([exe, "1"], capture_output=True, text=True).stdout.split()
        check(o26 == ["1", "0"], "model iOS 26: 3 pipes made, CLOEXEC set, pipe2 never called (got %s)" % o26)
        check(o27 == ["1", "3"], "model iOS 27: pipe2 used each time (got %s)" % o27)

print("check-ios26-pipe2: " + ("PASS" if not fails else "%d FAILED" % fails))
sys.exit(1 if fails else 0)
