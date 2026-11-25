#!/usr/bin/env python3
"""[early-pool] the image-load constructor holds a pool placeholder above a mapping that blocks
the run directly above the 0x140000000 window (Sentry 8A); unchanged when that run was obtained."""
import os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
s = open(os.path.join(ROOT, 'app/Madeira/JITAllocator.c'), encoding='utf-8').read()
f = s[s.index('static void madeira_early_va_claim(void)'):]
f = f[:f.index('\n}\n') + 3]
checks = [
    ('if (!madeira_early_pool_size && madeira_cfg_bool("early-pool-above", 1))' in f, 'only when no placeholder was obtained; off with early-pool-above = 0'),
    (f.index('madeira_early_intruder_base = ra') < f.index('early-pool-above'), 'the blocking mapping is still recorded first (ml1135 log line unchanged)'),
    ('start >= 0x190000000ul' in f and 'start + sz > 0x190000000ul' in f, 'stays below 0x190000000'),
    ('for (sz = 1152ul << 20; sz >= (256ul << 20); sz -= (16ul << 20))' in f, '1152MB down to 256MB in 16MB steps'),
    ('hop < 8' in f, 'at most 8 regions skipped'),
    ('for (sz = 1024ul << 20; sz >= (256ul << 20); sz -= (16ul << 20)) {\n        a = win + winsz;' in f, 'the first try directly above the window is unchanged'),
]
bad = 0
for ok, t in checks:
    print(('PASS: ' if ok else 'FAIL: ') + t); bad += not ok
sys.exit(1 if bad else 0)
