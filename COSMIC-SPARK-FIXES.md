# Spark fixes in Cosmic

[Spark](https://github.com/kazi-kaz/Spark) is an Iridium fork whose runtime is
Madeira as of 2026-09-30 (`40d5e748`) plus its own fixes. Cosmic is built on
Madeira `fbad430` (2026-11-12), six weeks newer, so each Spark change was
merged against the newer code rather than copied. Spark's changes to Madeira's
code are GPL-3.0-or-later with the Madeira Converter Exception, like Cosmic.

None of these is device-tested in Cosmic yet. Each keeps a switch.

## Ported

| Fix | Files | Switch |
|---|---|---|
| Truncated 32-bit stack pointers: a fault below 4 GB in translated code is retried with the high bits of the guest RSP (MX Bikes) | `build/ntdll-unix/signal_arm64_ios.c` | `MADEIRA_TRUNC_PTR=0` |
| Trampoline slots of exited threads are reused once the 1024 fresh slots run out, instead of sharing slot 0 with a live thread (long Ren'Py sessions) | `signal_arm64_ios.c`, `virtual_ios.c` | `MADEIRA_TRAMP_REUSE=0` |
| A child process's ntdll copy is kept out of the JIT-pool freelist (stray writes into a reused range; MX Bikes, Pseudoregalia) | `virtual_ios.c` | `MADEIRA_POOL_REUSE_NTDLL=1` reuses |
| Base-relocation directories that are not relocation tables are ignored, and every DIR64 write is bounded to the image (Ren'Py launcher, `pythonw.exe`) | `virtual_ios.c` | - |
| `cmd.exe /c ver` is refused: CPython runs it on every `platform.win32_ver()` and each child cost ~50 MB of pool (Ren'Py 8) | `build/ntdll-unix/process_ios.c` | `MADEIRA_CMD_VER=1` starts it |
| FEX's `0xFExxxxxx` UNIMPLEMENTED() exit codes are named in the log | `process_ios.c` | - |
| `pipe()` + `fcntl()` instead of `pipe2()` on iOS | `process_ios.c`, `server_ios.c` | - |
| Click activation: `GA_ROOT` answering 0 falls back to walking `GA_PARENT`; a press on a window that cannot come to the front is delivered and the window made active in its thread (Ren'Py taps) | `build/win32u-unix/message_ios.c` | `MADEIRA_EAT_UNFOCUSED_CLICK=1` restores Wine's discard |
| The foreground lock does not block a foreground change in the single-game session | `build/wineserver/queue_ios.c` | - |
| The detached desktop's cursor clip follows `MADEIRA_SCREEN_W/H` instead of a fixed 1024x768, and the size is published from `EnumDisplayMonitors` and the virtual-screen metrics | `build/wineserver/window_ios.c`, `build/win32u-unix/sysparams_ios.c` | - |
| `MADEIRA_NO_PROBES` (Spark's Quiet Diagnostics) is accepted as `MADEIRA_PROBES=light` | `server_ios.c` | - |

Host checks from Spark: `tests/host/check-trunc-ptr.py`, `check-ntdll-quarantine.py`,
`check-reloc-dir.py`, `check-cmd-ver.py`, `check-cursor-clip.py`, and
`check-tramp-slot-reuse.py` (the trampoline half of Spark's
`check-thread-slot-reuse.py`), adapted to the newer code where needed.

## Already in Madeira (upstream fixed it its own way)

- Thread-registry reuse (#397, `MADEIRA_THREAD_REUSE`), with a FEX lock-stamp check.
- WoW64 thread TLS and native ARM64 entry points through the JIT-pool copy (Madeira's Wine fork).
- Stale FEX alias entries across processes: each x64 process now has its own alias table (`MADEIRA_ALIAS_PER_PROCESS`).
- Image sections with no room in the JIT pool fail the load (`ios_jit_copy_refused`).
- WASAPI timer pacing on absolute deadlines on a real-time thread (ml1230).
- Guest main thread on a QoS class instead of a fixed priority.
- No foreground window when input arrives (`ios_foreground_check`, click focus).
- Integer store-pair emulation with writeback.
- Spark's ports of Madeira #107, #110, #111, #119, #120, #125, #129, #144 and the OpenGL backend.

## Not ported

- Spark's input coordinate mapping and cursor callback in `driver_ios.c`: they
  belong to Iridium's input layer (client coordinates, `winios_cursor_move`).
- `PYGAME_SDL2_AVOID_GL` and dropping `--windowed` for Ren'Py: Madeira's
  frontend adds no generic launch arguments and now has OpenGL (GLES and Zink).
  `env.PYGAME_SDL2_AVOID_GL=1` in a game's config still sets it.
- `[resv-map]` WoW64 mapping diagnostics (logging only).
- Iridium's app, interface, Steam framework and build system.
