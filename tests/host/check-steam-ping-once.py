#!/usr/bin/env python3
"""[steam-ping] SteamConnection.connect resumes its ping continuation once (Sentry B8 SIGTRAP)."""
import os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
s = open(os.path.join(ROOT, 'app/Madeira/SwiftSteam/Core/SteamConnection.swift'), encoding='utf-8').read()
i = s.index('task.sendPing { error in'); body = s[i:i + 600]
ok = ('let once = PingResumeOnce()' in s[i - 400:i] and 'guard once.claim() else {' in body
      and body.index('guard once.claim()') < body.index('cont.resume')
      and 'private final class PingResumeOnce' in s and 'if done { return false }' in s)
print(('PASS' if ok else 'FAIL') + ': the ping completion claims a once-flag before it resumes the continuation')
sys.exit(0 if ok else 1)
