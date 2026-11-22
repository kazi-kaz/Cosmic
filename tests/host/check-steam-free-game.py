#!/usr/bin/env python3
"""[steam-free] Add a Free Game: the Steam store page asks Steam for a free license
(ClientRequestFreeLicense 5572 -> 5573), then rereads the library until the game shows."""
import os, re, sys
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
def read(p): return open(os.path.join(ROOT, 'app/Madeira', p), encoding='utf-8').read()
proto, fetch, lib, ui = (read('SwiftSteam/Core/SteamProtocol.swift'), read('SwiftSteam/Library/SteamLibraryFetcher.swift'),
                         read('SteamOwnedLibrary.swift'), read('SteamGames.swift'))
fails = []
def check(ok, what):
    print(('PASS' if ok else 'FAIL') + ': ' + what)
    if not ok: fails.append(what)

check('case clientRequestFreeLicense = 5572' in proto and 'case clientRequestFreeLicenseResponse = 5573' in proto,
      'EMsg numbers 5572/5573 (SteamKit EMsg.ClientRequestFreeLicense / Response)')
i = fetch.index('func requestFreeLicense(appID: UInt32)'); f = fetch[i:i + 2200]
check('request.writeUInt32(fieldNumber: 2, value: appID)' in f, 'request puts the app in field 2 (appids)')
check('responseEMsg: .clientRequestFreeLicenseResponse' in f, 'waits for the response by job id')
check('case (1, .varint): result' in f and '(2, .lengthDelimited)' in f and '(3, .lengthDelimited)' in f,
      'response reads eresult (1), granted packages (2) and apps (3), packed or not')
check('[steam-free] request app=' in f, 'logs each request')
j = lib.index('func addFreeGame(_ text: String) async -> String'); a = lib[j:j + 4200]
check('!inSession' in a and 'signedIn' in a, 'never asks while signed out or while a game session holds the account')
check('if let game = game(Int(appID))' in a and a.index('if let game = game(Int(appID))') < a.index('requestFreeLicense'),
      'a game already in the library is not asked for again')
check('answer.eresult == 1' in a and 'for attempt in 1...4' in a and 'refreshLibrary(interactive: false)' in a,
      'only a real grant rereads the library, at most 4 times')
box = read('SwiftSteam/Core/LicenseListBox.swift'); sess = read('SwiftSteam/Core/SteamSession.swift')
check('if result == 1, !packages.isEmpty { session.addGrantedLicenses(packages) }' in f
      and 'func addGrantedLicenses(_ packageIDs: [UInt32])' in sess and 'guard var list = packageIDs else { return }' in box,
      'granted packages join the license list at once (no wait for Steam to push a new list)')
check('keepFreeApps(answer.grantedApps.isEmpty ? [appID] : answer.grantedApps)' in a
      and a.index('keepFreeApps(') < a.index('refreshLibrary(interactive: false)'),
      'a granted app is kept before the library is read (Steam grants TF2 as an app, no package: Test 15 log)')
r = lib[lib.index('func refreshLibrary(interactive: Bool = true) async {'):]
r = r[:r.index('writeCache()')]
check('let extra = freeApps().filter { !known.contains($0) }' in r and 'fetcher.fetchAppInfos(appIDs: extra)' in r
      and r.index('apps += infos') < r.index('let games = apps.filter(\\.installableOnWindows)'),
      'every library read adds the kept free apps before the Windows filter')
check('saved.account == account' in lib and 'removeItem(at: Self.freeAppsURL)' in lib,
      'kept free apps belong to one Steam account and go away on sign-out')
check('while refreshing && waited < 40' in a, 'a library read already running is waited for, not skipped')
check('installable=' in a and 'no Windows download Madeira can install' in a and 'Pull down on the Library' in a,
      'when the game still is not listed, Steam app info says which: no Windows download, or refresh')
check('expectNewLicenseList' not in lib and 'licenseListBox.reset' not in fetch,
      'the license list is never cleared (a refusal must not leave the library waiting)')
check('if fold && signedIn {' in ui and 'id: "steam-add-free"' in ui and 'await steam.addFreeGame(text)' in ui,
      'the button is on the Steam store page only, signed in, and goes through addFreeGame')

# Mirror of SteamOwnedLibrary.freeGameAppID on the inputs players paste.
def app_id(text):
    text = text.strip()
    if re.fullmatch(r'[0-9]+', text):
        n = int(text); return n if 0 < n <= 0xFFFFFFFF else None
    k = text.find('/app/')
    if k < 0: return None
    d = re.match(r'[0-9]*', text[k + 5:]).group(0)
    if not d: return None
    n = int(d); return n if 0 < n <= 0xFFFFFFFF else None
cases = {'440': 440, ' 440\n': 440, 'https://store.steampowered.com/app/440/Team_Fortress_2/': 440,
         'store.steampowered.com/app/440': 440, 'https://steamdb.info/app/570/': 570, '0': None,
         'tf2': None, 'https://store.steampowered.com/app/': None, '99999999999': None}
check(all(app_id(k) == v for k, v in cases.items()), 'app ID from a number or a /app/<id> link (mirror of the Swift)')
check('UInt32(text), id > 0' in lib and 'text.range(of: "/app/")' in lib and '$0.isASCII && $0.isNumber' in lib,
      'the Swift parser has the same three steps as the mirror')
# Request bytes for app 440: field 2 varint -> 0x10, 440 -> b8 03.
def varint(n):
    out = b''
    while True:
        b = n & 0x7f; n >>= 7
        out += bytes([b | (0x80 if n else 0)])
        if not n: return out
check(varint(2 << 3 | 0) + varint(440) == bytes([0x10, 0xb8, 0x03]), 'request body for TF2 is 10 b8 03')
sys.exit(1 if fails else 0)
