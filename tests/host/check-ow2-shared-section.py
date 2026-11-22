#!/usr/bin/env python3
"""ow2-shared-section: Battle.net's list turns on the shared-section path, and that path still keeps a pagefile-backed
x64 section view out of the JIT pool (no ml634 PRE-REMAP) while FEX is told about the executable view by map-exec-view."""
import pathlib, re, subprocess, sys
root = pathlib.Path(__file__).resolve().parents[2]
ok = True
def check(name, cond):
    global ok
    print(('PASS ' if cond else 'FAIL ') + name); ok &= bool(cond)
v = (root / 'build/ntdll-unix/virtual_ios.c').read_text()
f = v[v.index('static int ios_guest_section_is_host_data('):]
f = f[:f.index('\n}\n') + 3]
check('the switch is opt-in, exactly "1"', "s && s[0] == '1' && !s[1]" in v[v.index('static int ios_shared_section_exec_enabled('):][:400])
check('only pagefile-backed sections, never images/files/EC code/system views', 'SEC_COMMIT | SEC_RESERVE' in f and 'SEC_FILE | SEC_IMAGE | VPROT_ARM64EC | VPROT_SYSTEM' in f)
check('never a view in a 32-bit window or native EC code', 'ios_alloc_ec_code || ios_wow_in_window( base )' in f)
me = v[v.index('static inline int mprotect_exec('):]
sec = me.index('ios_guest_section_is_host_data( base, size )')
check('the section test comes before the ml634 pool copy', sec < me.index('ml634'))
check('it drops only the host exec bit', 'unix_prot &= ~PROT_EXEC;' in me[sec:sec + 600])
wine = root / 'wine'
src = None
try:   # the branch's own wine pin (a worktree's wine folder may be another checkout)
    pin = subprocess.run(['git', '-C', str(root), 'rev-parse', 'HEAD:wine'], capture_output=True, text=True).stdout.strip()
    src = subprocess.run(['git', '-C', str(wine), 'show', pin + ':dlls/ntdll/signal_arm64ec.c'], capture_output=True, text=True).stdout
except Exception:
    pass
if not src:
    p = wine / 'dlls/ntdll/signal_arm64ec.c'
    src = p.read_text() if p.exists() else ''
check('wine pin tells FEX about executable data-section views (map-exec-view)', '[map-exec-view]' in src and 'pNotifyMemoryProtect( addr, size, protect, TRUE, STATUS_SUCCESS );' in src)
g = (root / 'app/Madeira/GameRecommendations.swift').read_text()
bn = g[g.index('static let battleNet = GameRecommendation('):]
bn = bn[:bn.index('""",')]
check("Battle.net's list (v9) turns it on", 'version: 9' in bn and 'env.MADEIRA_SHARED_SECTION_EXEC = 1' in bn)
def body(m):
    start = g.index('config: """', m.start()) + len('config: """')
    return g[start:g.index('"""', start)]
others = [m.group(1) for m in re.finditer(r'static let (\w+) = GameRecommendation\(', g)
          if 'env.MADEIRA_SHARED_SECTION_EXEC = 1' in body(m)]
check('no other list turns it on', others == ['battleNet'])
sys.exit(0 if ok else 1)
