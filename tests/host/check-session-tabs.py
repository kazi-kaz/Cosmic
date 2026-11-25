#!/usr/bin/env python3
"""The Session menu's tabs (session-tabs): the MADEIRA_SESSION_TABS switch is read, the classic
layout (one page and three sub-pages) is still there for the off switch, and the three tabs exist."""
import os, re, sys
R = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
lib = open(os.path.join(R, "app/Madeira/Library.swift")).read()
gen = open(os.path.join(R, "app/Madeira/ConfigCatalog.generated.swift")).read()
ok = True
def check(cond, what):
    global ok
    print(("ok   " if cond else "FAIL ") + what)
    ok &= bool(cond)

check('MadeiraConfig.flag("MADEIRA_SESSION_TABS")' in lib, "the switch is read (default on)")
check('env.MADEIRA_SESSION_TABS' in gen, "the switch is in the config catalog")
check('if sessionTabs { sessionTabsMenu } else { classicMenu }' in lib, "the switch picks the tabs or the classic menu")
for name in ("classicMenu", "sessionMainScroll", "sessionSubPage", "touchLookRows", "overlayRows", "moreRows"):
    check(re.search(r'\b(var|func) ' + name + r'\b', lib), f"the classic layout keeps {name}")
check('goSession("touch")' in lib and 'goSession("overlay")' in lib and 'goSession("more")' in lib,
      "the classic main page still opens its three sub-pages")
case = re.search(r'enum SessionTab\b.*?\n}\n', lib, re.S)
check(case, "SessionTab exists")
body = case.group(0) if case else ""
for tab in ("Controls", "Display", "Power"):
    check(f'"{tab}"' in body, f"the {tab} tab exists")
check(re.search(r'case controls, display, power', body) and 'sessionTab = SessionTab.controls' in lib.replace("@State private var ", ""),
      "Controls is the default tab")
check('.pickerStyle(.segmented)' in lib[lib.index("private var sessionTabsMenu"):lib.index("private var sessionTabRows") if "private var sessionTabRows" in lib else None],
      "the tabs are a segmented picker")
check('command == "previous" || command == "next"' in lib, "LB / RB switch tabs")
check('private var sessionPageKey' in lib and 'guard key == sessionPageKey' in lib, "the card fits the page of the tab on show")
check(re.search(r'SteamCloudQuitRow\(appID: appID, beside: AnyView\(quit\)\)\s*\.buttonStyle\(\.borderless\)', lib),
      "the Steam Cloud quit row is borderless inside the tabs Form (a tap on its text must not press Replace)")
check(re.search(r'sessionTabs[^\n]*\n?[^\n]*command == "previous"|command == "previous"[^\n]*\n[^\n]*sessionTabs', lib) or 'sessionTabs' in lib[lib.index('command == "previous"') - 400:lib.index('command == "previous"') + 400],
      "LB / RB only switch tabs when the tabs are on")
xc = open(os.path.join(R, "app/Madeira/Localizable.xcstrings"), encoding="utf8").read()
for s in ("Controls", "Power", "Touch buttons", "Show touch buttons", "Edit Layout…", "Mouse & keyboard",
          "Show Keyboard", "Show overlay", "What it shows", "Session section", "Button style"):
    check(f'"{s}" : {{' in xc or f'"{s}": {{' in xc, f"'{s}' is in Localizable.xcstrings")
print("PASS: session tabs wired" if ok else "FAIL: session tabs")
sys.exit(0 if ok else 1)
