#!/usr/bin/env python3
"""builtin-class-per-process: later pseudo-processes must not skip builtin class
registration because of the atom cached in the shared builtin_classes[] table.
Run from the Madeira root: python3 tests/host/check-builtin-class-per-process.py"""
from pathlib import Path
import sys
root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
src = (root / "build/win32u-unix/class_ios.c").read_text()
rb = src[src.index("static void register_builtin( enum ntuser_client_procs proc )"):]
rb = rb[:rb.index("\n}\n")]
assert "if (descr->atom && !ios_builtin_force) return;" in rb, "cached-atom check must be skipped while forcing"
assert "if (descr->atom) return;" not in rb, "plain cached-atom early return is the regression"
assert "descr->atom = NtUserRegisterClassExWOW" not in rb, "a refused duplicate must not zero the cached atom"
rbc = src[src.index("void register_builtin_classes(void)\n{"):]
rbc = rbc[:rbc.index("\n}\n")]
f_on, f_off = rbc.index("ios_builtin_force = ios_builtin_per_process_enabled();"), rbc.index("ios_builtin_force = 0;")
lock = rbc.rindex("pthread_mutex_lock( &builtin_lock );", 0, f_on)
assert lock < f_on < rbc.index("register_builtins();") < f_off < rbc.rindex("pthread_mutex_unlock( &builtin_lock );"), "force flag set inside the lock, around register_builtins"
assert 'getenv( "MADEIRA_BUILTIN_CLASS_PER_PROCESS" )' in src, "off switch"
print("PASS: builtin classes register in every pseudo-process (off: MADEIRA_BUILTIN_CLASS_PER_PROCESS=0)")
