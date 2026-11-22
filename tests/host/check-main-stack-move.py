#!/usr/bin/env python3
"""[main-stack-move] opt-in startup stack move (Civilization VII, 896 MB fixed-base exe): checks the
C, header and Swift pieces are present and the switch is off by default."""
import os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
rd = lambda p: open(os.path.join(ROOT, p), encoding='utf-8').read()
c, h, sw, sj = rd('app/Madeira/JITAllocator.c'), rd('app/Madeira/JITAllocator.h'), rd('app/Madeira/MadeiraApp.swift'), rd('app/Madeira/StikJITHelper.swift')
checks = [
    ('madeira_cfg_bool("main-stack-move", 0)' in c, 'off by default; on only with main-stack-move = 1'),
    ('info.user_tag != 30' in c and 'hi > 0x148000000ul && lo < 0x180000000ul' in c, 'only a VM tag 30 stack that sits in the window path'),
    ('0x13f000000ul' in c and 'MSM_STACK_SIZE (8ul << 20)' in c.replace('#define MSM_STACK_SIZE   ', '#define MSM_STACK_SIZE ') , 'new 8MB stack below the executable window'),
    (c.index('madeira_msm_dup_vec(*pe)') < c.index('"mov sp, %0'), 'environ and argv are copied before the switch'),
    ('return 0;' in c[c.index('int madeira_run_on_new_stack'):], 'returns 0 (nothing changed) when it cannot'),
    ('int madeira_run_on_new_stack(void (*fn)(void));' in h and 'madeira_main_stack_move_wanted' in h, 'declared in JITAllocator.h'),
    ('static func main()' in sw and 'madeira_main_stack_move_wanted() != 0' in sw and 'T.main()' in sw, 'MadeiraApp.main() runs the default App main, on the new stack only when asked'),
    ('[main-stack-move]' in sj, 'the result is logged'),
]
bad = 0
for ok, t in checks:
    print(('PASS: ' if ok else 'FAIL: ') + t); bad += not ok
sys.exit(1 if bad else 0)
