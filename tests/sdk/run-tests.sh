#!/bin/sh
# SPDX-FileCopyrightText: 2026 Openchip and Software Technologies, S.L.
# SPDX-License-Identifier: Apache-2.0
#
# run-tests.sh — functional tests of an extracted SDK. scripts/verify-sdk.sh
# runs it on the build host and inside each base image of the portability
# matrix. POSIX sh, because a base image may have no bash.
#
#   run-tests.sh <sdk dir> [<tools dir>]
#
# <tools dir> holds a portable cmake/ and ninja; without it the CMake test
# is skipped. The SDK may be read-only. Prints "ALL TESTS PASSED" last.

set -eu

SDK=$1
TOOLS=${2:-}
T=$(cd "$(dirname "$0")" && pwd)
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
X=riscv64-openchip-linux-gnu
SYSROOT=$SDK/$X/sysroot
CPU=max,x-zvvm=true,vlen=2048

step() { printf '== %s\n' "$*"; }
# expect <text> <command...>: run the command, print its output, and fail
# unless one line of it is exactly <text>.
expect() {
    want=$1
    shift
    out=$("$@" 2>&1) || { printf '%s\n' "$out"; echo "FAILED: exit status of $*"; exit 1; }
    printf '%s\n' "$out"
    printf '%s\n' "$out" | grep -qx "$want" || { echo "FAILED: no line '$want' from $*"; exit 1; }
}

step "the SDK runs from $SDK, without env.sh"
"$SDK/bin/$X-gcc" --version | head -n 1
"$SDK/bin/$X-gcc" -print-sysroot

step "env.sh, sourced by sh with SDK_ROOT set"
SDK_ROOT=$SDK
. "$SDK/share/sdk/env.sh"
[ "$SDK_SYSROOT" = "$SYSROOT" ] || { echo "FAILED: SDK_SYSROOT=$SDK_SYSROOT"; exit 1; }
command -v "$X-gcc"
command -v qemu-riscv64

step "C: compile, link, run under qemu-riscv64 -L <sysroot>"
"$X-gcc" -O2 -Wall -o "$W/hello_c" "$T/hello.c"
expect "hello from C" qemu-riscv64 -L "$SYSROOT" "$W/hello_c"

# The GCC runtime libraries (libstdc++, libgcc_s, libatomic, ...) are in
# <sysroot>/lib, but the riscv64 lp64d dynamic loader searches only
# /lib64/lp64d and /usr/lib64/lp64d. A dynamically linked C++ program
# therefore needs LD_LIBRARY_PATH=/lib in the guest; see "Known issues" in
# build/release/README.md.
step "C++: compile, link, run with -E LD_LIBRARY_PATH=/lib"
"$X-g++" -O2 -Wall -o "$W/hello_cpp" "$T/hello.cpp"
expect "hello from C++" qemu-riscv64 -L "$SYSROOT" -E LD_LIBRARY_PATH=/lib "$W/hello_cpp"

step "static C"
"$X-gcc" -O2 -static -o "$W/hello_static" "$T/hello.c"
expect "hello from C" qemu-riscv64 "$W/hello_static"

step "QEMU_LD_PREFIX and QEMU_CPU from env.sh, no -L"
expect "hello from C" qemu-riscv64 "$W/hello_c"

step "IME CPU model: -cpu $CPU"
expect "hello from C" qemu-riscv64 -cpu "$CPU" -L "$SYSROOT" "$W/hello_c"

step "LTO with the linker plugin: slim objects, gcc-ar archive"
"$X-gcc" -O2 -flto -c -o "$W/lto_a.o" "$T/lto_a.c"
"$X-gcc" -O2 -flto -c -o "$W/lto_b.o" "$T/lto_b.c"
if "$X-readelf" -S "$W/lto_b.o" | grep -q '\.text.*PROGBITS.*AX'; then
    # A slim LTO object has an empty .text section; check that it is empty.
    size=$("$X-size" -A "$W/lto_b.o" | awk '$1 == ".text" { print $2 }')
    [ "${size:-0}" = 0 ] || { echo "FAILED: lto_b.o has $size bytes of .text, not a slim LTO object"; exit 1; }
fi
"$X-gcc-ar" rcs "$W/liblto.a" "$W/lto_b.o"
"$X-gcc-nm" "$W/liblto.a" | grep -q 'T lto_square' \
    || { echo "FAILED: gcc-nm cannot read the LTO symbol table"; exit 1; }
"$X-gcc" -O2 -flto -o "$W/lto" "$W/lto_a.o" -L"$W" -llto
expect "lto 49" qemu-riscv64 -L "$SYSROOT" "$W/lto"

step "gdb with Python"
"$X-gdb" --version | head -n 1
expect "python ok" "$X-gdb" -nx -batch -ex 'python import sys, os, json; print("python ok")'
"$X-gdb" -nx -batch -ex "file $W/hello_c" -ex 'info line main'

step "qemu-system-riscv64 and qemu-system-riscv32, bare metal on virt"
"$X-gcc" -march=rv64gc -mabi=lp64d -nostdlib -static -Wl,-Ttext=0x80000000 \
    -o "$W/bm64" "$T/baremetal.S"
"$X-gcc" -march=rv32imac -mabi=ilp32 -nostdlib -static -Wl,-Ttext=0x80000000 \
    -o "$W/bm32" "$T/baremetal.S"
to=
command -v timeout >/dev/null && to="timeout 60"
expect "baremetal ok" $to qemu-system-riscv64 -M virt -m 128M -display none -serial stdio \
    -monitor none -bios none -kernel "$W/bm64"
expect "baremetal ok" $to qemu-system-riscv32 -M virt -m 128M -display none -serial stdio \
    -monitor none -bios none -kernel "$W/bm32"

if [ -n "$TOOLS" ]; then
    step "CMake with share/sdk/toolchain-$X.cmake, ctest under qemu-riscv64"
    "$TOOLS/cmake/bin/cmake" -G Ninja -DCMAKE_MAKE_PROGRAM="$TOOLS/ninja" \
        -DCMAKE_TOOLCHAIN_FILE="$SDK/share/sdk/toolchain-$X.cmake" \
        -S "$T/cmake" -B "$W/cmake"
    "$TOOLS/cmake/bin/cmake" --build "$W/cmake"
    "$TOOLS/cmake/bin/ctest" --test-dir "$W/cmake" --output-on-failure
else
    step "CMake: skipped, no tools directory"
fi

echo "ALL TESTS PASSED"
