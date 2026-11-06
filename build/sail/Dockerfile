# syntax=docker/dockerfile:1
# SPDX-FileCopyrightText: 2026 Openchip and Software Technologies, S.L.
# SPDX-License-Identifier: Apache-2.0
#
# Sail RISC-V model with the IME extension: the sail_riscv_sim emulator,
# its configuration schema and sample configurations, installed into
# /opt/openchip/sail.
#
# Every input of this image lives in this directory, and nothing outside it
# is read. CI tags the image with the git tree hash of build/sail, so any
# change here produces a new tag and a rebuild, and no other change does.
# pins.hcl is generated from sdk.lock.yaml by `make lock`.
#
# To force a rebuild with unchanged inputs, bump this number: 1

ARG BASE_IMAGE

FROM ${BASE_IMAGE} AS build

ENV LC_ALL=C
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

RUN apt-get update \
    && apt-get install -y ca-certificates curl \
                    build-essential cmake ninja-build git pkg-config libgmp-dev \
    && rm -rf /var/lib/apt/lists/*

# The Sail compiler translates the model into C++. It is written in OCaml,
# so it is installed from the upstream binary release instead of being
# built. The sail-riscv build passes --require-version with the version in
# cmake/sail_required_version.txt, and fails if this version is older.
# The checksum is the digest GitHub lists for the release asset.
ARG SAIL_VERSION=0.20.3
ARG SAIL_SHA256=8d7cd75624ece407d7001ad32905a13ae111d5cc1a055404f21510e113207e3f
RUN curl -fsSL -o /tmp/sail.tar.gz \
        "https://github.com/rems-project/sail/releases/download/${SAIL_VERSION}-binary/sail-Linux-x86_64.tar.gz" \
    && echo "${SAIL_SHA256}  /tmp/sail.tar.gz" | sha256sum -c - \
    && mkdir /opt/sail \
    && tar -xzf /tmp/sail.tar.gz -C /opt/sail --strip-components=1 \
    && rm /tmp/sail.tar.gz
ENV PATH=/opt/sail/bin:$PATH

ARG SAIL_RISCV_REPO
ARG SAIL_RISCV_COMMIT

# BuildKit fetches the public repo itself, with no credentials.
# Keep .git: the build runs `git describe` for the version string that
# `sail_riscv_sim --version` prints.
ADD --keep-git-dir=true ${SAIL_RISCV_REPO}#${SAIL_RISCV_COMMIT} /src/sail-riscv

# Build only the sail_riscv_sim target. The tests, the documentation and
# the SMT, Lean and Rocq outputs of the model are not built. The test
# suites are off by default in the sail-riscv CMake build.
WORKDIR /src/sail-riscv
RUN cmake -S . -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/opt/openchip/sail \
    && cmake --build build --target sail_riscv_sim \
    && cmake --install build \
    && /opt/openchip/sail/bin/sail_riscv_sim --version

# The published image: the installed model and nothing else.
FROM scratch AS sail
COPY --link --from=build /opt/openchip/sail /opt/openchip/sail
