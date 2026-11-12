<!--
SPDX-FileCopyrightText: 2026 Openchip and Software Technologies, S.L.
SPDX-License-Identifier: Apache-2.0
-->

# IME SDK

This is Openchip's cross toolchain, sysroot and emulators for **RISC-V IME**
development. It builds to an OCI image, the **SDK image**, and as an
**Apptainer image** (`.sif`) converted from it.

`<version>` below is the SDK version, a date in the form `YYYY.MM.DD`.
Each release is tagged `openchip-v<version>`.

The SDK image provides:

| Path | Contents |
| --- | --- |
| `/opt/openchip/toolchain` | gcc, binutils, gdb, glibc sysroot — `riscv64-openchip-linux-gnu-*` |
| `/opt/openchip/qemu` | `qemu-riscv64`, `qemu-system-riscv64`, `qemu-system-riscv32` |
| `/opt/openchip/sail` | `sail_riscv_sim`, the Sail RISC-V model; sample configurations in `share/sail-riscv/config` |

The `bin` directories of all three are on `PATH`. `QEMU_LD_PREFIX` points at the sysroot,
so `qemu-riscv64 ./prog` runs a dynamically linked program without `-L`.
`QEMU_CPU` sets the default CPU model to `max,x-zvvm=true,vlen=2048`.


## Build it

`make` builds the SDK image, the Apptainer image and the image archive
from source, at the component commits pinned in `sdk.lock.yaml`.

### Requirements

- Docker with BuildKit and the `buildx` plugin. Check with
  `docker buildx version`.
- Apptainer. It reads the SDK image from the local Docker
  daemon, so the user running `make` needs access to Docker.
- [mikefarah/yq](https://github.com/mikefarah/yq) v4. Ubuntu's apt `yq`
  package is a different tool and does not work here; install yq from its
  [releases](https://github.com/mikefarah/yq/releases).
- `make`, `git` and `xz`.
- About 21 GB of free disk space.
- Network access.

Tested on x86-64 Linux. With an empty build cache, `make` between 1 to 2 hours. Later builds reuse the build cache and take a few minutes.

### Build

```sh
git clone https://github.com/Openchip-Software/riscv-ime-sdk.git
cd riscv-ime-sdk
make
```

`make` produces:

| Output | Name | Where |
| --- | --- | --- |
| SDK image | `riscv-ime-sdk:openchip-v<version>` | local Docker daemon |
| Apptainer image | `riscv-ime-sdk-openchip-v<version>.sif` | repo root |
| Image archive | `riscv-ime-sdk-openchip-v<version>.tar.xz` | repo root |

`<version>` is `sdk_version` in `sdk.lock.yaml`. `make` replaces any
existing image under that tag in the local Docker daemon. To use another
tag, set `IMAGE`:

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
docker run --rm riscv-ime-sdk:openchip-v<version> \
    riscv64-openchip-linux-gnu-gcc --version
```

Apptainer runs as your user and mounts the current directory and `$HOME`.
Docker does neither, so to work on files in the current directory, mount
it and run as your user:

```sh
docker run --rm -it -u "$(id -u):$(id -g)" -v "$PWD":/work -w /work \
    riscv-ime-sdk:openchip-v<version>
```

### Make targets

| Target | Does |
| --- | --- |
| `make` | build the SDK image, the Apptainer image and the image archive |
| `make sdk` | build the SDK image only |
| `make toolchain`, `make qemu`, `make sail` | build one component image only |
| `make print` | print the resolved build definition |
| `make clean` | delete the Apptainer images, the image archives and the SDK image |

`make clean` keeps the build cache, which holds most of the disk space.
The build cache is shared with every other Docker build on the machine.
`docker buildx prune` deletes all of it, and the next `make` then
rebuilds everything from source.

To build other component commits than the pinned ones, see
[Changing a component](DEVELOPERS.md#changing-a-component).

## SDK Components

| Repo | Role |
| --- | --- |
| [`riscv-ime-crosstool-NG`](https://github.com/Openchip-Software/riscv-ime-crosstool-NG) | crosstool-NG + OpenChip patches |
| [`riscv-ime-gcc`](https://github.com/Openchip-Software/riscv-ime-gcc) | GCC + IME support — cross-built inside ct-ng |
| [`riscv-ime-binutils`](https://github.com/Openchip-Software/riscv-ime-binutils) | binutils/gdb + IME support — cross-built inside ct-ng |
| [`riscv-ime-qemu`](https://github.com/Openchip-Software/riscv-ime-qemu) | QEMU + IME model |
| [`sail-riscv`](https://github.com/Openchip-Software/sail-riscv) | Sail RISC-V model + IME support |

To change the SDK itself, pin other component commits or make a release,
see [DEVELOPERS.md](DEVELOPERS.md).
