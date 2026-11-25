#!/usr/bin/env python3
"""Host check for illegal-x64-bytes (log only). Usage: check-illegal-x64-bytes.py <tree root>"""
import sys, re
root = sys.argv[1] if len(sys.argv) > 1 else "."
s = open(root + "/build/ntdll-unix/signal_arm64_ios.c").read()
ok = True
def check(n, c):
    global ok
    print(("PASS " if c else "FAIL ") + n); ok &= bool(c)
i = s.find("rev=illegal-x64-bytes: the [illegal-insn]")
blk = s[i:i+3600] if i >= 0 else ""
check("marker + block present", i >= 0 and "[illegal-x64] c000001d" in blk)
check("only for c000001d", "rec->ExceptionCode == 0xc000001d" in blk)
check("every read via mach_vm_read_overwrite, no raw deref of rip/state",
      blk.count("mach_vm_read_overwrite") >= 4 and not re.search(r"\*\s*\(\s*(uint64_t|unsigned char)\s*\*\s*\)\s*(rip|state|cpuarea)", blk))
check("capped at 6 per session", "<= 6" in blk)
check("off switch MADEIRA_ILLEGAL_X64_BYTES", 'getenv( "MADEIRA_ILLEGAL_X64_BYTES" )' in blk)
check("writes nothing (no context-> / sigcontext)", "context->" not in blk and "sigcontext" not in blk)
sys.exit(0 if ok else 1)
