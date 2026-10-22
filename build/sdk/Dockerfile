# syntax=docker/dockerfile:1
# SPDX-FileCopyrightText: 2026 Openchip and Software Technologies, S.L.
# SPDX-License-Identifier: Apache-2.0
#
# IME SDK image: assembly only. The SDK image is never published; this is
# the recipe that assembles it from the published component images.
#
# `toolchain` and `qemu` are not stages of this file. They are named build
# contexts: in this repository, docker-bake.hcl supplies either the bake
# targets that build them from source or the component images from GHCR
# (`make sdk`). A user builds the image from the published components with
# plain `docker build` and two --build-context options; see "Use it" in
# README.md.

# pins.hcl sets the digest-pinned base image. The default is for users who
# build without pins.hcl: the components are built on Ubuntu 26.04 and need
# its libraries.
ARG BASE_IMAGE=ubuntu:26.04

FROM ${BASE_IMAGE} AS sdk

ENV LC_ALL=C
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
                    libpython3.14 libglib2.0-0 libpixman-1-0 libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

COPY --link --from=toolchain /opt/openchip/toolchain /opt/openchip/toolchain
COPY --link --from=qemu      /opt/openchip/qemu      /opt/openchip/qemu

ENV RISCV_SYSROOT=/opt/openchip/toolchain/riscv64-openchip-linux-gnu/sysroot
ENV QEMU_LD_PREFIX=/opt/openchip/toolchain/riscv64-openchip-linux-gnu/sysroot
ENV QEMU_CPU=max,x-zvvm=true,vlen=2048
ENV PATH=/opt/openchip/toolchain/bin:/opt/openchip/qemu/bin:$PATH

ARG SDK_VERSION
ARG LOCK_DIGEST

# sha256 of the sdk.lock.yaml this image was built from, which traces the
# image back to an exact set of source commits.
LABEL org.opencontainers.image.version="${SDK_VERSION}"
LABEL eu.openchip.ime.lock-digest="${LOCK_DIGEST}"
