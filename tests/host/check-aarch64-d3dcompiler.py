#!/usr/bin/env python3
"""Host check for beamng-arm64-d3dcompiler: the aarch64 farm gets d3dcompiler_47.dll (BeamNG.drive's native ARM64 exe imports it),
linked into system32 only for a native ARM64 target, never for WoW64 i386 ones, and env.MADEIRA_AARCH64_D3DCOMPILER = 0 turns it off.
With the built DLL at app/Madeira/aarch64-windows/d3dcompiler_47.dll (or the path given), also checks it is an ARM64 PE."""
import json, re, struct, sys, os
root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
fails = 0
def ok(c, m):
    global fails
    print(("PASS " if c else "FAIL ") + m); fails += (not c)
comp = json.load(open(root + "/tools/build/runtime-components.json"))
text = json.dumps(comp)
ok("aarch64-windows/d3dcompiler_47.dll" in text, "runtime-components.json lists aarch64-windows/d3dcompiler_47.dll")
src = open(root + "/app/Madeira/WineProcessBridge.m", encoding="utf-8").read()
i = src.index("const BOOL skip_aa64_d3dc")
seg = src[i - 900:i + 1100]
ok("!use_arm64ec" in seg and "is_i386_target" in seg and 'madeira_cfg_off_word(getenv("MADEIRA_AARCH64_D3DCOMPILER"))' in seg, "skipped for arm64ec and i386 targets and by env.MADEIRA_AARCH64_D3DCOMPILER = 0")
ok("caseInsensitiveCompare:@\"d3dcompiler_47.dll\"" in seg and "removeItemAtPath" in seg, "skip clears the system32 link so the old arm64ec link returns")
dll = sys.argv[1] if len(sys.argv) > 1 else root + "/app/Madeira/aarch64-windows/d3dcompiler_47.dll"
if os.path.exists(dll):
    d = open(dll, "rb").read(); pe = struct.unpack_from("<I", d, 0x3c)[0]
    ok(struct.unpack_from("<H", d, pe + 4)[0] == 0xaa64, "the DLL is an ARM64 PE (0xaa64): " + dll)
else:
    print("SKIP the DLL is not at " + dll + " (the build puts it there from the t30 overrides)")
print("fails: %d" % fails); sys.exit(1 if fails else 0)