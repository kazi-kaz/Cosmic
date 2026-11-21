#!/usr/bin/env python3
"""A syscall stub that calls through a still-NULL dispatcher slot is recognised.

Cosmic, 2026-11-20: MX Bikes started through Madeira Dock crashed at PC 0.
comctl32 called win32u's syscall 0x10a7 before win32u's DllMain had filled
win32u's __wine_syscall_dispatcher. The stub before the return address was
    d28214e8 movz x8,#0x10a7 / aa1e03e9 mov x9,x30 / 90000290 adrp x16 /
    f9401610 ldr x16,[x16,#0x28] / d63f0200 blr x16
with lr = 0x157f94184, and the slot it loaded was 0x157fe4028.

Compiles ios_syscall_stub_slot() (between the ios-syscall-slot markers in
build/ntdll-unix/signal_arm64_ios.c) with the host compiler, checks it
against those values and refuses look-alikes, and checks the wiring.
"""
import subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / "build/ntdll-unix/signal_arm64_ios.c").read_text(encoding="utf-8")
fn = source[source.index("/* ios-syscall-slot:begin"):source.index("/* ios-syscall-slot:end */")]

harness = r'''
#include <stdint.h>
#include <stdio.h>
''' + fn + r'''
static int fails;
#define CHECK(w, lr, want) do { uint64_t g = ios_syscall_stub_slot((w), (lr)); \
    if (g != (want)) { printf("FAIL %s: got %#llx want %#llx\n", #w, (unsigned long long)g, (unsigned long long)(want)); fails++; } } while (0)
int main(void)
{
    const uint32_t mx[5]     = { 0xd28214e8, 0xaa1e03e9, 0x90000290, 0xf9401610, 0xd63f0200 };
    const uint32_t run2[5]   = { 0xd28214e8, 0xaa1e03e9, 0x90000290, 0xf9401610, 0xd63f0200 };
    const uint32_t no_mov8[5]= { 0xd28214e9, 0xaa1e03e9, 0x90000290, 0xf9401610, 0xd63f0200 };
    const uint32_t no_x9[5]  = { 0xd28214e8, 0xaa1e03ea, 0x90000290, 0xf9401610, 0xd63f0200 };
    const uint32_t x17[5]    = { 0xd28214e8, 0xaa1e03e9, 0x90000291, 0xf9401631, 0xd63f0220 };
    const uint32_t br[5]     = { 0xd28214e8, 0xaa1e03e9, 0x90000290, 0xf9401610, 0xd61f0200 };
    CHECK(mx, 0x157f94184ull, 0x157fe4028ull);     /* run 1 */
    CHECK(run2, 0x1352f4184ull, 0x135344028ull);   /* run 2: same stub, other pool address */
    CHECK(no_mov8, 0x157f94184ull, 0);
    CHECK(no_x9, 0x157f94184ull, 0);
    CHECK(x17, 0x157f94184ull, 0);
    CHECK(br, 0x157f94184ull, 0);
    if (fails) return 1;
    puts("ok");
    return 0;
}
'''
with tempfile.TemporaryDirectory() as tmp:
    src = Path(tmp) / "s.c"; exe = Path(tmp) / "s"
    src.write_text(harness)
    subprocess.run(["cc", "-std=c99", "-Wall", "-Werror", "-o", str(exe), str(src)], check=True)
    r = subprocess.run([str(exe)], capture_output=True, text=True)
    if r.returncode: print(r.stdout + r.stderr); sys.exit(1)

tgt = source[source.index("static uint64_t ios_syscall_slot_target( uint64_t pc, uint64_t lr, uint64_t x8, uint64_t x9 )"):]
tgt = tgt[:tgt.index("\n}\n")]
assert "ios_fault_pc_is_jit( lr - 20 )" in tgt, "only stubs in the JIT pool or region C"
assert "|| value)" in tgt, "only a slot that is really NULL"
assert tgt.index("return (uint64_t)(uintptr_t)__wine_syscall_dispatcher;") > tgt.index("|| value)")
assert 'getenv( "MADEIRA_SYSCALL_SLOT" )' in tgt
# Claimed on the Mach exception thread, right after the state fetch and before
# the sub-floor service, every diagnostic and the guest-exception delivery.
mach = source[source.index("static void *ios_mach_exception_thread( void *arg )"):]
claim = mach.index("ios_syscall_slot_target( 0, state.__lr, state.__x[8], state.__x[9] )")
assert mach.index("kr = thread_get_state( thread, ARM_THREAD_STATE64,") < claim
assert claim < mach.index("ml939: THE SUB-FLOOR SERVICE BELONGS HERE")
assert claim < mach.index("ios_mach_deliver_guest_exception( thread, &state,")
block = mach[claim:mach.index("goto cosmic_exc_reply;", claim)]
assert "__darwin_arm_thread_state64_set_pc_fptr( state, (void *)(uintptr_t)target );" in block
assert "thread_set_state( thread, ARM_THREAD_STATE64, (thread_state_t)&state, count );" in block
assert "handled = 1;" in block
assert mach.index("cosmic_exc_reply:") < mach.index("reply.ret_code = handled ? KERN_SUCCESS : KERN_FAILURE;")
assert "ios_syscall_slot_recover" not in source, "the segv_handler path is gone (ml939)"
print("PASS syscall-slot")
