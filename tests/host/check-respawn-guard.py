#!/usr/bin/env python3
"""respawn-guard: a self-respawn is refused only after 3 copies of that image each closed within 6 s,
inside 60 s; --type= helpers and other programs never count; the app only tells the player.
Compiles the guard on the host with a stubbed ended-ring and checks the wiring."""
import pathlib, subprocess, sys, tempfile
root = pathlib.Path(__file__).resolve().parents[2]
src = (root / 'build/ntdll-unix/process_ios.c').read_text()
ok = True
def check(name, cond):
    global ok
    print(('PASS ' if cond else 'FAIL ') + name); ok &= bool(cond)

i = src.index('/* respawn-guard (pending-prs/respawn-guard)')
j = src.index('/* The image the guard stopped this session', i)
block = src[i:j]
check('off switch MADEIRA_RESPAWN_GUARD = 0', 'getenv( "MADEIRA_RESPAWN_GUARD" )' in block and "e[0] == '0' && !e[1]" in block)
check('3 fast copies, 6 s, 60 s', '#define IOS_RESPAWN_FAST   3' in block and '#define IOS_RESPAWN_SHORT  6.0' in block and '#define IOS_RESPAWN_WINDOW 60.0' in block)
check('the ended ring is read under ios_child_lock', 'pthread_mutex_lock( &ios_child_lock );' in block and 'ios_child_ended[at].ended_at - ios_child_ended[at].started >= IOS_RESPAWN_SHORT' in block)
check('--type= helpers skipped', 'ios_respawn_has_type_arg( cmdline )' in block)
check('C:\\windows\\ programs skipped', 'if (ios_respawn_is_system( path )) return 0;' in block)
nt = src[src.index('NTSTATUS WINAPI NtCreateUserProcess('):]
call = nt.index('if (ios_respawn_guard_stop( &params->ImagePathName, &params->CommandLine )) return STATUS_ACCESS_DENIED;')
check('refused before anything is allocated or opened', nt.index('if (!process_attr) process_attr = &empty_attr;') < call < nt.index('alloc_object_attributes('))
check('reset and getter exported', 'void madeira_respawn_guard_reset( void )' in src and 'int madeira_respawn_guard_image( char *buf, int len )' in src)

lib = (root / 'app/Madeira/Library.swift').read_text()
dsp = (root / 'app/Madeira/LibraryBCD.swift').read_text()   # RespawnGuard lives beside ShortMap (DockStartProgram.swift is compiled alone by check-dock-start-program)
assert 'enum RespawnGuard' not in (root / 'app/Madeira/DockStartProgram.swift').read_text()
hdr = (root / 'app/Madeira/Madeira-Bridging-Header.h').read_text()
rg = dsp[dsp.index('enum RespawnGuard'):]
check('bridging header', 'int madeira_respawn_guard_image(char *buf, int len);' in hdr and 'void madeira_respawn_guard_reset(void);' in hdr)
check('begin resets it', 'wine_exit_status_reset(); RespawnGuard.reset()' in lib)
check('finish tells the player first', 'if let note = RespawnGuard.finish(activeEntry) { error = note }   // respawn-guard\n        else if sawProcess, let next = steamRunRequest()' in lib)
check('the Steam starts choice is never touched', 'setChosen' not in rg and 'apply(' not in rg and 'moveItem' not in rg)
cat = (root / 'build/tools/gen-config-catalog.py').read_text()
k = cat.index('"env.MADEIRA_RESPAWN_GUARD"')
check('catalog lists the switch, on by default', '"default": "1"' in cat[k:k + 300])

prog = r"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
typedef unsigned short WCHAR;
typedef struct { unsigned short Length, MaximumLength; WCHAR *Buffer; } UNICODE_STRING;
typedef struct { UNICODE_STRING ImagePathName; } RTL_USER_PROCESS_PARAMETERS;
typedef struct { RTL_USER_PROCESS_PARAMETERS *ProcessParameters; } PEB;
typedef struct { PEB *Peb; } TEB;
static TEB teb; static PEB peb; static RTL_USER_PROCESS_PARAMETERS pp;
static TEB *NtCurrentTeb(void) { return &teb; }
static double fake_now;
static double ios_child_now(void) { return fake_now; }
#define IOS_CHILD_PATH 256
#define IOS_CHILD_ENDED 64
static pthread_mutex_t ios_child_lock = PTHREAD_MUTEX_INITIALIZER;
static struct { char name[64]; char path[IOS_CHILD_PATH]; double started; double ended_at; int status; } ios_child_ended[IOS_CHILD_ENDED];
static unsigned ios_child_ended_count;
#define ERR(...) printf(__VA_ARGS__)
static void ios_child_path_text( char *out, const UNICODE_STRING *image )
{ unsigned i, n = 0; for (i = 0; i < image->Length / 2 && n < IOS_CHILD_PATH - 1; i++) out[n++] = (char)image->Buffer[i]; out[n] = 0; }
""" + block + r"""
static UNICODE_STRING us(const char *s, WCHAR *buf) { int n = strlen(s); for (int i = 0; i < n; i++) buf[i] = s[i]; UNICODE_STRING u = { n * 2, n * 2, buf }; return u; }
static void ended(const char *path, double started, double ended_at)
{ unsigned at = ios_child_ended_count++ % IOS_CHILD_ENDED; snprintf(ios_child_ended[at].path, IOS_CHILD_PATH, "%s", path); ios_child_ended[at].started = started; ios_child_ended[at].ended_at = ended_at; }
int main(void)
{
    WCHAR a[300], b[300], c[300]; UNICODE_STRING none = { 0, 0, NULL };
    teb.Peb = &peb; peb.ProcessParameters = &pp;
    pp.ImagePathName = us("C:\\Games\\FNV\\FalloutNVLauncher.exe", a);
    UNICODE_STRING self = us("\\??\\c:\\games\\fnv\\falloutnvlauncher.exe", b);
    /* FNV: copies live 1-5 s */
    int r0 = (fake_now = 10, ios_respawn_guard_stop(&self, &none));
    ended("C:\\Games\\FNV\\FalloutNVLauncher.exe", 10, 12); ended("C:\\Games\\FNV\\FalloutNVLauncher.exe", 12, 15.5);
    int r2 = (fake_now = 15.6, ios_respawn_guard_stop(&self, &none));
    ended("C:\\Games\\FNV\\FalloutNVLauncher.exe", 15.6, 20);
    int r3 = (fake_now = 20.1, ios_respawn_guard_stop(&self, &none));
    int r4 = (fake_now = 21, ios_respawn_guard_stop(&self, &none));
    printf("fnv %d%d%d%d\n", r0, r2, r3, r4);
    /* the same three fast ends, but over 60 s ago */
    fake_now = 200; printf("old %d\n", ios_respawn_guard_stop(&self, &none));
    /* Chromium helper: same image, --type=, after many fast ends */
    pp.ImagePathName = us("C:\\BN\\Battle.net.exe", a);
    UNICODE_STRING bn = us("C:\\BN\\Battle.net.exe", b), bncmd = us("\"C:\\BN\\Battle.net.exe\" --type=renderer --lang=en", c);
    for (int i = 0; i < 5; i++) ended("C:\\BN\\Battle.net.exe", 300 + i, 300.5 + i);
    fake_now = 306; printf("helper %d\n", ios_respawn_guard_stop(&bn, &bncmd));
    /* long-lived copies never count */
    pp.ImagePathName = us("C:\\x\\a.exe", a); UNICODE_STRING s2 = us("C:\\x\\a.exe", b);
    for (int i = 0; i < 5; i++) ended("C:\\x\\a.exe", 400 + i, 420 + i);
    fake_now = 430; printf("long %d\n", ios_respawn_guard_stop(&s2, &none));
    /* another program (installer started by its setup) never counts, however fast */
    pp.ImagePathName = us("C:\\x\\dxsetup.exe", a); UNICODE_STRING inf = us("C:\\x\\infinst.exe", b);
    for (int i = 0; i < 7; i++) ended("C:\\x\\infinst.exe", 500 + i, 500.5 + i);
    fake_now = 508; printf("other %d\n", ios_respawn_guard_stop(&inf, &none));
    /* a system program that starts itself (cmd.exe /c ...), however fast */
    pp.ImagePathName = us("C:\\windows\\system32\\cmd.exe", a); UNICODE_STRING cmd = us("\\??\\C:/Windows/System32/cmd.exe", b);
    for (int i = 0; i < 6; i++) ended("C:\\windows\\system32\\cmd.exe", 550 + i, 550.2 + i);
    fake_now = 557; printf("system %d\n", ios_respawn_guard_stop(&cmd, &none));
    setenv("MADEIRA_RESPAWN_GUARD", "0", 1);
    pp.ImagePathName = us("C:\\Games\\FNV\\FalloutNVLauncher.exe", a);
    for (int i = 0; i < 4; i++) ended("C:\\Games\\FNV\\FalloutNVLauncher.exe", 600 + i, 600.5 + i);
    fake_now = 605; printf("off %d\n", ios_respawn_guard_stop(&self, &none));
    return 0;
}
"""
with tempfile.TemporaryDirectory() as d:
    cf = pathlib.Path(d) / 'g.c'; cf.write_text(prog)
    cc = subprocess.run(['cc', '-std=gnu11', '-Wall', '-Werror', '-Wno-unused-function', '-o', str(pathlib.Path(d) / 'g'), str(cf), '-lpthread'], capture_output=True, text=True)
    check('guard compiles on the host', cc.returncode == 0)
    if cc.returncode: print(cc.stderr[:1500])
    else:
        out = subprocess.run([str(pathlib.Path(d) / 'g')], capture_output=True, text=True).stdout
        check('FNV-like loop: the start after 3 fast copies is refused, logged once', 'fnv 0011' in out and out.count('[respawn-guard]') == 1)
        check('fast ends older than 60 s do not count', 'old 0' in out)
        check('a --type= helper of the same image never counts', 'helper 0' in out)
        check('copies that lived 6 s or more never count', 'long 0' in out)
        check('a different program never counts', 'other 0' in out)
        check('a C:\\windows\\ program never counts', 'system 0' in out)
        check('MADEIRA_RESPAWN_GUARD=0: nothing refused', 'off 0' in out)
sys.exit(0 if ok else 1)
