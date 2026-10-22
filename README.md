<!--
SPDX-FileCopyrightText: 2026 Openchip and Software Technologies, S.L.
SPDX-License-Identifier: Apache-2.0
-->

# IME SDK

Cross toolchain, glibc sysroot and QEMU for RISC-V IME development.

Two ways to get it:

- [Container image](#quick-start), built locally from the published components.
- [Relocatable tarball](#sdk-tarball) for x86_64 Linux.

## Quick start

Requires Docker 23 or later (BuildKit).

```sh
V=openchip-v<YYYY.MM.DD>          # a release tag, or: V=latest
# for V=latest, use #main:build/sdk as the build context
docker build -t riscv-ime-sdk:$V \
    --build-context toolchain=docker-image://ghcr.io/openchip-software/riscv-ime-sdk-toolchain:$V \
    --build-context qemu=docker-image://ghcr.io/openchip-software/riscv-ime-sdk-qemu:$V \
    "https://github.com/Openchip-Software/riscv-ime-sdk.git#$V:build/sdk"
docker run --rm -it riscv-ime-sdk:$V riscv64-openchip-linux-gnu-gcc --version
```

Release tags are listed under
[Tags](https://github.com/Openchip-Software/riscv-ime-sdk/tags).

## Contents

- `riscv64-openchip-linux-gnu-*`: gcc, binutils, gdb, glibc sysroot
- `qemu-riscv64`, `qemu-system-riscv64`, `qemu-system-riscv32`

Environment: both tool directories are on `PATH`, and `RISCV_SYSROOT`,
`QEMU_LD_PREFIX` and `QEMU_CPU=max,x-zvvm=true,vlen=2048` are set.

## Compile and run

```sh
# TODO: set the IME -march string
riscv64-openchip-linux-gnu-gcc -O2 -march=<TODO> -o hello hello.c
qemu-riscv64 ./hello
```

## Apptainer and offline use

`V` is the tag used in [Quick start](#quick-start).

```sh
# Apptainer image, converted from the SDK image in the Docker daemon
apptainer build riscv-ime-sdk-$V.sif docker-daemon://riscv-ime-sdk:$V

# Image file, for a machine without registry access
docker save riscv-ime-sdk:$V | xz -T0 > riscv-ime-sdk-$V.tar.xz
docker load -i riscv-ime-sdk-$V.tar.xz
```

## SDK tarball

Relocatable tarball for x86_64 Linux with glibc 2.28 or later. Download
it from the artifacts of the `release` workflow run for a release tag.

```sh
sha256sum -c SHA256SUMS
tar -xJf riscv-ime-sdk-<version>-x86_64-linux.tar.xz -C /opt   # creates /opt/sdk
. /opt/sdk/share/sdk/env.sh
```

Full usage: see `sdk/share/doc/sdk/README.md` inside the tarball
([source](build/release/README.md)). To run the tarball in a container,
use the recipes in [`release/`](release/), also shipped in the tarball.

## Source repositories

| Repo | Role |
| --- | --- |
| [`riscv-ime-crosstool-NG`](https://github.com/Openchip-Software/riscv-ime-crosstool-NG) | crosstool-NG + OpenChip patches |
| [`riscv-ime-gcc`](https://github.com/Openchip-Software/riscv-ime-gcc) | GCC + IME support |
| [`riscv-ime-binutils`](https://github.com/Openchip-Software/riscv-ime-binutils) | binutils/gdb + IME support |
| [`riscv-ime-qemu`](https://github.com/Openchip-Software/riscv-ime-qemu) | QEMU + IME model |

Building from source and contributing: see [DEVELOPERS.md](DEVELOPERS.md).
