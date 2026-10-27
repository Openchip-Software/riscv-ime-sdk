<!--
SPDX-FileCopyrightText: 2026 Openchip and Software Technologies, S.L.
SPDX-License-Identifier: Apache-2.0
-->

# IME SDK

This is Openchip's cross toolchain, sysroot and emulator for **RISC-V IME**
development. It ships as an OCI image, the **SDK image**, and as an
**Apptainer image** (`.sif`) converted from it.

`<version>` below is the SDK version, a date in the form `YYYY.MM.DD`.
Each release is tagged `openchip-v<version>`.

## Use it

```sh
# SDK image: a release by its version, or the newest release
docker pull ghcr.io/openchip-software/riscv-ime-sdk:openchip-v<version>
docker pull ghcr.io/openchip-software/riscv-ime-sdk:latest

# Apptainer image, converted from the SDK image
apptainer pull riscv-ime-sdk-openchip-v<version>.sif \
    docker://ghcr.io/openchip-software/riscv-ime-sdk:openchip-v<version>
apptainer exec riscv-ime-sdk-openchip-v<version>.sif riscv64-openchip-linux-gnu-gcc --version

# Image archive: the SDK image as a file, for a machine without registry access
docker save ghcr.io/openchip-software/riscv-ime-sdk:openchip-v<version> \
    | xz -T0 > riscv-ime-sdk-openchip-v<version>.tar.xz
docker load -i riscv-ime-sdk-openchip-v<version>.tar.xz
```

The SDK image provides:

| Path | Contents |
| --- | --- |
| `/opt/openchip/toolchain` | gcc, binutils, gdb, glibc sysroot — `riscv64-openchip-linux-gnu-*` |
| `/opt/openchip/qemu` | `qemu-riscv64`, `qemu-system-riscv64`, `qemu-system-riscv32` |

Both directories are on `PATH`. `QEMU_LD_PREFIX` points at the sysroot,
so `qemu-riscv64 ./prog` runs a dynamically linked program without `-L`.
`QEMU_CPU` sets the default CPU model to `max,x-zvvm=true,vlen=2048`.

CI publishes the SDK image. A release tag publishes it under the same
tag and moves `:latest` to it. See [DEVELOPERS.md](DEVELOPERS.md#ci).

## Build it

`make` builds the SDK image, the Apptainer image and the image archive
from source, at the component commits pinned in `sdk.lock.yaml`.

### Requirements

- Docker with BuildKit and the `buildx` plugin. Check with
  `docker buildx version`.
- Apptainer 1.3 or later. It reads the SDK image from the local Docker
  daemon, so the user running `make` needs access to Docker.
- [mikefarah/yq](https://github.com/mikefarah/yq) v4. Ubuntu's apt `yq`
  package is a different tool and does not work here; install yq from its
  [releases](https://github.com/mikefarah/yq/releases).
- `make`, `git` and `xz`.
- About 20 GB of free disk space for Docker: about 16 GB of build cache
  and 1.7 GB for the SDK image. The Apptainer image and the image archive
  take about 0.7 GB more in the repo.
- Network access to GitHub and Docker Hub. The component repos are
  public, so no credentials are needed.

Tested on x86-64 Linux. With an empty build cache, `make` took about one
hour on a 12-core machine with 16 GB of RAM, almost all of it for the
toolchain. Later builds reuse the build cache and take a few minutes.

### Build

```sh
git clone https://github.com/Openchip-Software/riscv-ime-sdk.git
cd riscv-ime-sdk
make
```

`make` produces:

| Output | Name | Where |
| --- | --- | --- |
| SDK image | `ghcr.io/openchip-software/riscv-ime-sdk:openchip-v<version>` | local Docker daemon |
| Apptainer image | `riscv-ime-sdk-openchip-v<version>.sif` | repo root |
| Image archive | `riscv-ime-sdk-openchip-v<version>.tar.xz` | repo root |

`<version>` is `sdk_version` in `sdk.lock.yaml`. The SDK image gets the
same tag as the published release of that version, and replaces a pulled
copy of it in the local Docker daemon. To use another tag, set `IMAGE`:

```sh
make IMAGE=riscv-ime-sdk:local
```

### Check the build

Compile a program with the toolchain and run it on QEMU:

```sh
printf '#include <stdio.h>\nint main(void) { puts("hello"); }\n' > hello.c
apptainer exec riscv-ime-sdk-openchip-v<version>.sif \
    sh -c 'riscv64-openchip-linux-gnu-gcc hello.c -o hello && qemu-riscv64 ./hello'
```

It prints `hello`. To check the SDK image directly:

```sh
docker run --rm ghcr.io/openchip-software/riscv-ime-sdk:openchip-v<version> \
    riscv64-openchip-linux-gnu-gcc --version
```

### Make targets

| Target | Does |
| --- | --- |
| `make` | build the SDK image, the Apptainer image and the image archive |
| `make sdk` | build the SDK image only |
| `make toolchain`, `make qemu` | build one component image only |
| `make print` | print the resolved build definition |
| `make clean` | delete the Apptainer images, the image archives and the SDK image |

`make clean` keeps the build cache, which holds most of the disk space.
The build cache is shared with every other Docker build on the machine.
`docker buildx prune` deletes all of it, and the next `make` then
rebuilds everything from source.

To build other component commits than the pinned ones, see
[Changing a component](DEVELOPERS.md#changing-a-component).

## Components

| Repo | Role |
| --- | --- |
| [`riscv-ime-crosstool-NG`](https://github.com/Openchip-Software/riscv-ime-crosstool-NG) | crosstool-NG + OpenChip patches |
| [`riscv-ime-gcc`](https://github.com/Openchip-Software/riscv-ime-gcc) | GCC + IME support — cross-built inside ct-ng |
| [`riscv-ime-binutils`](https://github.com/Openchip-Software/riscv-ime-binutils) | binutils/gdb + IME support — cross-built inside ct-ng |
| [`riscv-ime-qemu`](https://github.com/Openchip-Software/riscv-ime-qemu) | QEMU + IME model |

To change the SDK itself, pin other component commits or make a release,
see [DEVELOPERS.md](DEVELOPERS.md).
