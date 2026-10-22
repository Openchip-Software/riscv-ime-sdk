#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Openchip and Software Technologies, S.L.
# SPDX-License-Identifier: Apache-2.0
#
# install-packages.sh — the host packages of the SDK builder, on AlmaLinux 8.
# Run as root by build/builder/Dockerfile and build/builder/builder.def.
#
# Only build tools are installed. No -devel package of a library that ends
# up linked into an SDK executable may be installed here: crosstool-NG and
# scripts/build-sdk.sh build those libraries from pinned sources, and a
# system copy found first by a configure script would make the SDK depend on
# that library on the consumer's machine. ncurses-devel is the exception,
# because crosstool-NG's own configure requires it. build-crosstool-ng.sh
# removes it again once crosstool-NG is built.

set -euo pipefail

dnf -y install dnf-plugins-core
# texinfo, help2man and ninja-build are in PowerTools on EL8.
dnf config-manager --set-enabled powertools

# gcc-toolset-14 is the host compiler: the EL8 system gcc 8.5 is older than
# what gdb 16 (C++17) and QEMU 10 expect. libstdc++-static provides the
# libstdc++.a that -static-libstdc++ needs with gcc-toolset.
# python3.12 runs QEMU's configure and meson (Python >= 3.9) and glib's
# meson build; QEMU's configure creates a venv, which needs pip. It is a
# build tool only; gdb embeds the CPython that build-sdk.sh builds.
dnf -y install \
    gcc-toolset-14-gcc gcc-toolset-14-gcc-c++ gcc-toolset-14-binutils \
    libstdc++-static \
    make autoconf automake libtool bison flex gawk texinfo help2man \
    patch diffutils git curl wget rsync unzip xz bzip2 gzip tar cpio \
    file which findutils perl python3.12 python3.12-pip ninja-build pkgconf-pkg-config \
    ncurses-devel

dnf clean all
rm -rf /var/cache/dnf
