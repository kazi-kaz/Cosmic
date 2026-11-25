#!/usr/bin/env python3
"""Host check for img-protect-probe (build/ntdll-unix/virtual_ios.c): a LOG-ONLY line in
NtProtectVirtualMemory for image views other than the main program. Static anchors:
it only reads (get_page_vprot after the call), changes no status or protection,
sits before the virtual_mutex is released, is capped, and has an off switch."""
import re, sys
from pathlib import Path
root = Path(__file__).resolve().parents[2]
src = (root / 'build/ntdll-unix/virtual_ios.c').read_text()
fails = 0
def check(c, label):
    global fails
    print(('PASS: ' if c else 'FAIL: ') + label); fails += (not c)
fn = src[src.index('NTSTATUS WINAPI NtProtectVirtualMemory( HANDLE process, PVOID *addr_ptr, SIZE_T *size_ptr,'):]
fn = fn[:fn.index('\n}\n')]
i = fn.find('img-protect-probe (LOG ONLY)')
check(i > 0, 'probe present in NtProtectVirtualMemory')
blk = fn[i:fn.index('#endif', i)]
check('rev=img-protect-probe' in blk and '[img-protect]' in blk, 'log tag [img-protect] with rev=img-protect-probe')
check('MADEIRA_IMG_PROTECT_PROBE' in blk and "e[0] == '0'" in blk, 'off switch MADEIRA_IMG_PROTECT_PROBE=0')
check('probe_n < 64' in blk and 'probe_fail_n < 64' in blk, 'capped at 64 calls + 64 failures')
check('view->protect & SEC_IMAGE' in blk and '!(cur_peb && cur_peb->ImageBaseAddress == view->base)' in blk,
      'only image views that are not the main program (that one already has [prot-img])')
check('SUCCESS-BUT-NOT-WRITABLE' in blk and 'get_page_vprot( base )' in blk, 'names a call that succeeded but left the page unwritable')
# log only: no assignment to status, old, new_prot or protections inside the block
code = re.sub(r'"(?:[^"\\]|\\.)*"', '""', blk)                       # string literals out (the format has "old=%#x")
code = re.sub(r'/\*.*?\*/', '', code, flags=re.S)                     # comments out
check(not re.search(r'(?<![\w.>])(status|old|new_prot|size|base)\s*=[^=]|set_protection|set_vprot|mprotect', code),
      'changes nothing (no status/prot/size/base writes)')
check(fn.index('img-protect-probe (LOG ONLY)') < fn.index('server_leave_uninterrupted_section( &virtual_mutex, &sigset );'),
      'runs while virtual_mutex is still held (view stays valid)')
print('FAIL' if fails else 'PASS'); sys.exit(1 if fails else 0)
