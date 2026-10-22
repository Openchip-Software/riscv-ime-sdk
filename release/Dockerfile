# syntax=docker/dockerfile:1
# SPDX-FileCopyrightText: 2026 Openchip and Software Technologies, S.L.
# SPDX-License-Identifier: Apache-2.0
#
# IME SDK container recipe. We ship this file; you build the image yourself.
# Put it next to the SDK tarball and run:
#
#   docker build --build-arg SDK_TARBALL=riscv-ime-sdk-<version>-x86_64-linux.tar.xz \
#       -t riscv-ime-sdk:<version> .
#
# Any base image with glibc >= 2.28 works: change FROM freely. The SDK
# needs nothing from the base image except glibc. The packages below are
# conveniences for building projects with the SDK.

FROM ubuntu:24.04

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
            make cmake ninja-build ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ADD extracts a local .tar.xz; the tarball's top directory is sdk/.
ARG SDK_TARBALL=riscv-ime-sdk-VERSION-x86_64-linux.tar.xz
ADD ${SDK_TARBALL} /opt/

# The paths of the SDK images published before the SDK tarball existed.
RUN mkdir -p /opt/openchip \
    && ln -s /opt/sdk /opt/openchip/toolchain \
    && ln -s /opt/sdk /opt/openchip/qemu

# What /opt/sdk/share/sdk/env.sh sets.
ENV SDK_ROOT=/opt/sdk
ENV SDK_SYSROOT=/opt/sdk/riscv64-openchip-linux-gnu/sysroot
ENV RISCV_SYSROOT=/opt/sdk/riscv64-openchip-linux-gnu/sysroot
ENV QEMU_LD_PREFIX=/opt/sdk/riscv64-openchip-linux-gnu/sysroot
ENV QEMU_CPU=max,x-zvvm=true,vlen=2048
ENV PATH=/opt/sdk/bin:$PATH
