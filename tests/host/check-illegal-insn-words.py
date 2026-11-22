#!/usr/bin/env python3
"""Host check for illegal-insn-words (log only). Usage: check-illegal-insn-words.py <tree root>"""
import sys, re
root = sys.argv[1] if len(sys.argv) > 1 else "."
s = open(root + "/build/ntdll-unix/signal_arm64_ios.c").read()
ok = True
def check(n, c):
    global ok
    print(("PASS " if c else "FAIL ") + n); ok &= bool(c)
i = s.find("rev=illegal-insn-words: an illegal")
blk = s[i:i+2600] if i >= 0 else ""
check("marker + block present", i >= 0 and "[illegal-insn] c000001d" in blk)
check("only for c000001d", "rec->ExceptionCode == 0xc000001d" in blk)
check("reads with mach_vm_read_overwrite (cannot fault)", "mach_vm_read_overwrite" in blk)
check("capped at 6 per session", "<= 6" in blk)
check("off switch MADEIRA_ILLEGAL_INSN_WORDS", "MADEIRA_ILLEGAL_INSN_WORDS" in blk)
check("writes nothing (no store through pc / context)", not re.search(r"\*\s*\(?\(?[a-z_ ]*\*?\)?\s*pc\s*=", blk) and "context->" not in blk)
sys.exit(0 if ok else 1)
