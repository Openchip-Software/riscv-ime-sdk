# syntax=docker/dockerfile:1
# SPDX-FileCopyrightText: 2026 Openchip and Software Technologies, S.L.
# SPDX-License-Identifier: Apache-2.0
#
# QEMU with the IME model, installed into /opt/openchip/qemu.
#
# Every input of this image lives in this directory, and nothing outside it
# is read. CI tags the image with the git tree hash of build/qemu, so any
# change here produces a new tag and a rebuild, and no other change does.
# pins.hcl is generated from sdk.lock.yaml by `make lock`.
#
# To force a rebuild with unchanged inputs, bump this number: 2

ARG BASE_IMAGE

FROM ${BASE_IMAGE} AS build

ENV LC_ALL=C
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

RUN apt-get update \
    && apt-get install -y ca-certificates \
                    build-essential git python3 python3-venv bison flex \
                    ninja-build meson pkg-config libglib2.0-dev libpixman-1-dev \
    && rm -rf /var/lib/apt/lists/*

ARG QEMU_REPO
ARG QEMU_COMMIT

# BuildKit fetches the public repo itself, with no credentials.
# Keep .git: the previous build ran from a git clone, and QEMU's scripts
# take different paths when .git is absent. The meson subprojects that
# configure downloads are pinned by commit in subprojects/*.wrap.
ADD --keep-git-dir=true ${QEMU_REPO}#${QEMU_COMMIT} /src/qemu

WORKDIR /src/qemu/build
RUN ../configure \
        --target-list=riscv64-linux-user,riscv64-softmmu,riscv32-softmmu \
        --enable-plugins \
        --disable-docs \
        --prefix=/opt/openchip/qemu \
    && ninja \
    && ninja install

# The published image: the installed QEMU and nothing else.
FROM scratch AS qemu
COPY --link --from=build /opt/openchip/qemu /opt/openchip/qemu
