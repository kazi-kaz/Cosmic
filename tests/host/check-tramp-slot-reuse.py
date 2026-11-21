#!/usr/bin/env python3
"""Trampoline slots of exited threads are reused once the fresh slots run out.

Ported from Spark (check-thread-slot-reuse.py, trampoline half). Upstream
Madeira hands out IOS_JIT_MAX_SLOTS slots once each; the next thread used to
share slot 0 with the first thread. ios_alloc_thread_trampoline (in
build/ntdll-unix/signal_arm64_ios.c) takes a fresh slot first, then the slot of
an exited thread, then slot 0. Compiles the production functions with stubs.
"""
import subprocess, sys, tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[2]
source = (root / 'build/ntdll-unix/signal_arm64_ios.c').read_text()
virtual = (root / 'build/ntdll-unix/virtual_ios.c').read_text()

def function(text, signature):
    start = text.index(signature)
    return text[start:text.index('\n}', start) + 2] + '\n'

assert 'ios_my_slot = ios_alloc_thread_trampoline( pthread_mach_thread_np( pthread_self() ) );' in source
alloc = function(virtual, 'int ios_jit_alloc_trampoline_slot_or_fail(void)')
assert alloc.count('return -1;') == 2
legacy = function(virtual, 'int ios_jit_alloc_trampoline_slot(void)')
assert 'return 0;  /* fallback to slot 0 */' in legacy
assert 'int ios_jit_trampoline_slot_limit(void)' in virtual

code = r'''
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
typedef unsigned int thread_t;
typedef int kern_return_t;
typedef unsigned int mach_msg_type_number_t;
typedef int *thread_info_t;
struct thread_basic_info { int dummy[10]; };
#define THREAD_BASIC_INFO 3
#define THREAD_BASIC_INFO_COUNT 10
#define KERN_INVALID_ARGUMENT 4
#define KERN_TERMINATED 37
#define MACH_SEND_INVALID_DEST 0x10000003
#define MACH_PORT_RIGHT_SEND 0
#define ERR(...) ((void)0)
static unsigned char dead[100000];
static kern_return_t thread_info( thread_t port, int f, thread_info_t o, mach_msg_type_number_t *n )
{ (void)f; (void)o; (void)n; return dead[port] ? MACH_SEND_INVALID_DEST : 0; }
static int mach_task_self(void) { return 0; }
static int mach_port_mod_refs( int t, thread_t p, int r, int d ) { (void)t; (void)p; (void)r; (void)d; return 0; }
static int next_fresh, limit = 8;
static int ios_jit_alloc_trampoline_slot_or_fail(void) { return next_fresh < limit ? next_fresh++ : -1; }
static int ios_jit_trampoline_slot_limit(void) { return limit; }
static thread_t ios_tramp_owner[1024];
'''
code += function(source, 'static int ios_tramp_port_dead(')
code += function(source, 'static int ios_alloc_thread_trampoline(')
code += r'''
#define CHECK(c, ...) do { if (!(c)) { fprintf( stderr, __VA_ARGS__ ); return 1; } } while (0)
int main( void )
{
    int i, s;
    for (i = 0; i < 8; i++) CHECK( ios_alloc_thread_trampoline( 100 + i ) == i, "fresh slot %d\n", i );
    CHECK( ios_alloc_thread_trampoline( 200 ) == 0, "all live: slot 0\n" );
    dead[100] = 1;                       /* slot 0's owner: never reused */
    CHECK( ios_alloc_thread_trampoline( 201 ) == 0, "slot 0 reused\n" );
    dead[105] = 1;
    s = ios_alloc_thread_trampoline( 202 );
    CHECK( s == 5, "dead owner's slot not reused (%d)\n", s );
    CHECK( ios_alloc_thread_trampoline( 203 ) == 0, "slot 5 handed out twice\n" );
    dead[202] = 1;                       /* the new owner exits too */
    CHECK( ios_alloc_thread_trampoline( 204 ) == 5, "second reuse\n" );
    setenv( "MADEIRA_TRAMP_REUSE", "0", 1 );
    puts( "ok" );
    return 0;
}
'''
with tempfile.TemporaryDirectory() as tmp:
    src = Path(tmp) / 't.c'; exe = Path(tmp) / 't'
    src.write_text(code)
    subprocess.run(['cc', '-std=gnu11', '-Wall', '-Werror', '-Wno-unused-function', '-o', str(exe), str(src)], check=True)
    r = subprocess.run([str(exe)], capture_output=True, text=True)
    if r.returncode: print(r.stdout + r.stderr); sys.exit(1)
print('PASS tramp-slot-reuse')
