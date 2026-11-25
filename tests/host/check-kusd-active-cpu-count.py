#!/usr/bin/env python3
"""Host check for kusd-active-cpu-count (build/ntdll-unix/virtual_ios.c).

virtual_init_user_shared_data writes KUSER_SHARED_DATA.ActiveProcessorCount from
peb->NumberOfProcessors; on the [kusd-fill] path that runs before the PEB is set up, so it
was 0. The fix only acts when the value is 0, takes sysconf(_SC_NPROCESSORS_ONLN), caps it
at 64, logs it, and has an off switch. Also compiles and runs the selection rule on the host."""
import os, re, shutil, subprocess, sys, tempfile
from pathlib import Path
root = Path(__file__).resolve().parents[2]
src = (root / 'build/ntdll-unix/virtual_ios.c').read_text()
fails = 0
def check(c, label):
    global fails
    print(('PASS: ' if c else 'FAIL: ') + label); fails += (not c)
fn = src[src.index('void virtual_init_user_shared_data(void)'):]
fn = fn[:fn.index('\n}\n')]
i = fn.find('kusd-active-cpu-count:')
check(i > 0, 'fix is inside virtual_init_user_shared_data')
blk = fn[i:fn.index('#endif', i)]
check(fn.index('data->ActiveProcessorCount  = peb->NumberOfProcessors;') < i, 'the normal value is still written first (PEB count wins when it is set)')
check('if (!data->ActiveProcessorCount)' in blk and blk.count('data->ActiveProcessorCount =') == 1, 'acts only when the count is 0 (one write, inside that test)')
check('sysconf( _SC_NPROCESSORS_ONLN )' in blk and 'if (n > 64) n = 64;' in blk, 'host online cores, capped at 64 (one group)')
check('MADEIRA_KUSD_CPU_COUNT' in blk and "e[0] == '0'" in blk, 'off switch MADEIRA_KUSD_CPU_COUNT=0')
check('[kusd-cpu-count]' in blk and 'rev=kusd-active-cpu-count' in blk, 'log line [kusd-cpu-count]')
check(fn.index('kusd-active-cpu-count:') < fn.index('data->ActiveGroupCount'), 'before ActiveGroupCount (inside the field block)')
cc = shutil.which('cc') or shutil.which('gcc') or shutil.which('clang')
if cc:
    body = blk[blk.index('if (!data->ActiveProcessorCount)'):]
    prog = r'''#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
typedef unsigned long ULONG;
struct { ULONG ActiveProcessorCount; } d, *data = &d;
#define dprintf(fd, ...) fprintf(stderr, __VA_ARGS__)
static void fill(void) {
''' + body + r'''
}
int main(int argc, char **argv) {
    d.ActiveProcessorCount = (ULONG)atol(argv[1]);
    fill();
    printf("%lu\n", d.ActiveProcessorCount);
    return 0;
}
'''
    with tempfile.TemporaryDirectory() as t:
        Path(t, 'x.c').write_text(prog)
        r = subprocess.run([cc, '-Wall', '-o', t + '/x', t + '/x.c'], capture_output=True, text=True)
        check(r.returncode == 0, 'selection rule compiles on the host' + ('' if r.returncode == 0 else '\n' + r.stderr[-600:]))
        if r.returncode == 0:
            host = os.sysconf('SC_NPROCESSORS_ONLN')
            run = lambda v, env=None: subprocess.run([t + '/x', str(v)], capture_output=True, text=True, env=env).stdout.strip()
            check(run(0) == str(min(host, 64)), 'count 0 becomes the host core count (%s)' % min(host, 64))
            check(run(6) == '6', 'a PEB count of 6 is kept')
            env = dict(os.environ, MADEIRA_KUSD_CPU_COUNT='0')
            check(run(0, env) == '0', 'MADEIRA_KUSD_CPU_COUNT=0 keeps 0')
else:
    print('SKIP: no host C compiler for the selection rule')
print('FAIL' if fails else 'PASS'); sys.exit(1 if fails else 0)
