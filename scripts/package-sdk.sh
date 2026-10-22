#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Openchip and Software Technologies, S.L.
# SPDX-License-Identifier: Apache-2.0
#
# package-sdk.sh — pack a finished SDK prefix into dist/:
#
#   riscv-ime-sdk-<version>-<arch>-linux.tar.xz   the SDK, top directory sdk/
#   riscv-ime-sdk-<version>-source.tar.xz         the corresponding source
#   SHA256SUMS
#
# scripts/build-sdk.sh runs it as its last step, inside the builder, with
# the same environment (SDK_PREFIX, SDK_WORK, SDK_TARBALLS, SDK_DIST).
#
# The source tarball holds every upstream tarball that crosstool-NG and
# build-sdk.sh built from, the crosstool-NG tree, the QEMU tree with its
# meson subprojects, the rendered crosstool-NG configuration, and this
# repository's build recipe. That is the source of everything the SDK
# tarball contains in binary form.
#
# Both tarballs are reproducible where practical: entries sorted by name,
# mtime SOURCE_DATE_EPOCH (default: the commit time of HEAD), owner 0:0.

set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SDK_PREFIX="${SDK_PREFIX:-/opt/sdk}"
SDK_WORK="${SDK_WORK:-$REPO/work}"
SDK_TARBALLS="${SDK_TARBALLS:-$SDK_WORK/tarballs}"
SDK_DIST="${SDK_DIST:-$REPO/dist}"
PINS="$REPO/build/release/pins.hcl"

log() { printf '[package-sdk] %s\n' "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

pin() {
    local v
    v=$(sed -n "s/^ *$1 *= *\"\(.*\)\"\$/\1/p" "$PINS")
    [[ -n "$v" ]] || die "$1 not in $PINS"
    printf '%s\n' "$v"
}

[[ -f "$SDK_PREFIX/share/sdk/MANIFEST" ]] || die "$SDK_PREFIX has no share/sdk/MANIFEST; run build-sdk.sh first"

version=$(pin SDK_VERSION)
name="riscv-ime-sdk-$version"
bin_tar="$name-$(uname -m)-linux.tar.xz"
src_tar="$name-source.tar.xz"

SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$REPO" log -1 --format=%ct 2>/dev/null || date +%s)}"
export SOURCE_DATE_EPOCH

TAR=(tar --sort=name --mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner
     --format=posix --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime)
# A fixed block size makes the multi-threaded output independent of the
# number of threads.
XZ=(xz -6 -T0 --block-size=64MiB)

mkdir -p "$SDK_DIST"
rm -f "$SDK_DIST/$bin_tar" "$SDK_DIST/$src_tar" "$SDK_DIST/SHA256SUMS"

# --- binary tarball --------------------------------------------------------

log "packing $bin_tar"
base=$(basename "$SDK_PREFIX")
transform=()
# Rename the top directory to sdk/. flags=rh: member names and hard link
# targets, not symlink targets, which are relative.
[[ "$base" == sdk ]] || transform=(--transform "flags=rh;s|^$base\(/\|\$\)|sdk\1|")
"${TAR[@]}" "${transform[@]}" -C "$(dirname "$SDK_PREFIX")" -cf - "$base" \
    | "${XZ[@]}" > "$SDK_DIST/$bin_tar.part"
mv "$SDK_DIST/$bin_tar.part" "$SDK_DIST/$bin_tar"

# --- source tarball --------------------------------------------------------

log "packing $src_tar"
stage="$SDK_WORK/source-stage"
top="$stage/$name-source"
rm -rf "$stage"
mkdir -p "$top/upstream" "$top/crosstool-ng" "$top/qemu" "$top/recipe"

# Upstream release tarballs saved by crosstool-NG (CT_SAVE_TARBALLS), the
# gcc and binutils-gdb trees packed by build-sdk.sh, and sources.list.
# Hard links: the files are large and only read.
find "$SDK_TARBALLS" -maxdepth 1 -type f ! -name '*.part' -exec ln {} "$top/upstream/" \; 2>/dev/null \
    || find "$SDK_TARBALLS" -maxdepth 1 -type f ! -name '*.part' -exec cp {} "$top/upstream/" \;

ctng_src=(/opt/crosstool-ng/src/crosstool-ng-*.tar.xz)
[[ -f "${ctng_src[0]}" ]] || die "no crosstool-NG source in /opt/crosstool-ng/src; run inside the builder"
cp "${ctng_src[@]}" "$top/crosstool-ng/"

# The QEMU tree as configured: meson downloaded the pinned subprojects into
# subprojects/. No build directory, no git metadata.
"${TAR[@]}" --exclude-vcs --exclude=./build -C "$SDK_WORK/src/qemu" \
    --transform "s|^\.|qemu-$(pin QEMU_COMMIT)|" -cf - . \
    | "${XZ[@]}" > "$top/qemu/qemu-$(pin QEMU_COMMIT).tar.xz"

# The build recipe: this repository's files as built, and the crosstool-NG
# configuration rendered from build/release/defconfig.in.
(cd "$REPO" && git ls-files -z --cached --others --exclude-standard) \
    | (cd "$REPO" && "${TAR[@]}" --null -T - --transform "s|^|riscv-ime-sdk/|" -cf -) \
    | "${XZ[@]}" > "$top/recipe/riscv-ime-sdk-recipe.tar.xz"
cp "$SDK_WORK/ctng/defconfig" "$top/recipe/crosstool-ng.defconfig"
cp "$SDK_WORK/ctng/.config"   "$top/recipe/crosstool-ng.config"
cp "$SDK_PREFIX/share/sdk/MANIFEST" "$top/MANIFEST"

cat > "$top/README" <<EOF
Corresponding source of riscv-ime-sdk $version.

upstream/       every upstream tarball the SDK was built from. The
                gcc-git-* and binutils-git-* tarballs are the pinned commits
                of the OpenChip gcc and binutils-gdb repositories.
crosstool-ng/   the crosstool-NG tree, including its patches to the
                upstream packages.
qemu/           the OpenChip QEMU tree, with the meson subprojects it
                built with.
recipe/         the riscv-ime-sdk repository at the commit in MANIFEST
                (riscv-ime-sdk-recipe.tar.xz) and the crosstool-NG
                configuration it rendered.

To rebuild: extract recipe/riscv-ime-sdk-recipe.tar.xz, copy upstream/*
into its work/tarballs/, and follow "Building the SDK tarball" in its
README.md.
EOF

"${TAR[@]}" -C "$stage" -cf - "$name-source" | "${XZ[@]}" > "$SDK_DIST/$src_tar.part"
mv "$SDK_DIST/$src_tar.part" "$SDK_DIST/$src_tar"
rm -rf "$stage"

(cd "$SDK_DIST" && sha256sum "$bin_tar" "$src_tar" > SHA256SUMS)
log "done:"
(cd "$SDK_DIST" && ls -l "$bin_tar" "$src_tar" SHA256SUMS) >&2
