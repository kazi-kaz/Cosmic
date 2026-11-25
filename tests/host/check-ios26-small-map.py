#!/usr/bin/env python3
"""ios26-small-map: on a map that ends at or below 0x7000000000 (iOS 26 without extended VA,
63 GB) the guest band, the usable floor and the cage holdback follow the real map; a 512 GB map
keeps exactly the old numbers. Source checks plus a small C model of the band decisions."""
import os, re, subprocess, sys, tempfile
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
V = open(os.path.join(ROOT, 'build/ntdll-unix/virtual_ios.c'), encoding='utf-8').read()
S = open(os.path.join(ROOT, 'build/ntdll-unix/signal_arm64_ios.c'), encoding='utf-8').read()
fails = 0
def check(cond, text):
    global fails
    print(('PASS: ' if cond else 'FAIL: ') + text)
    if not cond: fails += 1

check('uintptr_t ios_guest_band_lo = 0x7000000000ULL, ios_guest_band_hi = 0x8000000000ULL;' in V
      and 'uintptr_t ios_guest_band_pc_lo = 0x7000000000ULL;' in V, 'the bands start as the 512 GB ones')
check('getenv( "MADEIRA_SMALL_MAP_FIX" )' in V and "e[0] == '0'" in V, 'off switch env.MADEIRA_SMALL_MAP_FIX = 0')
check('(uintptr_t)host_addr_space_limit <= 0x7000000000ULL' in V, 'small map = the map ends at or below 0x7000000000')
i_set = V.find('host_addr_space_limit = get_host_addr_space_limit();'); i_small = V.find('ios_small_map = 1;')
check(0 < i_set < i_small, 'the small-map decision comes after host_addr_space_limit is known')
check('if (ios_small_map)\n        dprintf( 2, "[small-map] cage holdback skipped' in V
      and 'else if (anon_mmap_fixed( (void *)(uintptr_t)IOS_CAGE_BASE' in V, 'the cage holdback is skipped on a small map only')
check(V.count('if (ios_small_map) return ios_small_map_floor;') == 1
      and '>= 0x800000000ULL ? IOS_SMALL_MAP_FLOOR : IOS_TINY_MAP_FLOOR' in V, 'the usable floor is 16 GB on a small map, 8 GB when it ends below 32 GB')
check('[va-limit] using the probed top %p' in V and '(UINT_PTR)walked - probed > (256ULL << 20)' in V
      and 'probed >= 0x100000000ULL' in V, 'the probed top replaces an over-reading walk (more than 256 MB, at least 4 GB)')
check('if (ios_small_map) { LO = ios_small_map_floor; HI = ios_guest_band_hi; }' in V, 'the furniture census follows the map on a small map')
check('*floor = ios_usable_va_floor_big();' in V, 'ios_wow_band still tests with the 512 GB floor (its small-map branch is unchanged)')
check('0x7000000000ull && p < 0x8000000000ull' not in S and '0x7000000000ull && a < 0x8000000000ull' not in S,
      'ios_fault_is_foreign has no hard-coded band left')
check('p >= ios_guest_band_pc_lo && p < ios_guest_band_hi' in S and 'a >= ios_guest_band_lo && a < ios_guest_band_hi' in S,
      'ios_fault_is_foreign tests the device band')
check('[small-map] declined fault pc=%p addr=%p' in S, 'a declined fault on a small map is logged with its range and thread')

# model of the decisions (same constants as the C)
code = r'''
#include <stdio.h>
#include <stdint.h>
static int small; static uintptr_t lo = 0x7000000000ULL, hi = 0x8000000000ULL, pclo = 0x7000000000ULL;
static void init(uintptr_t limit, int off) { small = 0; lo = 0x7000000000ULL; hi = 0x8000000000ULL; pclo = 0x7000000000ULL;
  if (!off && limit && limit <= 0x7000000000ULL) { lo = 0x100000000ULL; hi = limit; pclo = 0x400000000ULL; small = 1; } }
static int ours_addr(uintptr_t a) { return a >= lo && a < hi; }
static int ours_pc(uintptr_t p) { return p >= pclo && p < hi; }
int main(void) {
  int bad = 0;
  init(0x8000000000ULL, 0); bad |= small || !ours_addr(0x71fffe0000ULL) || ours_addr(0xfbffe0000ULL) || ours_pc(0x101a6d658ULL);
  init(0xfc0000000ULL, 0);  bad |= !small || !ours_addr(0xfbffe0000ULL) || !ours_addr(0x13ffe0000ULL) || !ours_addr(0x3fffe0000ULL)
                                  || ours_addr(0x71fffe0000ULL) || ours_pc(0x101a6d658ULL) || !ours_pc(0x800000000ULL);
  init(0xfc0000000ULL, 1);  bad |= small || ours_addr(0xfbffe0000ULL);
  printf(bad ? "model FAIL\n" : "model ok\n"); return bad; }
'''
d = tempfile.mkdtemp(); c = os.path.join(d, 'm.c'); open(c, 'w').write(code)
r = subprocess.run(['cc', '-o', os.path.join(d, 'm'), c], capture_output=True, text=True)
ok = r.returncode == 0 and subprocess.run([os.path.join(d, 'm')]).returncode == 0
check(ok, '512 GB map: band and pcs as before; 63 GB map: TEBs at 0x13ffe0000/0x3fffe0000/0xfbffe0000 are guest, the app image is not; switch off = old band')
print('check-ios26-small-map: ' + ('PASS' if not fails else f'{fails} FAILED'))
sys.exit(1 if fails else 0)
