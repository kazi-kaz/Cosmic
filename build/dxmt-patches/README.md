# Madeira's DXMT patches

Changes to DXMT (the `dxmt` submodule) that live in this repository until
they are in DXMT's own repository. `apply.sh` applies them, in file-name
order, to the `dxmt` working tree before `build/dxmt-ios/build.sh` (the
native Direct3D 9 frontend in `libdxmt_combined.a`),
`build/wine-i386/build.sh` (the 32-bit DLLs) and
`build/windows-runtime/build.sh` (the 64-bit DLLs) build DXMT; it skips a
patch that is already applied, and `apply.sh --revert` takes them out. The
`dxmt` submodule pin does not change.

| Patch | What it fixes |
|---|---|
| `0001-winemetal-arm64ec-wine-11.22-icall-helper.patch` | Cosmic, for Madeira 0.2.72 / Wine 11.22. The ARM64EC `winemetal.dll` failed to link with `duplicate symbol: __icall_helper_arm64ec`. Wine 11.22's `libwinecrt0` no longer carries the CHPE metadata, so the toolchain's `chpe.o` is linked as well, and both define the same helper. The ARM64EC link now allows that one duplicate (same routine; lld keeps `chpe.o`'s). |

The two earlier patches (`d3d9-index-range-per-draw`, `d3d11-video-device-fallback`) are in the 0.2.72 `dxmt` pin itself.

A patch must apply on the current `dxmt` pin. When the pin moves, rebase the
patches onto it (or drop a patch the new pin already covers).
