<!--
SPDX-FileCopyrightText: 2026 Openchip and Software Technologies, S.L.
SPDX-License-Identifier: Apache-2.0
-->

# IME SDK

OpenChip's cross toolchain, sysroot, debugger and emulator for **RISC-V
IME** development:

| Path in `sdk/` | Contents |
| --- | --- |
| `bin/riscv64-openchip-linux-gnu-*` | gcc, g++, binutils, gdb |
| `riscv64-openchip-linux-gnu/sysroot/` | glibc sysroot of the target |
| `bin/qemu-riscv64` | user-mode emulator for riscv64 Linux programs |
| `bin/qemu-system-riscv64`, `bin/qemu-system-riscv32` | system emulators |
| `share/sdk/env.sh` | shell setup |
| `share/sdk/toolchain-riscv64-openchip-linux-gnu.cmake` | CMake toolchain file |
| `share/sdk/MANIFEST` | versions and commits of every component |
| `share/sdk/Dockerfile`, `share/sdk/sdk.def` | container recipes |
| `share/licenses/` | licences of every component |
| `host/` | private CPython and glib, used by gdb and QEMU |

## Requirements

An x86_64 Linux system with glibc 2.28 or later, for example RHEL, Alma or
Rocky 8 and later, Debian 10 and later, or Ubuntu 20.04 and later. The SDK
needs no other system library and no root access. musl-based systems such
as Alpine are not supported.

## Install

Extract anywhere. Every path inside the SDK is relative, so the directory
can be moved, mounted read-only, or bind-mounted at another path:

```sh
sha256sum -c SHA256SUMS
tar -xJf riscv-ime-sdk-<version>-x86_64-linux.tar.xz -C /opt   # creates /opt/sdk
. /opt/sdk/share/sdk/env.sh
riscv64-openchip-linux-gnu-gcc --version
```

`env.sh` works when sourced from bash or zsh. From another shell, set
`SDK_ROOT=/opt/sdk` before sourcing it. It sets:

| Variable | Value |
| --- | --- |
| `SDK_ROOT` | the SDK directory |
| `SDK_SYSROOT`, `RISCV_SYSROOT` | `$SDK_ROOT/riscv64-openchip-linux-gnu/sysroot` |
| `QEMU_LD_PREFIX` | the sysroot, so `qemu-riscv64` finds the target's libraries |
| `QEMU_CPU` | `max,x-zvvm=true,vlen=2048`, the CPU model with IME, unless already set |
| `PATH` | `$SDK_ROOT/bin` prepended |

## Compile and run

```sh
riscv64-openchip-linux-gnu-gcc -O2 -o hello hello.c
qemu-riscv64 -L "$SDK_SYSROOT" -cpu max,x-zvvm=true,vlen=2048 ./hello
```

Pass the emulator explicitly, as above. The SDK does not register QEMU
with `binfmt_misc`, so `./hello` alone does not run a riscv64 program;
containers and Apptainer cannot register it without privileges. After
sourcing `env.sh`, `QEMU_LD_PREFIX` and `QEMU_CPU` make `-L` and `-cpu`
optional. A program linked with `-static` needs no `-L`.

System emulation, for example a bare-metal program on the `virt` machine:

```sh
qemu-system-riscv64 -M virt -nographic -bios none -kernel program.elf
```

## CMake

```sh
cmake -DCMAKE_TOOLCHAIN_FILE=/opt/sdk/share/sdk/toolchain-riscv64-openchip-linux-gnu.cmake \
      -S . -B build
cmake --build build
ctest --test-dir build
```

The toolchain file sets `CMAKE_SYSROOT` and the compilers. It also sets
`CMAKE_CROSSCOMPILING_EMULATOR` to
`qemu-riscv64 -L <sysroot> -cpu ${SDK_QEMU_CPU}`, so `try_run` and `ctest`
run target programs under QEMU. `SDK_QEMU_CPU` defaults to the IME CPU
model; set it with `-DSDK_QEMU_CPU=...`.

## Debugging

```sh
qemu-riscv64 -L "$SDK_SYSROOT" -g 1234 ./hello &
riscv64-openchip-linux-gnu-gdb -ex 'target remote :1234' ./hello
```

gdb has Python scripting, with its own Python 3.14 in `host/`. The
standard library is complete except for modules that need an external
library: `ssl`, `sqlite3`, `lzma`, `bz2`, `readline`, `curses` and
`tkinter`.

## Containers

The SDK ships two container recipes, `share/sdk/Dockerfile` and
`share/sdk/sdk.def`. You build the image yourself; no image is published.
Copy the recipe next to the tarball:

```sh
docker build --build-arg SDK_TARBALL=riscv-ime-sdk-<version>-x86_64-linux.tar.xz \
    -t riscv-ime-sdk:<version> .

apptainer build --fakeroot --build-arg SDK_TARBALL=riscv-ime-sdk-<version>-x86_64-linux.tar.xz \
    riscv-ime-sdk-<version>.sif sdk.def
```

Both start from `ubuntu:24.04`. You may change the base image to any
distribution with glibc 2.28 or later. Both install the SDK at `/opt/sdk`,
set the variables of `env.sh`, and link the paths of the earlier SDK
images, `/opt/openchip/toolchain` and `/opt/openchip/qemu`, to `/opt/sdk`.

An Apptainer image can also be converted from a Docker image built
locally:

```sh
apptainer build riscv-ime-sdk.sif docker-daemon://riscv-ime-sdk:<version>
```

Without building any image, bind-mount the extracted SDK into a container:

```sh
docker run --rm -v /opt/sdk:/opt/sdk:ro -v "$PWD:/work" -w /work ubuntu:24.04 \
    /opt/sdk/bin/riscv64-openchip-linux-gnu-gcc -o hello hello.c
apptainer exec --bind /opt/sdk:/opt/sdk:ro docker://ubuntu:24.04 \
    /opt/sdk/bin/riscv64-openchip-linux-gnu-gcc -o hello hello.c
```

## Known issues

**Dynamically linked C++ programs do not start under `qemu-riscv64` by
default.** The GCC runtime libraries (`libstdc++.so.6`, `libgcc_s.so.1`,
`libatomic`, `libgomp` and the sanitizer runtimes) are installed in
`<sysroot>/lib`. The riscv64 lp64d dynamic loader searches only
`/lib64/lp64d` and `/usr/lib64/lp64d`, where glibc is installed. The
earlier SDK images have the same layout. Until the toolchain is fixed, add
the library directory in the guest:

```sh
qemu-riscv64 -L "$SDK_SYSROOT" -E LD_LIBRARY_PATH=/lib ./hello_cpp
```

The CMake toolchain file already passes `-E LD_LIBRARY_PATH=/lib`.
Programs linked with `-static` or `-static-libstdc++ -static-libgcc` are
not affected. On target hardware, install these libraries into a
directory the loader searches.

## Changes from the SDK container images

- Install path: `/opt/sdk` instead of `/opt/openchip/toolchain` and
  `/opt/openchip/qemu`. The container recipes add symlinks for the old
  paths.
- The SDK runs on glibc 2.28 and later. The earlier images needed
  glibc 2.43.
- gdb uses its own Python 3.14 instead of the system's `libpython3.14`.
  Some standard library modules are missing; see [Debugging](#debugging).
- The CMake toolchain file is
  `share/sdk/toolchain-riscv64-openchip-linux-gnu.cmake`.

## Licensing

The SDK contains GCC, binutils and gdb (GPL-3.0-or-later; the GCC runtime
libraries carry the GCC Runtime Library Exception), glibc
(LGPL-2.1-or-later), QEMU (GPL-2.0, parts under other licences), glib
(LGPL-2.1-or-later), CPython (PSF License), and the libraries listed in
`share/sdk/MANIFEST`. Their licence texts are in `share/licenses/`.

The source of every component is in
`riscv-ime-sdk-<version>-source.tar.xz`, published with this tarball. It
includes the build recipe used to produce the SDK.
