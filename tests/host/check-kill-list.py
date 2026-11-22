#!/usr/bin/env python3
"""(kill-list) KillList.swift static checks, no compiler needed (the build thread adds the swiftc run on the PC).
Run from the repo root after applying kill-list-wiring.patch and adding KillList.swift to app/Madeira/."""
import re, sys
from pathlib import Path
R = Path(__file__).resolve().parents[2] if (Path(__file__).resolve().parents[2] / 'app').exists() else Path('.')
app = R / 'app' / 'Madeira'
src = (app / 'KillList.swift').read_text()
fails = 0
def check(ok, what):
    global fails
    print(('ok   ' if ok else 'FAIL ') + what); fails += 0 if ok else 1
check('MadeiraConfig.flag("MADEIRA_KILLLIST")' in src, 'switch env.MADEIRA_KILLLIST read with MadeiraConfig.flag (default on)')
check('setenv($0, "0", 0)' in src, 'only ever sets "0", overwrite = 0 (a cfg line wins)')
check(src.count('setenv(') == 1, 'one setenv call only')
check('SharedConfigs.verify(data, signature: sig)' in src and src.count('SharedConfigs.verify') >= 2, 'download and kept file are both signature-checked')
check('isCatalogSwitch' in src and '$0.kind == .bool' in src, 'only catalog on/off switches count')
check('"MADEIRA_KILLLIST"' in src and 'neverKill' in src, 'the list cannot turn off itself')
check('appendingPathComponent("shared/killlist")' in src, 'GET /shared/killlist')
m = (app / 'MadeiraApp.swift').read_text()
check(m.index('KillList.apply()') < m.index('ExternalDisplay.watch()'), 'apply() is the first thing in MadeiraApp.init')
check('KillList.refresh()' in m, 'refresh at start-up')
pbx = (R / 'app' / 'Madeira.xcodeproj' / 'project.pbxproj').read_text() if (R / 'app' / 'Madeira.xcodeproj' / 'project.pbxproj').exists() else ''
check(pbx.count('KillList.swift') == pbx.count('SharedConfigs.swift'), 'KillList.swift is in the Xcode project the same number of times as SharedConfigs.swift')
gen = (app / 'ConfigCatalog.generated.swift').read_text()
check('key: "env.MADEIRA_KILLLIST"' in gen, 'env.MADEIRA_KILLLIST is in the settings catalog (run build/tools/gen-config-catalog.py)')
sys.exit(1 if fails else 0)
