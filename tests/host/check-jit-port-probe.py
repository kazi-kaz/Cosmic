#!/usr/bin/env python3
"""Host check for jit-port-probe: LoopbackProbe.check takes a port; helperFailure asks the JIT port (49152) only when the helper
failed as a connection problem, lockdownd answered and LocalDevVPN is up; no answer there is ConnectionProblem.device with its message;
env.MADEIRA_JIT_PORT_PROBE = 0 keeps the old behaviour; the notice offers Pair Again; the texts have six languages."""
import json, os, re, sys
root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
app = root + "/app/Madeira/"
fails = 0
def ok(c, m):
    global fails
    print(("PASS " if c else "FAIL ") + m); fails += (not c)
net = open(app + "JITNetwork.swift", encoding="utf-8").read()
setup = open(app + "JITSetup.swift", encoding="utf-8").read()
ok("static func check(timeout: TimeInterval = 0.4, requireVPN: Bool = true, port: UInt16 = LoopbackProbe.port) -> Result" in net
   and "target(port: port)" in net, "LoopbackProbe.check takes a port (default lockdownd's 62078)")
hf = setup[setup.index("private func helperFailure("):]
hf = hf[:hf.index("    func resetDDI")]
ok("problem == .vpn, loopbackAnswered != false" in hf and "LoopbackProbe.check(timeout: 0.4).reachable" in hf and 'MadeiraConfig.flag("MADEIRA_JIT_PORT_PROBE")' in hf and "LoopbackProbe.vpnInterfaceUp" in hf,
   "asked only when the helper failed as a connection problem, lockdownd answered and the VPN is up, and the switch is on")
ok("timeout: 0.4, port: Self.jitPort" in hf and "private static let jitPort: UInt16 = 49152" in setup, "a 0.4 s probe of port 49152")
ok("[jit-port-probe]" in hf and "problem = probe.reachable ? nil : .device" in hf, "logged; no answer means .device, an answer shows the helper's own words (never .vpn)")
ok(setup.count("helperFailure(response.message)") == 2, "still exactly two helperFailure(response.message) call sites")
enum = setup[setup.index("enum ConnectionProblem"):setup.index("var message: String")]
ok(enum.index("case vpn") < enum.index("case pairing") < enum.index("case device"), "ConnectionProblem order: vpn, pairing, device")
ok("isn't answering for JIT" in setup and "Settings › JIT" in setup, "the message names Settings › JIT")
ok("problem == .pairing || problem == .device" in setup and 'problem == .device ? L("Open LocalDevVPN")' in setup, "a device problem offers Pair Again and Open LocalDevVPN (not Connect)")
cat = open(app + "ConfigCatalog.generated.swift", encoding="utf-8").read()
ok('key: "env.MADEIRA_JIT_PORT_PROBE"' in cat and 'defaultValue: "1"' in cat[cat.index("MADEIRA_JIT_PORT_PROBE"):cat.index("MADEIRA_JIT_PORT_PROBE") + 200], "switch in the catalog, default on")
strings = json.load(open(app + "Localizable.xcstrings", encoding="utf-8"))["strings"]
langs = {"de", "es", "ko", "pt-BR", "ru", "zh-Hans"}
for t in ("LocalDevVPN is on, but this device isn't answering for JIT. Turn LocalDevVPN off and on, use Wi-Fi instead of cellular, or pair again in Settings › JIT.",
          "Turn LocalDevVPN off and on, use Wi-Fi instead of cellular, or pair again."):
    ok(t in strings and langs <= set(strings[t].get("localizations", {})), "six languages: " + t[:40])
print("fails: %d" % fails); sys.exit(1 if fails else 0)