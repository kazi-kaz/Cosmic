#!/usr/bin/env python3
# Host check for player-id (Madeira app). Run from the repo root.
import re,sys
bad=0
def check(c,m):
    global bad
    print(('ok   ' if c else 'FAIL ')+m); bad+= (not c)
v=open('app/Madeira/GetHelpView.swift').read()
check('MadeiraConfig.flag("MADEIRA_PLAYER_ID")' in v,'off switch env.MADEIRA_PLAYER_ID = 0')
check('guard playerIDOn' in v,'playerID is nil when off')
check('get-help-install-id' in v and 'static func resetPlayerID' in v,'Reset ID makes a fresh install id')
check('Int($0) % idAlphabet.count' in v and 'UIDevice' not in v.split('Player ID')[1].split('installID')[0] if 'Player ID' in v else True,'no hardware identifier used')
g=open('app/Madeira/GetHelp.swift').read()
check('var install_id: String' in g and 'var player_id: String? = nil' in g and 'request.player_id = GetHelp.playerID' in v,'player_id sent beside install_id')
check('env.MADEIRA_PLAYER_ID' in open('app/Madeira/ConfigCatalog.generated.swift').read(),'switch is in the config catalog')
check('Player ID' in open('app/Madeira/NewLook.swift').read(),'Settings row')
check('[player-id]' in open('app/Madeira/ContentView.swift').read(),'log line')
sys.exit(1 if bad else 0)
