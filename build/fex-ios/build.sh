#!/bin/bash
# Configure and build the FEXCore static libraries the app links
# (FEX/build-ios/FEXCore/Source/*.a and External/*). Options mirror the
# development build's CMakeCache.
set -eu
# Cosmic: tune FEX for Apple A13 and newer (COSMIC_PROFILE=stock: Madeira's
# original tuning). COSMIC_LTO=1 also turns on link-time optimisation.
if [ "${COSMIC_PROFILE:-fast}" = stock ]; then COSMIC_FEX_CPU=cortex-a78; else COSMIC_FEX_CPU=apple-a13; fi
if [ "${COSMIC_LTO:-0}" = 1 ]; then COSMIC_FEX_LTO=ON; else COSMIC_FEX_LTO=OFF; fi
R="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
B="$R/FEX/build-ios"
cmake -S "$R/FEX" -B "$B" -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=arm64 -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_DISABLE_FIND_PACKAGE_fmt=ON -DCMAKE_DISABLE_FIND_PACKAGE_range-v3=ON \
    -DCMAKE_DISABLE_FIND_PACKAGE_unordered_dense=ON \
    -DBUILD_TESTING=OFF -DBUILD_THUNKS=OFF -DBUILD_FEXCONFIG=OFF -DBUILD_FEX_LINUX_TESTS=OFF \
    -DENABLE_FEX_ALLOCATOR=OFF -DENABLE_ASSERTIONS=OFF -DENABLE_CLANG_THUNKS=ON -DENABLE_CCACHE=ON \
    -DTUNE_CPU="$COSMIC_FEX_CPU" -DENABLE_LTO="$COSMIC_FEX_LTO"
cmake --build "$B" --target FEXCore FEXCore_Base JemallocLibs fmt cephes_128bit softfloat_3e xxhash
ls "$B/FEXCore/Source/"*.a
