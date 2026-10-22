# SPDX-FileCopyrightText: 2026 Openchip and Software Technologies, S.L.
# SPDX-License-Identifier: Apache-2.0
#
# CMake toolchain file of the IME SDK, installed as
# <sdk>/share/sdk/toolchain-riscv64-openchip-linux-gnu.cmake:
#
#   cmake -DCMAKE_TOOLCHAIN_FILE=<sdk>/share/sdk/toolchain-riscv64-openchip-linux-gnu.cmake ...
#
# Every path is relative to this file, so the SDK works from wherever it
# was extracted. Test programs (try_run, ctest, add_test) run under
# qemu-riscv64 with the target sysroot. binfmt_misc is not needed.

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR riscv64)

get_filename_component(SDK_ROOT "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
set(SDK_TUPLE riscv64-openchip-linux-gnu)

set(CMAKE_SYSROOT "${SDK_ROOT}/${SDK_TUPLE}/sysroot")
set(CMAKE_C_COMPILER   "${SDK_ROOT}/bin/${SDK_TUPLE}-gcc")
set(CMAKE_CXX_COMPILER "${SDK_ROOT}/bin/${SDK_TUPLE}-g++")
set(CMAKE_ASM_COMPILER "${SDK_ROOT}/bin/${SDK_TUPLE}-gcc")

# The CPU model QEMU emulates. The default enables the IME extension, as
# QEMU_CPU did in the SDK container images.
set(SDK_QEMU_CPU "max,x-zvvm=true,vlen=2048" CACHE STRING
    "QEMU -cpu option for running target programs")
# LD_LIBRARY_PATH=/lib: the GCC runtime libraries (libstdc++, libgcc_s,
# libatomic, ...) are in <sysroot>/lib, which the riscv64 lp64d dynamic
# loader does not search. See "Known issues" in share/doc/sdk/README.md.
set(CMAKE_CROSSCOMPILING_EMULATOR
    "${SDK_ROOT}/bin/qemu-riscv64;-L;${CMAKE_SYSROOT};-cpu;${SDK_QEMU_CPU};-E;LD_LIBRARY_PATH=/lib")

set(CMAKE_FIND_ROOT_PATH "${CMAKE_SYSROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
