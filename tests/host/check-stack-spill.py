#!/usr/bin/env python3
"""Thread stacks: MADEIRA_THREAD_STACK_SPILL and MADEIRA_SMALL_STACK_EXES (virtual_ios.c); no Wine runs.

RDR2 (build 460, log 2026-10-08 23:59:11) froze when the furniture band was
full: every CreateThread of RDR2.exe's main thread failed at the 1 MB kernel
stack, which init_thread_stack asks for with limit_low = limit_4g. Because
address_space_start is reset to 0x10000 for a 64-bit program, map_view did
not count that 4 GB floor as relaxable, so the request scanned the low map
from 4 GB and ended in STATUS_NO_MEMORY instead of the kernel's pick.

Compiles ios_stack_spill_enabled, ios_exe_name_in_list and
ios_thread_stack_floor against a fake PEB and checks:
  - the spill switch is on only for MADEIRA_THREAD_STACK_SPILL=1;
  - the stack floor is 8 MB unless the calling program's exe name is in
    MADEIRA_SMALL_STACK_EXES (case-insensitive, comma or semicolon list,
    spaces around names ignored, whole names only), then 2 MB;
and textually that map_view makes a limit_low at or below 4 GB relaxable
only through the switch, logs a spilled placement, and that
virtual_alloc_thread_stack keeps 8 MB for everyone else.
[stack-spill-auto] (nine logs, the owner's Deep Rock Galactic DX12 run among them: "[thr-create]
FAILED at emulator stack" with "[slot#2] 0x7800000000+16GB CLEAR"): without the switch, the same
request takes the kernel's pick only after the band has refused it; MADEIRA_STACK_SPILL_AUTO=0
turns that off.
Needs python3 and a C compiler (CC, default cc).
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
src = (root / 'build/ntdll-unix/virtual_ios.c').read_text()


def chunk(start_marker, end_marker):
    start = src.index(start_marker)
    return src[start:src.index(end_marker, start)]


spill = chunk('static int ios_stack_spill_enabled(void)', '/***********************************************************************\n *           map_view')
floor = chunk('#define IOS_SMALL_STACK_FLOOR', '/***********************************************************************\n *           virtual_alloc_thread_stack')

harness = r'''
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
typedef uint16_t WCHAR;
typedef size_t SIZE_T;
typedef struct { unsigned short Length, MaximumLength; WCHAR *Buffer; } UNICODE_STRING;
typedef struct { UNICODE_STRING ImagePathName; } RTL_USER_PROCESS_PARAMETERS;
typedef struct { RTL_USER_PROCESS_PARAMETERS *ProcessParameters; } PEB;
static PEB *fake_peb;
static void *ios_jit_current_peb(void) { return fake_peb; }
''' + spill + floor + r'''
static WCHAR wbuf[260];
int main(int argc, char **argv)
{
    static RTL_USER_PROCESS_PARAMETERS pp;
    static PEB peb;
    size_t i, n = strlen(argv[1]);

    for (i = 0; i < n; i++) wbuf[i] = (unsigned char)argv[1][i];
    pp.ImagePathName.Buffer = wbuf;
    pp.ImagePathName.Length = (unsigned short)(n * sizeof(WCHAR));
    peb.ProcessParameters = &pp;
    fake_peb = argc > 2 ? NULL : &peb;
    printf("spill=%d floor=%zu auto=%d\n", ios_stack_spill_enabled(), (size_t)ios_thread_stack_floor(),
           ios_stack_spill_auto_enabled());
    return 0;
}
'''

cc = os.environ.get('CC', 'cc')
MB = 1024 * 1024
with tempfile.TemporaryDirectory(prefix='madeira-stack-spill-') as directory:
    c = Path(directory) / 's.c'
    exe = Path(directory) / 's'
    c.write_text(harness)
    build = subprocess.run([cc, '-std=gnu11', '-Wall', '-Werror', '-Wno-unused-function',
                            '-fsanitize=address,undefined', '-o', str(exe), str(c)], capture_output=True, text=True)
    assert build.returncode == 0, build.stdout + build.stderr

    def run(path, env_extra, no_peb=False):
        env = {k: v for k, v in os.environ.items() if not k.startswith('MADEIRA_')}
        env.update(env_extra)
        args = [str(exe), path] + (['nopeb'] if no_peb else [])
        r = subprocess.run(args, capture_output=True, text=True, env=env)
        assert r.returncode == 0, r.stdout + r.stderr
        return r

    rdr2 = 'C:\\Program Files (x86)\\Steam\\steamapps\\common\\Red Dead Redemption 2\\RDR2.exe'
    helper = 'C:\\Program Files\\Rockstar Games\\Social Club\\SocialClubHelper.exe'
    for value, on in ((None, 0), ('0', 0), ('yes', 0), ('11', 0), ('1', 1)):
        r = run(rdr2, {} if value is None else {'MADEIRA_THREAD_STACK_SPILL': value})
        assert f'spill={on} ' in r.stdout, (value, r.stdout)
        assert ('[stack-spill] MADEIRA_THREAD_STACK_SPILL=1' in r.stderr) == bool(on), (value, r.stderr)
    print('PASS: the 4 GB-floor spill is on only with MADEIRA_THREAD_STACK_SPILL=1')

    for value, on in ((None, 1), ('1', 1), ('', 1), ('0', 0), ('00', 0), ('no', 1)):
        r = run(rdr2, {} if value is None else {'MADEIRA_STACK_SPILL_AUTO': value})
        assert f' auto={on}\n' in r.stdout, (value, r.stdout)
    print('PASS: the after-failure spill is on unless MADEIRA_STACK_SPILL_AUTO starts with 0')

    cases = (
        (rdr2, None, 8 * MB),
        (rdr2, '', 8 * MB),
        (rdr2, 'RDR2.exe', 2 * MB),
        (rdr2, 'rdr2.EXE', 2 * MB),
        (rdr2, 'GTA5.exe, RDR2.exe', 2 * MB),
        (rdr2, ' RDR2.exe ;PlayRDR2.exe', 2 * MB),
        (rdr2, 'DR2.exe', 8 * MB),
        (rdr2, 'RDR2.ex', 8 * MB),
        (rdr2, 'RDR2.exe2', 8 * MB),
        (helper, 'RDR2.exe', 8 * MB),
        ('RDR2.exe', 'RDR2.exe', 2 * MB),
        ('C:/games/RDR2.exe', 'RDR2.exe', 2 * MB),
        (rdr2, ',;', 8 * MB),
    )
    for path, value, want in cases:
        r = run(path, {} if value is None else {'MADEIRA_SMALL_STACK_EXES': value})
        assert f'floor={want}' in r.stdout, (path, value, r.stdout)
    r = run(rdr2, {'MADEIRA_SMALL_STACK_EXES': 'RDR2.exe'}, no_peb=True)
    assert f'floor={8 * MB}' in r.stdout, r.stdout
    print('PASS: only programs named in MADEIRA_SMALL_STACK_EXES get the 2 MB floor; unknown callers keep 8 MB')

mv = src[src.index('static NTSTATUS map_view( struct file_view **view_ret, void *base, size_t size,'):]
mv = mv[:mv.index('\n}\n')]
assert 'ceiling_relaxable = (limit_low <= (ULONG_PTR)address_space_start);\n' \
       '            /* madeira-bcd: [stack-spill] — see ios_stack_spill_enabled */\n' \
       '            if (!ceiling_relaxable && limit_low <= limit_4g && ios_stack_spill_enabled())\n' \
       '                ceiling_relaxable = stack_spill = 1;' in mv, 'map_view: a 4 GB floor is relaxable only through the switch'
assert mv.count('stack_spill = 1') == 1 and 'int stack_spill = 0;' in mv
tail = mv[mv.index('ptr = unmap_extra_space( ptr, view_size, host_size, align_mask );'):]
assert tail.index('if (stack_spill)') < tail.index('done:'), 'the spill log follows the kernel pick'
print('PASS: map_view treats a 4 GB floor as absent only with the switch and logs a spilled placement')

# [stack-spill-auto]: marked where the switch is not set, used only at the failure, logged after the kernel's pick
assert ('                ceiling_relaxable = stack_spill = 1;\n'
        '            /* [stack-spill-auto] — see ios_stack_spill_auto_enabled */\n'
        '            else if (!ceiling_relaxable && limit_low <= limit_4g && ios_stack_spill_auto_enabled())\n'
        '                stack_spill_late = 1;\n') in mv
assert mv.count('stack_spill_late') == 7 and 'int stack_spill_late = 0;' in mv
# the [va-scan] line of a request that will take the late spill says so, and does not spend the failure budget
assert mv.count('(ceiling_relaxable || stack_spill_late) ?') == 2
fail = ('            if (!ceiling_relaxable && !stack_spill_late)\n'
        '            {\n'
        '                ios_af_set( 2, ios_scan_fail_errno, ios_scan_fail_addr, size );\n'
        '                return STATUS_NO_MEMORY;\n'
        '            }\n'
        '            if (!ceiling_relaxable) stack_spill_late = 2;')
assert fail in mv, 'the band\'s refusal is the only place the late spill acts'
# every scan of the band comes before it: the late spill cannot change a placement the band can make
for scan in ('if ((ptr = map_reserved_area( start, end, host_size, top_down, unix_prot, align_mask )))',
             'ptr = map_free_area( start, end, host_size, top_down, unix_prot, align_mask );'):
    assert mv.index(scan) < mv.index(fail), scan
assert mv.index(fail) < mv.index('if ((ptr = anon_mmap_alloc( view_size, unix_prot )) == MAP_FAILED)')
assert tail.index('if (stack_spill_late == 2)') < tail.index('done:') and '[stack-spill-auto] #%lu' in tail
assert 'if (!ceiling_relaxable && limit_low <= limit_4g && ios_stack_spill_enabled())' in mv   # the switch still wins
print('PASS: map_view gives a refused 4 GB-floor request the kernel\'s pick only after every scan of the band failed, and logs it')

vats = src[src.index('NTSTATUS virtual_alloc_thread_stack( INITIAL_TEB *stack,'):]
vats = vats[:vats.index('\n}\n')]
assert 'SIZE_T min_size = ios_thread_stack_floor();' in vats
assert 'size = max( size, min_size );' in vats and 'size = 8 * 1024 * 1024;' in vats
assert vats.index('ios_thread_stack_floor()') < vats.index('map_view(')
print('PASS: virtual_alloc_thread_stack takes the floor from ios_thread_stack_floor and keeps 8 MB otherwise')
