#!/bin/bash
# Configure and build FEX's aarch64 WOW64 module (libwow64fex.dll,
# shipped as xtajit.dll), the CPU backend wow64.dll loads for 32-bit x86
# programs. See docs/WOW64.md, "Building". The options are the iOS host build's:
# FEX_IOS_HOST_BUILD turns on the 32-bit guest window (ENABLE_GUEST_WINDOW),
# which FEX refuses for the ARM64EC module.
set -eu
# Cosmic: tune FEX for Apple A13 and newer (COSMIC_PROFILE=stock: Madeira's
# original tuning). COSMIC_LTO=1 also turns on link-time optimisation.
if [ "${COSMIC_PROFILE:-fast}" = stock ]; then COSMIC_FEX_CPU=none; else COSMIC_FEX_CPU=apple-a13; fi
if [ "${COSMIC_LTO:-0}" = 1 ]; then COSMIC_FEX_LTO=ON; else COSMIC_FEX_LTO=OFF; fi
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PATH="$R/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin:$PATH"
B="$R/FEX/build-wow64"
# Madeira's own FEX changes (build/fex-patches/README.md).
bash "$R/build/fex-patches/apply.sh"
cmake -S "$R/FEX" -B "$B" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_DISABLE_FIND_PACKAGE_fmt=ON -DCMAKE_DISABLE_FIND_PACKAGE_range-v3=ON \
    -DCMAKE_DISABLE_FIND_PACKAGE_unordered_dense=ON \
    -DCMAKE_TOOLCHAIN_FILE="$R/FEX/Data/CMake/toolchain_mingw.cmake" \
    -DMINGW_TRIPLE=aarch64-w64-mingw32 \
    -DFEX_IOS_HOST_BUILD=ON -DCMAKE_C_FLAGS=-DFEX_IOS_HOST \
    -DCMAKE_CXX_FLAGS=-DFEX_IOS_HOST -DCMAKE_ASM_FLAGS=-DFEX_IOS_HOST \
    -DENABLE_LTO="$COSMIC_FEX_LTO" -DENABLE_ASSERTIONS=OFF -DENABLE_JEMALLOC_GLIBC_ALLOC=OFF \
    -DBUILD_TESTING=OFF -DBUILD_FEXCONFIG=OFF -DTUNE_ARCH=generic -DTUNE_CPU="$COSMIC_FEX_CPU" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build "$B" --target wow64fex
cp "$B/Bin/libwow64fex.dll" "$R/app/Madeira/aarch64-windows/xtajit.dll" && ls -l "$R/app/Madeira/aarch64-windows/xtajit.dll"
