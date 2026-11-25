#!/usr/bin/env python3
"""Host check for wow-image-anywindow (build/ntdll-unix/virtual_ios.c).

ios_guest_image_is_host_data() decides that a 32-bit image page is host data (no pool copy).
It used to test only the CALLING thread's window, so a re-protect run by another process
(Wine's virtual_enable_write_exceptions sweep from the first x64 process) copied every i386
image of the other processes into the JIT pool. Checks: the any-window helper exists and only
counts live slots, the image test falls back to it after the current-window test, the switch
and log are there, and the non-iOS stub exists. The scan rule is also compiled and run here."""
import re, shutil, subprocess, sys, tempfile
from pathlib import Path
root = Path(__file__).resolve().parents[2]
src = (root / 'build/ntdll-unix/virtual_ios.c').read_text()
fails = 0
def check(c, label):
    global fails
    print(('PASS: ' if c else 'FAIL: ') + label); fails += (not c)
i = src.find('int ios_wow_in_any_window( const void *addr )\n{')
check(i > 0, 'ios_wow_in_any_window is defined')
helper = src[i:src.index('\n}\n', i)] if i > 0 else ''
check('ios_wow_window_count' in helper and '.dead' in helper and '.leaked' in helper and 'IOS_WOW_WINDOW_SIZE' in helper,
      'it scans every slot and skips dead or leaked windows')
check('int ios_wow_in_any_window( const void *addr ) { return 0; }' in src, 'non-iOS stub')
g = src[src.index('static int ios_guest_image_is_host_data( const void *base, size_t size )'):]
g = g[:g.index('\n}\n')]
check(g.index('if (!ios_wow_in_window( base ))') < g.index('ios_wow_in_any_window( base )'),
      'the current-window test still comes first; any-window is the fallback')
check('MADEIRA_GUEST_IMAGE_ANYWIN' in g and "e[0] == '0'" in g, 'off switch MADEIRA_GUEST_IMAGE_ANYWIN=0')
check('[guest-image-anywin]' in g and 'rev=wow-image-anywindow' in g and 'anywin_n <= 8' in g, 'capped log line')
check('return (view->protect & SEC_IMAGE) != 0;' in g, 'still only SEC_IMAGE views count')
cc = shutil.which('cc') or shutil.which('gcc')
if cc and i > 0:
    body = helper[helper.index('{') + 1:]
    prog = '''#include <stdio.h>
typedef unsigned long ULONG_PTR;
#define IOS_WOW_WINDOW_SIZE 0x100000000UL
struct w { ULONG_PTR base; int dead, leaked; } ios_wow_windows[4];
unsigned ios_wow_window_count;
static int anywin(const void *addr) {''' + body + '''
}
int main(void) {
    ios_wow_windows[0] = (struct w){0x7100000000UL, 0, 0};
    ios_wow_windows[1] = (struct w){0x7200000000UL, 1, 0};
    ios_wow_windows[2] = (struct w){0x7700000000UL, 0, 1};
    ios_wow_windows[3] = (struct w){0x7800000000UL, 0, 0};
    ios_wow_window_count = 4;
    printf("%d%d%d%d%d\\n", anywin((void*)0x716c770000UL), anywin((void*)0x726c770000UL), anywin((void*)0x776c770000UL),
           anywin((void*)0x786c770000UL), anywin((void*)0x140000000UL));
    return 0;
}
'''
    with tempfile.TemporaryDirectory() as t:
        Path(t, 'x.c').write_text(prog)
        r = subprocess.run([cc, '-Wall', '-o', t + '/x', t + '/x.c'], capture_output=True, text=True)
        check(r.returncode == 0, 'scan rule compiles on the host' + ('' if r.returncode == 0 else '\n' + r.stderr[-500:]))
        if r.returncode == 0:
            out = subprocess.run([t + '/x'], capture_output=True, text=True).stdout.strip()
            check(out == '10010', 'live windows count, dead/leaked ones and x64 addresses do not (got %s)' % out)
else:
    print('SKIP: no host C compiler')
print('FAIL' if fails else 'PASS'); sys.exit(1 if fails else 0)
