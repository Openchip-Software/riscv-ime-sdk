#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Openchip and Software Technologies, S.L.
# SPDX-License-Identifier: Apache-2.0
#
# build-crosstool-ng.sh — build the pinned crosstool-NG into /opt/crosstool-ng.
# Run as root by build/builder/Dockerfile and build/builder/builder.def,
# after install-packages.sh.
#
#   build-crosstool-ng.sh <repo> <commit>
#
# The source tree is kept as /opt/crosstool-ng/src/crosstool-ng-<commit>.tar.xz,
# because scripts/package-sdk.sh puts it into the SDK source tarball.

set -euo pipefail

repo="${1:?usage: build-crosstool-ng.sh <repo> <commit>}"
commit="${2:?usage: build-crosstool-ng.sh <repo> <commit>}"

src=/tmp/crosstool-ng
git init -q "$src"
git -C "$src" fetch -q --depth 1 "$repo" "$commit"
git -C "$src" -c advice.detachedHead=false checkout -q FETCH_HEAD

install -d /opt/crosstool-ng/src
git -C "$src" archive --format=tar --prefix="crosstool-ng-${commit}/" HEAD \
    | xz -T0 > "/opt/crosstool-ng/src/crosstool-ng-${commit}.tar.xz"

# git-version-gen reads .tarball-version when `git describe` finds no tag in
# the shallow clone. It must start with a digit.
cd "$src"
rm -rf .git
printf '0+openchip.%.12s\n' "$commit" > .tarball-version
./bootstrap
./configure --prefix=/opt/crosstool-ng
make -j"$(nproc)"
make install
cd /
rm -rf "$src"

# crosstool-NG's configure needs the curses headers; building the SDK must
# not see them. Otherwise gdb links the system libncursesw.so and libtinfo.so
# instead of the static ncurses that crosstool-NG builds as a companion
# library. `ct-ng defconfig` and `ct-ng build` only use kconfig's `conf`,
# which does not need curses.
dnf -y remove ncurses-devel
dnf clean all
