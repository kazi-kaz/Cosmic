#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""(recommended-after-get-help) GameRecommendationsApply.swift: Get Help's and Madeira's own lines at the end of a
config no longer stop a recommended list from being written or updated, and lines the player wrote stay.

Static anchors on the Swift source, plus a Python port of splitAdded/due/put run over the cases from the Nov 15
Sentry reports (Stardew with only Get Help's lines; Slay the Spire 2 with the standard list plus Get Help's lines).
"""
import sys, zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
src = (ROOT / 'app/Madeira/GameRecommendationsApply.swift').read_text(encoding='utf-8')
fails = 0
def check(c, t):
    global fails
    print(('PASS: ' if c else 'FAIL: ') + t)
    if not c: fails += 1

check('static func splitAdded(_ text: String) -> (base: String, tail: String)' in src
      and 'r.hasPrefix("# Get Help added these") || r.hasPrefix("# Added by Madeira:")' in src
      and 'guard let i = rows.firstIndex(where: { isAddedHeader($0) }) else { return (text, "") }' in src, 'splitAdded names both headers and leaves a config without them whole')
check('let tail = kind == .reset ? "" : splitAdded(file.text).tail' in src and 'guard file.text == want' in src, 'put keeps the additions below the list; a reset writes the list alone')
check('[recommended] \\(title): only Get Help' in src, 'log marker for the new case')

HDRS = ('# Get Help added these', '# Added by Madeira:')
def split(text):
    rows = text.split('\n')
    if rows and rows[-1] == '': rows.pop()
    idx = next((i for i, r in enumerate(rows) if r.strip().startswith(HDRS)), None)
    if idx is None: return text, ''
    head = rows[:idx]
    while head and not head[-1].strip(): head.pop()
    return ('\n'.join(head) + '\n' if head else ''), '\n'.join(rows[idx:]) + '\n'
h = lambda t: format(zlib.crc32(t.encode()), 'x')   # stand-in for LibraryPrefs.stableHash

def due(mark, text, rec_text, own=''):
    """returns the file text after prepare(), or None when nothing is written"""
    base, tail = split(text)
    if mark == '':
        if base.strip() or not tail.strip() or own.strip(): return None
    elif mark is not None:
        if mark == 'now' or not mark.endswith('#' + h(base)): return None
    elif (base + own).strip():
        return None
    return rec_text if not tail else rec_text + '\n' + tail

NEW = "# Madeira's recommended settings for Stardew Valley.\nenv.MADEIRA_ANON_CAS_FLUSH = 1\nenv.MADEIRA_CTX_CPU_AREA = 2\n"
GH = "\n# Get Help added these on Nov 15. Undo: Game details > Advanced > Undo Get Help\n# Try: join two free memory spaces\npool-split = 1\n"
std = "# Madeira's recommended settings for a game without a list of its own.\nenv.MADEIRA_EC_HOOK_TRACE = 0\n"
# Stardew: kept at first sight (mark ""), only Get Help's lines now
check(due('', GH, NEW) == NEW + GH, 'Stardew case: only Get Help lines, mark "": list goes above them')
check(due(None, GH, NEW) == NEW + GH, 'first sight with only Get Help lines gets the list')
check(due('', '', NEW) is None, 'a config the player emptied stays empty')
check(due('', 'pool = 896\n' + GH, NEW) is None, 'a config with a player line above the additions stays')
# Slay the Spire 2: standard list written, Get Help lines below, the game's own list arrives
check(due('standard#1#' + h(std), std + GH, NEW) == NEW + GH, 'StS2 case: standard list + Get Help lines, the game list replaces the standard one, lines kept')
check(due('standard#1#' + h(std), std.replace('= 0', '= 1') + GH, NEW) is None, 'the player changed a line of the written list: stays')
hand = GH + 'env.MADEIRA_FOO = 1\n'
check(due('', hand, NEW) == NEW + hand, 'a line the player typed below the Get Help comment is kept')
check(split(std) == (std, ''), 'no header: all base, unchanged')
print('PASS' if not fails else 'FAILED')
sys.exit(1 if fails else 0)
