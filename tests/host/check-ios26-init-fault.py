#!/usr/bin/env python3
"""ios26-init-fault: the iOS 26 start-crash diagnostic in server_ios.c. A SA_SIGINFO SIGSEGV/SIGBUS
handler is armed for the first process start only (before the request fd is received, disarmed after
init_first_thread), logs the step, fault address, pc/lr/sp and their symbols to stderr, then puts the
previous handlers back so the fault ends the run exactly as before. Source checks plus a small C model
of the arm -> fault -> hand-back sequence."""
import os, subprocess, sys, tempfile
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
S = open(os.path.join(ROOT, 'build/ntdll-unix/server_ios.c'), encoding='utf-8').read()
fails = 0
def check(cond, text):
    global fails
    print(('PASS: ' if cond else 'FAIL: ') + text)
    if not cond: fails += 1

check('getenv( "MADEIRA_INIT_FAULT_DIAG" )' in S and "e[0] == '0' && !e[1]" in S, 'off switch env.MADEIRA_INIT_FAULT_DIAG = 0')
check('sa.sa_flags = SA_SIGINFO;' in S and 'SA_ONSTACK' not in S[S.find('static void ios_init_fault_arm'):S.find('static void ios_init_fault_disarm')],
      'SA_SIGINFO, and not on the alternate stack (a suspect)')
check('sigaction( SIGSEGV, &sa, &ios_init_old_segv )' in S and 'sigaction( SIGBUS, &sa, &ios_init_old_bus )' in S, 'both SIGSEGV and SIGBUS, previous handlers saved')
h = S[S.find('static void ios_init_fault_handler'):S.find('static void ios_init_fault_arm')]
check('sigaction( SIGSEGV, &ios_init_old_segv, NULL );' in h and 'sigaction( SIGBUS, &ios_init_old_bus, NULL );' in h
      and 'abort' not in h and '_exit' not in h, 'the handler hands the fault back to the old handlers (run ends as before)')
check('write( 2, buf' in h and 'wine_log_write' not in h, 'the handler writes with write(2), no logger locks')
check('arm_thread_state64_get_pc( uc->uc_mcontext->__ss )' in h and '__es.__far' in h, 'pc/lr/sp/far from the Darwin arm64 context')
i_arm = S.find('    ios_init_fault_arm();'); i_wait = S.find('[Wine init_process] waiting for request_fd from wineserver...")')
i_got = S.find('[Wine init_process] got request_fd=%d'); i_pipe = S.find('    reply_pipe = init_thread_pipe();')
i_dis = S.find('    ios_init_fault_disarm();'); i_ret = S.find('[Wine init_process] init_first_thread ret=%d')
check(S.count('    ios_init_fault_arm();') == 1 and 0 < i_arm < i_wait < i_got < i_pipe < i_ret < i_dis, 'armed once, before the request fd; disarmed after init_first_thread')
check(S.count('ios_init_fault_disarm();') == 1, 'disarmed in one place only (the first process path)')
for n in range(1, 9):
    check(f'ios_init_set_step( {n}, ' in S, f'step {n} is marked')
t = S[S.find('static int init_thread_pipe(void)'):]
t = t[:t.find('\n}\n')]
check(t.find('ios_init_set_step( 3,') < t.find('sigaltstack( &ss, NULL );') < t.find('ios_init_set_step( 4,') < t.find('server_pipe( reply_pipe )')
      < t.find('ios_init_set_step( 5,') < t.find('server_pipe( ntdll_get_thread_data()->wait_fd )') < t.find('ios_init_set_step( 6,')
      < t.find('ios_init_set_step( 7,') < t.find('wine_server_send_fd( reply_pipe[1] );'), 'steps 3-7 bracket each call in init_thread_pipe')
check('if (ios_init_fault_on) wine_log_write( "[init-step] %d %s", n, name );' in S, 'other threads (init_thread_pipe runs per thread) log nothing')

code = r'''
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <stdlib.h>
static struct sigaction old_segv, old_bus; static int on, ours, olds; static char *page;
static void oldh(int s){ olds++; mprotect(page, 4096, PROT_READ|PROT_WRITE); }
static void h(int s, siginfo_t *si, void *uc){ ours++; on = 0; sigaction(SIGSEGV, &old_segv, NULL); sigaction(SIGBUS, &old_bus, NULL); }
int main(void){ struct sigaction sa, o; memset(&o, 0, sizeof o); o.sa_handler = oldh; sigaction(SIGSEGV, &o, NULL); sigaction(SIGBUS, &o, NULL);
  page = mmap(0, 4096, PROT_READ, MAP_PRIVATE|MAP_ANON, -1, 0);
  memset(&sa, 0, sizeof sa); sigemptyset(&sa.sa_mask); sa.sa_sigaction = h; sa.sa_flags = SA_SIGINFO;
  sigaction(SIGSEGV, &sa, &old_segv); sigaction(SIGBUS, &sa, &old_bus); on = 1;
  *(volatile int *)page = 1;   /* ours logs, hands back; the store re-faults under the old handler */
  struct sigaction now; sigaction(SIGSEGV, NULL, &now);
  int bad = !(ours == 1 && olds == 1 && on == 0 && now.sa_handler == oldh);
  printf(bad ? "model FAIL ours=%d old=%d\n" : "model ok ours=%d old=%d\n", ours, olds); return bad; }
'''
d = tempfile.mkdtemp(); c = os.path.join(d, 'm.c'); open(c, 'w').write(code)
r = subprocess.run(['cc', '-o', os.path.join(d, 'm'), c], capture_output=True, text=True)
ok = r.returncode == 0 and subprocess.run([os.path.join(d, 'm')]).returncode == 0
check(ok, 'model: one fault -> our handler once, then the SAME fault reaches the old handler once; old handler is back in place')
print('check-ios26-init-fault: ' + ('PASS' if not fails else f'{fails} FAILED'))
sys.exit(1 if fails else 0)
