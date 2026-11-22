#!/usr/bin/env python3
"""Host check for d3d12-root-params-64 (madeira-d3d12/src/pe/madeira_d3d12.c).

Static anchors, plus the layout rule worked through in Python: the converter's
top-level argument layout (mad_root_layout: 4 bytes per root constant, 8 per
table or root descriptor, 8-byte aligned, then 8 for the static-sampler table)
must end at or before MAD_ARG_DRAWPARAMS_OFF, or the root arguments would
overwrite the draw parameters in the per-draw argument slot."""
import re, sys
from pathlib import Path
root = Path(__file__).resolve().parents[2]
src = (root / 'madeira-d3d12/src/pe/madeira_d3d12.c').read_text()
fails = 0
def check(c, label):
    global fails
    print(('PASS: ' if c else 'FAIL: ') + label); fails += (not c)

m = re.search(r'#define MAD_ROOT_PARAM_MAX (\d+)', src); pmax = int(m.group(1)) if m else 0
check(pmax == 64, 'MAD_ROOT_PARAM_MAX is 64')
m = re.search(r'#define MAD_LOC_MAX (\d+)', src); lmax = int(m.group(1)) if m else 0
check(lmax >= pmax + 1, 'MAD_LOC_MAX holds every root parameter plus the static-sampler table entry (%d >= %d)' % (lmax, pmax + 1))
m = re.search(r'#define MAD_ARG_DRAWPARAMS_OFF (\d+)u', src); dp = int(m.group(1)) if m else 0
m = re.search(r'#define MAD_ARG_SLOT_BYTES +(\d+)u', src); slot = int(m.group(1)) if m else 0
check(dp == 512 and slot == 1088, 'argument slot unchanged (draw params at 512 of 1088)')
check('UINT offsets[32]' not in src, 'no root-layout prototype still sized [32]')
body = src[src.index('static int mad_root_layout_fits(const struct mad_rootsig *rs, const char *who) {'):]
body = body[:body.index('\n}\n')]
check('if (rs->nsamplers) end = ((end + 7) & ~7u) + 8;' in body and 'end <= MAD_ARG_DRAWPARAMS_OFF' in body,
      'mad_root_layout_fits counts the static-sampler slot and compares with MAD_ARG_DRAWPARAMS_OFF')
cr = src[src.index('static HRESULT device_CreateRootSignature_impl(ID3D12Device *This, UINT node,', src.index('static HRESULT STDMETHODCALLTYPE device_CreateRootSignature') ):]
cr = cr[:cr.index('\ntruncated:')]
check('if (!mad_root_layout_fits(r, "CreateRootSignature"))' in cr and cr.index('mad_root_layout_fits') < cr.index('rootsig_QI('),
      'CreateRootSignature refuses a too-large layout before handing the object out')
check('[d3d12-root-params-64]' in src, 'log tag [d3d12-root-params-64]')

def layout(params, nsamplers):
    off = 0
    for kind, n in params:
        if kind == 'c': off = (off + 3) & ~3; off += 4 * n
        else: off = (off + 7) & ~7; off += 8
    if nsamplers: off = ((off + 7) & ~7) + 8
    return off
def fits(params, ns): return layout(params, ns) <= dp
def dwords(params): return sum(n if k == 'c' else (1 if k == 't' else 2) for k, n in params)
cases = [
    ('Cyberpunk-like 36 tables + samplers', [('t', 1)] * 36, 4, True),
    ('64 tables, no samplers (D3D12 max)', [('t', 1)] * 64, 0, True),
    ('64 tables + samplers (refused: 520 > 512)', [('t', 1)] * 64, 2, False),
    ('63 tables + samplers', [('t', 1)] * 63, 2, True),
    ('32 root CBVs (64 DWORDs) + samplers', [('d', 1)] * 32, 1, True),
    ('64 root constants in one param', [('c', 64)], 1, True),
]
for name, ps, ns, want in cases:
    check(dwords(ps) <= 64, '%s is a legal D3D12 signature (%d DWORDs)' % (name, dwords(ps)))
    check(fits(ps, ns) == want, '%s: layout %d bytes -> %s' % (name, layout(ps, ns), 'accepted' if want else 'refused'))
# every legal D3D12 signature with <= 63 parameters fits: worst case is all tables (8 bytes each) + samplers
check(all(fits([('t', 1)] * n, 1) for n in range(1, 64)), 'every all-tables signature up to 63 parameters fits with static samplers')
print('FAIL' if fails else 'PASS'); sys.exit(1 if fails else 0)
