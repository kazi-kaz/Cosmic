# Cosmic's Madeira base

Cosmic merges Madeira releases instead of copying them, so `git log` keeps both sides and the next
update merges again. The upstream line is the `upstream/madeira-*` branch history, starting at the
import of Madeira `fbad430`:

```
c33572e  Import Madeira at willfaust/madeira@fbad430
d642811  Import Madeira Nightly 0.2.72 (willfaust test/wine-1173 @ 08eeff5)   <- branch upstream/madeira-0.2.72
```

Cosmic `main` merges that branch. To pull in a newer Madeira, commit its tree on top of the last
upstream import (not on `main`), then merge it into `main`.

## Madeira Nightly 0.2.72

- Source: the release asset `Madeira.Nightly.0.2.72.source.zip` on
  [camhoc/Madeira `0.2.72-og`](https://github.com/camhoc/Madeira/releases/tag/0.2.72-og). The git tag
  itself points at a docs-only commit with the older code. The zip is the working tree the 0.2.72 IPA
  (`com.willfaust.madeora`, build 150) was built from: branch `test/wine-1173` @ `08eeff5`. That
  branch is not on GitHub.
- Runtime: Wine 11.22, FEX FEX-2611.1-210, DXMT v0.80, madeira-dock `9ce5d63`.
- Tracked binaries the zip leaves out (test programs, `libmetalirconverter.dylib`, GnuTLS archives,
  metallibs) are kept from `fbad430`. CI rebuilds or refreshes them. The Windows DLL farms
  (`app/Madeira/{arm64ec,aarch64}-windows`) are the files in the 0.2.72 IPA. The file list there is
  what `build/windows-runtime/targets.py` builds, and it includes the new aarch64
  `d3dcompiler_47.dll` prebuilt.
- Removed after the import: 19 ARM64EC DLLs (`crtdll`, `d3d8`, `d3dim`, `d3dim700`, `dmband`,
  `dmcompos`, `dmime`, `dmscript`, `dmstyle`, `dplay`, `dplayx`, `dpwsockx`, `msvcp70`, `msvcp71`,
  `msvcr70`, `msvcr71`, `msvcrt20`, `msvcrt40`, `olepro32`). Since Wine 11.20 their Makefiles enable
  only i386 (as on 64-bit Windows), so the windows stage cannot build them. The IPA still had stale
  Wine 11.4 copies from Nov 5. This is the same fix as Madeira's own `f3d5146` on
  `codex/wine-11.20-runtime`. Their 32-bit versions still ship in `i386-windows`.
- Left out: the release's uncommitted edits that only work on the developer's WSL machine. These are
  `tools/build/build-wine.sh` and the moltenvk stage calling scripts in `~/madeira-shims`, `gcc` as
  the host compiler for GnuTLS and LuaJIT, and the dropped `Madeira.debug.dylib` IPA check.

## Submodules

The release's FEX, Wine and DXMT commits were never published. Each tree is committed to a
`madeira-0.2.72` branch in a kazi-kaz fork, on top of the nearest published Madeira branch:

| Submodule | Fork branch | Release commit (unpublished) | Parent |
|---|---|---|---|
| FEX | `kazi-kaz/FEX` `madeira-0.2.72` | `dc3db46` | willfaust `ios-port-2607` (`1dc6ed4`) |
| wine | `kazi-kaz/wine` `madeira-0.2.72` | `9fc8a67` | willfaust `codex/wine-11.20-mobile` (`da527a1`) |
| dxmt | `kazi-kaz/dxmt` `madeira-0.2.72` | `4211e46` | willfaust `codex/dxmt-upstream-port` (`e2cced7`) |
| madeira-dock | `willfaust/madeira-dock` | `9ce5d63` (published) | - |

The trees are the clean commits. The zip had Madeira's build-time patches applied
(`build/fex-patches`, `build/dock-patches`), and those are taken back out, because the build applies
them itself. FEX's three test-binary submodules were not checked out in the release, so they keep
their `ios-port-2607` pins.

## Cosmic changes on top

Compiler profile (README), Spark fixes and Cosmic's own fixes
([COSMIC-SPARK-FIXES.md](COSMIC-SPARK-FIXES.md)). Every change carried over to 0.2.72 unchanged,
with one exception: `server_pipe()` now uses upstream's iOS 27 `pipe2()` guard instead of Spark's
pipe()-always change.
