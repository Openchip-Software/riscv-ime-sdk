#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Openchip and Software Technologies, S.L.
# SPDX-License-Identifier: Apache-2.0
#
# verify-sdk.sh — check the SDK tarball in dist/ before a release. Runs on
# a build host, not in the builder.
#
#   verify-sdk.sh [-r docker|apptainer|none] [-d <dist dir>] [-k]
#
#   -r  container runtime for the portability matrix and the consumer
#       recipes. Default: docker if present, else apptainer, else none.
#   -d  directory with the tarballs and SHA256SUMS. Default: dist/
#   -k  keep the work directory ($SDK_WORK/verify)
#
# Checks:
#
#   1 linkage      host ELF files need only glibc from the system, and no
#                  glibc symbol version above $GLIBC_FLOOR_MAX
#   2 paths        no text file names the build prefix or a builder path
#   3 relocation   tests/sdk/run-tests.sh on this host, SDK extracted to a
#                  random directory
#   4 matrix       tests/sdk/run-tests.sh in each base image, SDK mounted
#                  read-only at a path that is not the build prefix
#   5 recipes      release/sdk.def (apptainer) or release/Dockerfile
#                  (docker) builds, and the tests pass in the result as an
#                  unprivileged user
#   6 features     LTO, gdb with Python, every QEMU target: part of 3 and 4
#   7 sources      every component in MANIFEST has its source in the source
#                  tarball
#
# Prints one line per check and exits non-zero if any check failed. A
# check that cannot run here is reported as SKIP with the reason.

set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SDK_WORK="${SDK_WORK:-$REPO/work}"
DIST="$REPO/dist"
RUNTIME=""
KEEP=0
GLIBC_FLOOR_MAX="${GLIBC_FLOOR_MAX:-2.28}"
BUILD_PREFIX="${BUILD_PREFIX:-/opt/sdk}"
TUPLE=riscv64-openchip-linux-gnu

# The libraries of glibc itself. Everything else must come from the SDK.
GLIBC_LIBS='linux-vdso\.so\.1|ld-linux-x86-64\.so\.2|lib(c|m|dl|pthread|rt|util|resolv|anl)\.so\.[0-9]+'

# Base images of the portability matrix. almalinux:8 is the builder's own
# glibc, the oldest supported.
MATRIX=(almalinux:8 ubuntu:20.04 ubuntu:22.04 ubuntu:24.04 debian:12
        rockylinux/rockylinux:8 rockylinux/rockylinux:9)

# Portable cmake and ninja for the CMake test in base images that have
# neither, pinned like build/release/sources.list.
CMAKE_URL=https://github.com/Kitware/CMake/releases/download/v4.4.4/cmake-4.4.4-linux-x86_64.tar.gz
CMAKE_SHA256=e5bb807f7728cb60cd8b27ebc97a2edb469b68655f21e844a600c3575b76f5bb
NINJA_URL=https://github.com/ninja-build/ninja/releases/download/v1.13.2/ninja-linux.zip
NINJA_SHA256=5749cbc4e668273514150a80e387a957f933c6ed3f5f11e03fb30955e2bbead6

while getopts "r:d:k" opt; do
    case "$opt" in
        r) RUNTIME=$OPTARG ;;
        d) DIST=$(cd "$OPTARG" && pwd) ;;
        k) KEEP=1 ;;
        *) sed -n '5,13p' "$0" >&2; exit 2 ;;
    esac
done
if [[ -z "$RUNTIME" ]]; then
    if command -v docker >/dev/null; then RUNTIME=docker
    elif command -v apptainer >/dev/null; then RUNTIME=apptainer
    else RUNTIME=none
    fi
fi

log() { printf '[verify-sdk] %s\n' "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

declare -a RESULTS=()
failed=0
result() {   # result <check> PASS|FAIL|SKIP <detail>
    RESULTS+=("$(printf '%-12s %-4s %s' "$1" "$2" "$3")")
    [[ "$2" != FAIL ]] || failed=1
    log "$1: $2 $3"
}

shopt -s nullglob
bins=("$DIST"/riscv-ime-sdk-*-"$(uname -m)"-linux.tar.xz)
srcs=("$DIST"/riscv-ime-sdk-*-source.tar.xz)
[[ ${#bins[@]} -eq 1 ]] || die "need exactly one SDK tarball in $DIST, found ${#bins[@]}"
[[ ${#srcs[@]} -eq 1 ]] || die "need exactly one source tarball in $DIST, found ${#srcs[@]}"
shopt -u nullglob
BIN_TAR=${bins[0]}
SRC_TAR=${srcs[0]}

(cd "$DIST" && sha256sum -c --quiet SHA256SUMS) || die "SHA256SUMS does not match $DIST"

W="$SDK_WORK/verify"
chmod -R u+w "$W" 2>/dev/null || true
rm -rf "$W"
mkdir -p "$W"
# shellcheck disable=SC2329  # invoked by the trap
cleanup() { [[ "$KEEP" == 1 ]] || { chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"; }; }
trap cleanup EXIT

# Extract to a random, deep path: nothing may depend on where the SDK is.
reloc="$W/x/y/$(mktemp -u XXXXXXXX)"
mkdir -p "$reloc"
log "extracting $(basename "$BIN_TAR") to $reloc"
tar -xJf "$BIN_TAR" -C "$reloc"
SDK="$reloc/sdk"
[[ -x "$SDK/bin/$TUPLE-gcc" ]] || die "$BIN_TAR has no sdk/bin/$TUPLE-gcc"

# --- 1 linkage ---------------------------------------------------------------

audit="$W/audit-linkage.txt"
"$REPO/scripts/audit-linkage.sh" "$SDK" > "$audit"
floor=$(tail -n 1 "$audit")
bad=$(grep -E '^\s+\S' "$audit" | grep -vE "^\s+(/\S*/)?($GLIBC_LIBS)( |$)" \
      | grep -vF " => $SDK/" | grep -vE '^\s+(statically linked|not a dynamic executable)' || true)
if [[ -n "$bad" ]]; then
    result linkage FAIL "libraries from outside the SDK and glibc: $(sort -u <<< "$bad" | tr -s ' \t' ' ' | head -c 600)"
elif [[ "$(printf '%s\n%s\n' "GLIBC_$GLIBC_FLOOR_MAX" "$floor" | sort -V | tail -n 1)" != "GLIBC_$GLIBC_FLOOR_MAX" ]]; then
    result linkage FAIL "glibc floor $floor is above GLIBC_$GLIBC_FLOOR_MAX"
else
    result linkage PASS "only glibc from the system; floor $floor <= GLIBC_$GLIBC_FLOOR_MAX"
fi

# --- 2 paths -----------------------------------------------------------------

# Text files only: compiled-in prefixes in QEMU and gdb are relocated at
# run time. ALLOWED lists text files that keep the prefix on purpose:
# - QEMU's libvirt firmware descriptors, which QEMU does not read;
# - CPython's record of its own build configuration;
# - binutils' linker scripts, whose SEARCH_DIRs are sysroot-relative ("=")
#   and skipped when missing;
# - GCC's records for plugins and fixincludes, and a comment in curses.h;
# - libstdc++'s gdb hook, which turns its two paths into a relative one;
# - the README and container recipes, which name /opt/sdk as the install
#   path.
ALLOWED='^(share/qemu/firmware/[^/]+\.json'
ALLOWED+='|host/lib/python3\.[0-9]+/(_sysconfigdata_[^/]+\.py|config-[^/]+/(Makefile|python-config\.py)|_sysconfig_vars_[^/]+\.json|build-details\.json)'
ALLOWED+="|$TUPLE/lib/ldscripts/[^/]+"
ALLOWED+="|lib/gcc/$TUPLE/[^/]+/(plugin/gtype\.state|plugin/include/.+|install-tools/.+)"
ALLOWED+="|libexec/gcc/$TUPLE/[^/]+/install-tools/.+"
ALLOWED+="|$TUPLE/sysroot/usr/include/curses\.h"
ALLOWED+="|$TUPLE/sysroot/lib/libstdc\+\+\.so\.[0-9.]+-gdb\.py"
ALLOWED+='|share/doc/sdk/README\.md|share/sdk/(Dockerfile|sdk\.def))$'
leaks=$(cd "$SDK" && grep -rIl -e "$BUILD_PREFIX" -e '/src/work' -e "$SDK_WORK" . 2>/dev/null \
        | sed 's|^\./||' | grep -vE "$ALLOWED" || true)
if [[ -n "$leaks" ]]; then
    result paths FAIL "build paths in: $(tr '\n' ' ' <<< "$leaks" | head -c 600)"
else
    result paths PASS "no text file names $BUILD_PREFIX or a builder path, outside the allowed list"
fi

# --- tools for the CMake test ------------------------------------------------

TOOLS="$W/tools"
mkdir -p "$TOOLS"
cache="$SDK_WORK/tarballs"
mkdir -p "$cache"
fetch() {   # fetch <url> <sha256> -> path in the cache
    local f="$cache/${1##*/}"
    [[ "$1" == *ninja-linux.zip ]] && f="$cache/ninja-linux-1.13.2.zip"
    [[ -s "$f" ]] || curl -fsSL --retry 3 -o "$f" "$1"
    echo "$2  $f" | sha256sum -c --quiet - >&2
    printf '%s\n' "$f"
}
if f=$(fetch "$CMAKE_URL" "$CMAKE_SHA256") && n=$(fetch "$NINJA_URL" "$NINJA_SHA256"); then
    mkdir -p "$TOOLS/cmake"
    tar -xzf "$f" -C "$TOOLS/cmake" --strip-components=1
    (cd "$TOOLS" && unzip -q -o "$n")
else
    log "cannot fetch cmake or ninja; the CMake test is skipped"
    TOOLS=""
fi

# --- 3 relocation + 6 features, on this host ----------------------------------

if sh "$REPO/tests/sdk/run-tests.sh" "$SDK" "$TOOLS" > "$W/host.log" 2>&1 \
        && tail -n 1 "$W/host.log" | grep -qx 'ALL TESTS PASSED'; then
    result relocation PASS "tests/sdk/run-tests.sh on $(. /etc/os-release && echo "$PRETTY_NAME"), SDK at $reloc"
else
    tail -n 30 "$W/host.log" >&2
    result relocation FAIL "tests/sdk/run-tests.sh on this host; log: $W/host.log (kept with -k)"
fi

# --- 4 matrix ------------------------------------------------------------------

# run_in_image <image> <log>: the SDK, the tests and the tools read-only
# at /sdk, /tests and /tools.
run_in_image() {
    local image=$1 log=$2 tools_arg=""
    [[ -n "$TOOLS" ]] && tools_arg=/tools
    case "$RUNTIME" in
        docker)
            docker run --rm --user "$(id -u):$(id -g)" \
                -v "$SDK:/sdk:ro" -v "$REPO/tests/sdk:/tests:ro" \
                ${TOOLS:+-v "$TOOLS:/tools:ro"} \
                "$image" sh /tests/run-tests.sh /sdk $tools_arg ;;
        apptainer)
            apptainer exec --containall --cleanenv \
                --bind "$SDK:/sdk:ro,$REPO/tests/sdk:/tests:ro${TOOLS:+,$TOOLS:/tools:ro}" \
                "docker://$image" sh /tests/run-tests.sh /sdk $tools_arg ;;
    esac > "$log" 2>&1 && tail -n 1 "$log" | grep -qx 'ALL TESTS PASSED'
}

if [[ "$RUNTIME" == none ]]; then
    result matrix SKIP "no docker or apptainer on this host"
else
    for image in "${MATRIX[@]}"; do
        log="$W/matrix-${image//[:\/]/_}.log"
        if run_in_image "$image" "$log"; then
            result "matrix" PASS "$image ($RUNTIME)"
        else
            tail -n 30 "$log" >&2
            result "matrix" FAIL "$image ($RUNTIME); log: $log (kept with -k)"
        fi
    done
fi

# --- 5 recipes -----------------------------------------------------------------

recipe="$W/recipe"
mkdir -p "$recipe"
ln "$BIN_TAR" "$recipe/" 2>/dev/null || cp "$BIN_TAR" "$recipe/"
tarball=$(basename "$BIN_TAR")
case "$RUNTIME" in
    apptainer)
        cp "$REPO/release/sdk.def" "$recipe/"
        if (cd "$recipe" && apptainer build --fakeroot --build-arg SDK_TARBALL="$tarball" sdk.sif sdk.def) \
                > "$W/recipe.log" 2>&1 \
           && apptainer exec --containall --cleanenv \
                --bind "$REPO/tests/sdk:/tests:ro${TOOLS:+,$TOOLS:/tools:ro}" \
                "$recipe/sdk.sif" sh /tests/run-tests.sh /opt/sdk ${TOOLS:+/tools} >> "$W/recipe.log" 2>&1 \
           && tail -n 1 "$W/recipe.log" | grep -qx 'ALL TESTS PASSED'; then
            result recipes PASS "release/sdk.def built with apptainer --fakeroot; tests pass as $(id -un)"
        else
            tail -n 30 "$W/recipe.log" >&2
            result recipes FAIL "release/sdk.def; log: $W/recipe.log (kept with -k)"
        fi ;;
    docker)
        cp "$REPO/release/Dockerfile" "$recipe/"
        if docker build --build-arg SDK_TARBALL="$tarball" -t riscv-ime-sdk-verify:local "$recipe" > "$W/recipe.log" 2>&1 \
           && docker run --rm --user "$(id -u):$(id -g)" -v "$REPO/tests/sdk:/tests:ro" \
                ${TOOLS:+-v "$TOOLS:/tools:ro"} riscv-ime-sdk-verify:local \
                sh /tests/run-tests.sh /opt/sdk ${TOOLS:+/tools} >> "$W/recipe.log" 2>&1 \
           && tail -n 1 "$W/recipe.log" | grep -qx 'ALL TESTS PASSED'; then
            result recipes PASS "release/Dockerfile built; tests pass as uid $(id -u)"
        else
            tail -n 30 "$W/recipe.log" >&2
            result recipes FAIL "release/Dockerfile; log: $W/recipe.log (kept with -k)"
        fi
        docker image rm riscv-ime-sdk-verify:local >/dev/null 2>&1 || true ;;
    none)
        result recipes SKIP "no docker or apptainer on this host" ;;
esac

# --- 7 sources -------------------------------------------------------------------

listing="$W/source-listing.txt"
tar -tJf "$SRC_TAR" > "$listing"
missing=()
# need <description> <regex of a path in the source tarball>
need() { grep -qE "$2" "$listing" || missing+=("$1"); }
while IFS= read -r line; do
    key=${line%%:*}
    read -r version repo commit _ <<< "${line#*:}"
    case "$key" in
        sdk_version|target|host|linkage|glibc_floor|builder_image|recipe_commit) ;;
        crosstool-ng)  need "$key" '/crosstool-ng/crosstool-ng-[0-9a-f]{40}\.tar\.xz$' ;;
        gcc)           need "$key" "/upstream/gcc-git-${commit:0:8}\.tar\.bz2$" ;;
        binutils-gdb)  need "$key" "/upstream/binutils-git-${commit:0:8}\.tar\.bz2$" ;;
        qemu)          need "$key" "/qemu/qemu-$commit\.tar\.xz$" ;;
        linux-headers) need "$key $version" "/upstream/linux-$version\.tar\." ;;
        host-*)        need "$key $version" "/upstream/(${key#host-}|Python)-$version\.tar\." ;;
        *)             need "$key $version" "/upstream/$key-$version\.tar\." ;;
    esac
done < "$SDK/share/sdk/MANIFEST"
need "build recipe" '/recipe/riscv-ime-sdk-recipe\.tar\.xz$'
if [[ ${#missing[@]} -gt 0 ]]; then
    result sources FAIL "no source in $(basename "$SRC_TAR") for: ${missing[*]}"
else
    result sources PASS "every MANIFEST component has its source in $(basename "$SRC_TAR")"
fi

# --- summary -------------------------------------------------------------------

echo
printf '%s\n' "${RESULTS[@]}"
exit "$failed"
