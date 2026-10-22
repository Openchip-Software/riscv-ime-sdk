#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Openchip and Software Technologies, S.L.
# SPDX-License-Identifier: Apache-2.0
#
# build-sdk.sh — build the SDK tarball, the source tarball and SHA256SUMS
# into dist/. The single entry point of the release build. It runs inside
# the internal builder (build/builder), as a non-root user, with the
# repository as the working directory and a writable directory at
# $SDK_PREFIX (default /opt/sdk). `make release` sets this up.
#
#   build-sdk.sh [step...]
#
# Steps, in order; with no argument all of them run:
#
#   fetch      download and verify every source; nothing after it downloads
#              except crosstool-NG (its release tarballs) and QEMU's
#              configure (its pinned meson subprojects)
#   hostlibs   zlib, libffi, pcre2, glib, pixman into $SDK_PREFIX/host
#   python     CPython into $SDK_PREFIX/host, for the cross gdb
#   toolchain  crosstool-NG: binutils, gcc, glibc, gdb into $SDK_PREFIX
#   qemu       QEMU into $SDK_PREFIX
#   finalize   RUNPATHs, CMake toolchain file, env.sh, MANIFEST, licenses,
#              read-only prefix
#   package    scripts/package-sdk.sh: dist/
#
# A step that finished leaves a stamp in $SDK_WORK/stamps and is skipped on
# the next run. Delete the stamp, or $SDK_WORK, to redo it. Redoing
# toolchain redoes qemu and finalize; redoing toolchain or qemu after
# finalize also redoes hostlibs and python, which finalize strips.
#
# Inputs, all from this repository: build/release/pins.hcl (component
# commits, SDK version), build/release/sources.list (other tarballs),
# build/release/defconfig.in (crosstool-NG configuration).
#
# Environment:
#   SDK_PREFIX    install prefix, at the same path in every build  [/opt/sdk]
#   SDK_WORK      build trees and stamps                           [./work]
#   SDK_TARBALLS  download cache, crosstool-NG CT_LOCAL_TARBALLS_DIR
#                                                                  [$SDK_WORK/tarballs]
#   SDK_DIST      output directory                                 [./dist]
#   SDK_LINKAGE   baseline | static-musl                           [baseline]
#   JOBS          parallel jobs                                    [nproc]

set -euo pipefail

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SDK_PREFIX="${SDK_PREFIX:-/opt/sdk}"
SDK_WORK="${SDK_WORK:-$REPO/work}"
SDK_TARBALLS="${SDK_TARBALLS:-$SDK_WORK/tarballs}"
SDK_DIST="${SDK_DIST:-$REPO/dist}"
SDK_LINKAGE="${SDK_LINKAGE:-baseline}"
JOBS="${JOBS:-$(nproc)}"
BUILD_PYTHON="${BUILD_PYTHON:-python3.12}"

TUPLE=riscv64-openchip-linux-gnu
PINS="$REPO/build/release/pins.hcl"
SOURCES="$REPO/build/release/sources.list"
HOSTDIR="$SDK_PREFIX/host"

export SDK_PREFIX SDK_WORK SDK_TARBALLS SDK_DIST SDK_LINKAGE TUPLE

log() { printf '[build-sdk] %s\n' "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# pin <KEY>: the value of KEY = "value" in build/release/pins.hcl.
pin() {
    local v
    v=$(sed -n "s/^ *$1 *= *\"\(.*\)\"\$/\1/p" "$PINS")
    [[ -n "$v" ]] || die "$1 not in $PINS"
    printf '%s\n' "$v"
}

# source_field <name> <field>: field 2 (version), 3 (sha256) or 4 (url) of
# the line for <name> in build/release/sources.list.
source_field() {
    awk -v n="$1" -v f="$2" '$1 == n { print $f; found = 1 } END { exit !found }' "$SOURCES" \
        || die "$1 not in $SOURCES"
}

source_tarball() { local url; url=$(source_field "$1" 4); printf '%s\n' "$SDK_TARBALLS/${url##*/}"; }

# unpack <name>: a fresh source tree of a sources.list entry; prints its path.
unpack() {
    local dir="$SDK_WORK/build/$1"
    rm -rf "$dir"
    mkdir -p "$dir"
    tar -xf "$(source_tarball "$1")" -C "$dir" --strip-components=1
    printf '%s\n' "$dir"
}

# Paths of the steps that build against $HOSTDIR. pkg-config sees only
# $HOSTDIR, so no system library is picked up. Not for the toolchain step:
# crosstool-NG refuses to run with LD_LIBRARY_PATH set.
host_env() {
    export PATH="$SDK_WORK/tools/bin:$PATH"
    export PKG_CONFIG_PATH="$HOSTDIR/lib/pkgconfig"
    export PKG_CONFIG_LIBDIR="$HOSTDIR/lib/pkgconfig"
    export LD_LIBRARY_PATH="$HOSTDIR/lib"
}

meson() { "$BUILD_PYTHON" "$SDK_WORK/tools/meson/meson.py" "$@"; }

# ---------------------------------------------------------------------------

step_fetch() {
    local name version sha url f dir c commit repo short

    mkdir -p "$SDK_TARBALLS" "$SDK_WORK/src"

    while read -r name version sha url; do
        [[ -z "$name" || "$name" == \#* ]] && continue
        f="$SDK_TARBALLS/${url##*/}"
        if [[ ! -s "$f" ]]; then
            log "downloading $name $version"
            curl -fsSL --retry 3 -o "$f.part" "$url"
            mv "$f.part" "$f"
        fi
        echo "$sha  $f" | sha256sum -c --quiet - || die "checksum mismatch: $f"
    done < "$SOURCES"

    # crosstool-NG checks out a devel source as <pkg>-git-<first 8 hex digits
    # of the commit>, and uses <pkg>-git-<8 hex>.tar.bz2 from its local
    # tarball directory instead when that exists. Pack the pinned commits
    # under that name, so crosstool-NG never contacts the repos and the
    # source tarball holds exactly what was built.
    for c in gcc:GCC binutils:BINUTILS_GDB; do
        repo=$(pin "${c#*:}_REPO")
        commit=$(pin "${c#*:}_COMMIT")
        short="${c%%:*}-git-${commit:0:8}"
        f="$SDK_TARBALLS/$short.tar.bz2"
        [[ -s "$f" ]] && continue
        log "fetching ${c%%:*} $commit"
        dir="$SDK_WORK/src/$short"
        rm -rf "$dir"
        git init -q "$dir"
        git -C "$dir" fetch -q --depth 1 "$repo" "$commit"
        git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
        rm -rf "$dir/.git"
        tar -C "$SDK_WORK/src" -cjf "$f.part" "$short"
        mv "$f.part" "$f"
        rm -rf "$dir"
    done

    # QEMU keeps .git: its scripts take different paths without it, and
    # configure fetches the meson subprojects pinned in subprojects/*.wrap.
    commit=$(pin QEMU_COMMIT)
    dir="$SDK_WORK/src/qemu"
    if [[ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" != "$commit" ]]; then
        log "fetching qemu $commit"
        rm -rf "$dir"
        git init -q "$dir"
        git -C "$dir" fetch -q --depth 1 "$(pin QEMU_REPO)" "$commit"
        git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
    fi
}

step_hostlibs() {
    local d

    host_env
    mkdir -p "$SDK_WORK/tools"

    # Build tools first. Neither is installed into the SDK.
    d=$(unpack meson)
    rm -rf "$SDK_WORK/tools/meson"
    mv "$d" "$SDK_WORK/tools/meson"
    d=$(unpack patchelf)
    (cd "$d" && ./configure --prefix="$SDK_WORK/tools" && make -j"$JOBS" && make install)

    # zlib, libffi and pcre2 are static and position-independent: they are
    # linked into glib, QEMU and CPython, and never needed at run time.
    d=$(unpack zlib)
    (cd "$d" && CFLAGS="-O2 -fPIC" ./configure --prefix="$HOSTDIR" --static \
        && make -j"$JOBS" && make install)

    d=$(unpack libffi)
    (cd "$d" && ./configure --prefix="$HOSTDIR" --libdir="$HOSTDIR/lib" \
            --disable-shared --enable-static --with-pic --disable-docs \
            --disable-multi-os-directory \
        && make -j"$JOBS" && make install)

    d=$(unpack pcre2)
    (cd "$d" && ./configure --prefix="$HOSTDIR" --libdir="$HOSTDIR/lib" \
            --disable-shared --enable-static --with-pic \
        && make -j"$JOBS" && make install)

    # glib is shared: QEMU TCG plugins built against $HOSTDIR use the same
    # glib as QEMU. Every optional dependency on a system library is off.
    d=$(unpack glib)
    meson setup "$d/_build" "$d" \
        --prefix="$HOSTDIR" --libdir=lib --buildtype=release \
        --wrap-mode=nofallback -Ddefault_library=shared \
        -Dselinux=disabled -Dxattr=false -Dlibmount=disabled \
        -Dnls=disabled -Dlibelf=disabled -Dsysprof=disabled \
        -Dintrospection=disabled -Ddtrace=disabled -Dsystemtap=disabled \
        -Dman-pages=disabled -Ddocumentation=false -Dtests=false
    meson install -C "$d/_build"

    # pixman is static; only qemu-system links it. OpenMP is off, or QEMU
    # would need libgomp.
    d=$(unpack pixman)
    meson setup "$d/_build" "$d" \
        --prefix="$HOSTDIR" --libdir=lib --buildtype=release \
        --wrap-mode=nofallback -Ddefault_library=static \
        -Dopenmp=disabled -Dgtk=disabled -Dlibpng=disabled \
        -Dtests=disabled -Ddemos=disabled
    meson install -C "$d/_build"
}

step_python() {
    local d

    host_env
    # Shared libpython, so that gdb can embed it. gdb finds the standard
    # library relative to its own location, because $HOSTDIR is inside
    # gdb's prefix (gdb's PYTHON_PATH_RELOCATABLE). Modules whose library
    # is not in $HOSTDIR (ssl, sqlite3, lzma, bz2, readline, curses, tk)
    # are not built.
    d=$(unpack python)
    (cd "$d" && ./configure --prefix="$HOSTDIR" --enable-shared \
            --without-ensurepip --disable-test-modules \
            CPPFLAGS="-I$HOSTDIR/include" LDFLAGS="-L$HOSTDIR/lib" \
        && make -j"$JOBS" && make install)
    patchelf --set-rpath '$ORIGIN/../lib' "$HOSTDIR/bin/python3"*[0-9]
    "$HOSTDIR/bin/python3" -c 'import sys, zlib, ctypes; print("python", sys.version)'
}

step_toolchain() {
    local ctdir="$SDK_WORK/ctng" gcc_commit

    export PATH="$SDK_WORK/tools/bin:$PATH"
    unset LD_LIBRARY_PATH PKG_CONFIG_PATH PKG_CONFIG_LIBDIR
    gcc_commit=$(pin GCC_COMMIT)
    mkdir -p "$ctdir"
    [[ -d "$SDK_PREFIX" ]] && chmod -R u+w "$SDK_PREFIX"
    # crosstool-NG does not empty the prefix (CT_RM_RF_PREFIX_DIR is unset
    # to keep host/), so remove what an earlier, failed run left there.
    find "$SDK_PREFIX" -mindepth 1 -maxdepth 1 ! -name host -exec rm -rf {} +
    rm -f "$SDK_WORK/stamps/qemu" "$SDK_WORK/stamps/finalize"

    # The package version names the gcc commit, as in build/toolchain.
    sed -e "s|@GCC_URL@|$(pin GCC_REPO)|g" \
        -e "s|@GCC_REVISION@|$gcc_commit|g" \
        -e "s|@BINUTILS_URL@|$(pin BINUTILS_GDB_REPO)|g" \
        -e "s|@BINUTILS_REVISION@|$(pin BINUTILS_GDB_COMMIT)|g" \
        -e "s|@PKGVERSION@|OpenChip-IME-${gcc_commit:0:12}|g" \
        -e "s|@PREFIX@|$SDK_PREFIX|g" \
        -e "s|@TARBALLS_DIR@|$SDK_TARBALLS|g" \
        -e "s|@PYTHON@|$HOSTDIR/bin/python3|g" \
        "$REPO/build/release/defconfig.in" > "$ctdir/defconfig"
    if grep -n '@[A-Z_]*@' "$ctdir/defconfig"; then
        die "unrendered placeholder in defconfig"
    fi

    cd "$ctdir"
    # kconfig only warns about a symbol it does not know. Treat that as an
    # error: a misspelt CT_* option would otherwise be dropped silently.
    ct-ng defconfig 2>&1 | tee defconfig.log
    if grep -iE 'warning|unknown symbol' defconfig.log; then
        die "crosstool-NG rejected a symbol in build/release/defconfig.in"
    fi

    # build.log.bz2 goes into the prefix, so only show the end on failure.
    ct-ng build."$JOBS" || {
        bzcat -f "$SDK_PREFIX/build.log.bz2" build.log 2>/dev/null | tail -n 200 || true
        die "crosstool-NG build failed; full log in $ctdir/build.log"
    }
    rm -rf "$ctdir/.build"
}

step_qemu() {
    local src="$SDK_WORK/src/qemu"

    host_env
    chmod -R u+w "$SDK_PREFIX"
    rm -rf "$src/build"
    mkdir -p "$src/build"
    cd "$src/build"
    # The target list and plugins match build/qemu. QEMU rejects --static
    # together with --enable-plugins, so it links glib dynamically from
    # $HOSTDIR. No GUI library is installed in the builder, so the GUI
    # front ends are off; VNC needs no extra library and stays on.
    # The builder's kernel headers (RHEL 8) have linux/openat2.h without
    # RESOLVE_CACHED (Linux 5.12), which linux-user/strace.c uses.
    ../configure \
        --prefix="$SDK_PREFIX" \
        --python="$(command -v "$BUILD_PYTHON")" \
        --target-list=riscv64-linux-user,riscv64-softmmu,riscv32-softmmu \
        --enable-plugins \
        --disable-docs \
        --disable-gtk --disable-sdl --disable-opengl --disable-curses \
        --extra-cflags="-DRESOLVE_CACHED=0x20" \
        --extra-ldflags="-static-libstdc++ -static-libgcc"
    make -j"$JOBS"
    make install
}

# relative_rpath <elf>: '$ORIGIN/<path from the file's directory to $HOSTDIR/lib>'
relative_rpath() {
    printf '$ORIGIN/%s\n' "$(realpath --relative-to="$(dirname "$1")" "$HOSTDIR/lib")"
}

step_finalize() {
    local f needed lib share="$SDK_PREFIX/share" n

    host_env
    chmod -R u+w "$SDK_PREFIX"

    # Static archives, libtool files and documentation of the host
    # libraries are not needed at run time. Headers and pkg-config files
    # stay: QEMU plugins are built against glib.
    find "$HOSTDIR/lib" -maxdepth 1 \( -name '*.a' -o -name '*.la' \) -delete
    rm -rf "$HOSTDIR/share/man" "$HOSTDIR/share/doc" "$HOSTDIR/share/gtk-doc"
    rm -rf "$HOSTDIR"/lib/python3.*/{test,idlelib,tkinter,turtledemo}
    # glib's tools and scripts, and Python's helper scripts, name the
    # builder's interpreter or the build prefix, and gdb and QEMU do not
    # use them. Keep only the python3 executable.
    find "$HOSTDIR/bin" -mindepth 1 ! -name 'python3' ! -name 'python3.[0-9]*[0-9]' -delete
    rm -rf "$HOSTDIR/libexec"
    # libtool archives name the build prefix and are not needed to link.
    # glib's gdb helpers are installed under a path named after the prefix.
    find "$SDK_PREFIX" -name '*.la' -delete
    rm -rf "$HOSTDIR/share/gdb"
    # pkg-config files: prefix relative to the file, and every other path
    # relative to the prefix, not to the build prefix.
    while IFS= read -r -d '' f; do
        sed -i -e "/^prefix=/!s|$(dirname "$(dirname "$(dirname "$f")")")|\${prefix}|g" \
               -e 's|^prefix=.*|prefix=${pcfiledir}/../..|' "$f"
    done < <(find "$SDK_PREFIX" -path "$SDK_PREFIX/$TUPLE" -prune -o \
                  -path '*/pkgconfig/*.pc' -print0)
    # crosstool-NG's gdbinit, for users to source, loads the libstdc++
    # pretty printers. Find them relative to gdb's data directory, not at
    # the build prefix.
    sed -i -e 's/^import sys$/import os, sys/' \
           -e "s|'$SDK_PREFIX/share/\(gcc-[^/']*/python\)'|os.path.join(gdb.PYTHONDIR, '..', '..', '\1')|" \
        "$share/gdb/gdbinit"

    # Every host executable or library that needs a library from $HOSTDIR
    # finds it through a RUNPATH relative to its own location.
    while IFS= read -r -d '' f; do
        file -b "$f" | grep -q '^ELF.*x86-64' || continue
        needed=$(readelf -d "$f" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
        for lib in $needed; do
            if [[ -e "$HOSTDIR/lib/$lib" ]]; then
                patchelf --set-rpath "$(relative_rpath "$f")" "$f"
                break
            fi
        done
    done < <(find "$SDK_PREFIX" -path "$SDK_PREFIX/$TUPLE/sysroot" -prune -o \
                  -type f \( -perm -u+x -o -name '*.so*' \) -print0)

    install -d "$share/sdk" "$share/doc/sdk" "$share/licenses"
    install -m 0644 "$REPO/build/release/README.md" "$share/doc/sdk/README.md"
    install -m 0644 "$REPO/build/release/env.sh" "$share/sdk/env.sh"
    install -m 0644 "$REPO/build/release/toolchain.cmake" "$share/sdk/toolchain-$TUPLE.cmake"
    install -m 0644 "$REPO/release/Dockerfile" "$REPO/release/sdk.def" "$share/sdk/"

    # crosstool-NG installs the licences of what it builds. Add the rest.
    install_license qemu    "$SDK_WORK/src/qemu" COPYING COPYING.LIB LICENSE
    for n in zlib libffi pcre2 glib pixman python; do
        install_license "$n" "$SDK_WORK/build/$n" \
            LICENSE LICENCE LICENCE.md COPYING COPYING.LIB LICENSES/LGPL-2.1-or-later.txt
    done

    write_manifest > "$share/sdk/MANIFEST"
    cat "$share/sdk/MANIFEST" >&2

    chmod -R a-w "$SDK_PREFIX"
}

# install_license <name> <source dir> <file>...: copy the licence files of
# a component that exist into share/licenses/<name>.
install_license() {
    local name="$1" dir="$2" f n=0
    shift 2
    install -d "$SDK_PREFIX/share/licenses/$name"
    for f in "$@"; do
        [[ -f "$dir/$f" ]] || continue
        install -m 0644 "$dir/$f" "$SDK_PREFIX/share/licenses/$name/${f##*/}"
        n=$((n + 1))
    done
    [[ "$n" -gt 0 ]] || die "no licence file for $name in $dir"
}

ctng_value() {
    sed -n "s/^CT_$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$SDK_WORK/ctng/.config"
}

write_manifest() {
    local n
    echo "sdk_version:       $(pin SDK_VERSION)"
    echo "target:            $TUPLE"
    echo "host:              $(uname -m)-linux-gnu"
    echo "linkage:           $SDK_LINKAGE"
    echo "glibc_floor:       $("$REPO/scripts/audit-linkage.sh" "$SDK_PREFIX" | tail -n 1)"
    echo "builder_image:     $(pin BASE_IMAGE)"
    echo "recipe_commit:     $(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)$(
        git -C "$REPO" diff --quiet HEAD 2>/dev/null || echo ' (modified)')"
    echo "crosstool-ng:      $(ctng_value VERSION)"
    echo "gcc:               $("$SDK_PREFIX/bin/$TUPLE-gcc" -dumpversion) $(pin GCC_REPO) $(pin GCC_COMMIT)"
    echo "binutils-gdb:      $("$SDK_PREFIX/bin/$TUPLE-ld" --version | sed -n '1s/.* //p') $(pin BINUTILS_GDB_REPO) $(pin BINUTILS_GDB_COMMIT)"
    echo "gdb:               $(ctng_value GDB_VERSION)"
    echo "glibc:             $(ctng_value GLIBC_VERSION)"
    echo "linux-headers:     $(ctng_value LINUX_VERSION)"
    # The companion libraries crosstool-NG built, linked into the host tools.
    for n in GMP MPFR MPC ISL ZLIB ZSTD EXPAT NCURSES LIBICONV GETTEXT; do
        if [[ "$(ctng_value "$n"_NEEDED)" == y ]]; then
            printf '%-18s %s\n' "$(tr 'A-Z' 'a-z' <<< "$n"):" "$(ctng_value "$n"_VERSION)"
        fi
    done
    echo "qemu:              $(cat "$SDK_WORK/src/qemu/VERSION") $(pin QEMU_REPO) $(pin QEMU_COMMIT)"
    # The libraries in host/, from build/release/sources.list.
    while read -r n version _ _; do
        [[ -z "$n" || "$n" == \#* || "$n" == meson || "$n" == patchelf ]] && continue
        printf '%-18s %s\n' "host-$n:" "$version"
    done < "$SOURCES"
}

step_package() {
    "$REPO/scripts/package-sdk.sh"
}

# ---------------------------------------------------------------------------

STEPS=(fetch hostlibs python toolchain qemu finalize package)

case "$SDK_LINKAGE" in
    baseline) ;;
    static-musl)
        die "SDK_LINKAGE=static-musl is not implemented" ;;
    *)  die "SDK_LINKAGE must be baseline or static-musl, not '$SDK_LINKAGE'" ;;
esac

[[ "$(id -u)" != 0 ]] || die "run as a non-root user: crosstool-NG refuses to run as root"
command -v ct-ng >/dev/null || die "ct-ng not on PATH: run inside the builder (build/builder)"
mkdir -p "$SDK_PREFIX" 2>/dev/null || true
[[ -d "$SDK_PREFIX" && -O "$SDK_PREFIX" ]] \
    || die "$SDK_PREFIX must be a directory owned by $(id -un); mount one there"
# Some tools want a writable home; a container user may not have one.
[[ -w "${HOME:-/nonexistent}" ]] || export HOME="$SDK_WORK/home"
mkdir -p "$HOME" "$SDK_WORK/stamps"

if [[ $# -eq 0 ]]; then set -- "${STEPS[@]}"; fi
for step in "$@"; do
    [[ " ${STEPS[*]} " == *" $step "* ]] || die "unknown step '$step'; steps: ${STEPS[*]}"
done
# finalize removes the static libraries and tools in $HOSTDIR that the
# toolchain and qemu steps build against. Rebuild $HOSTDIR before either.
s="$SDK_WORK/stamps"
if [[ -e "$s/finalize" && ( ! -e "$s/toolchain" || ! -e "$s/qemu" ) ]]; then
    log "finalize has stripped $HOSTDIR: redoing hostlibs, python and finalize"
    rm -f "$s/hostlibs" "$s/python" "$s/finalize"
fi
for step in "$@"; do
    stamp="$SDK_WORK/stamps/$step"
    if [[ -e "$stamp" && "$step" != package ]]; then
        log "step $step: done earlier, skipping (delete $stamp to redo)"
        continue
    fi
    log "step $step: start"
    # Not `cd && step`: errexit is off inside a function called from an
    # && list.
    (
        cd "$REPO"
        "step_$step"
    )
    touch "$stamp"
    log "step $step: done"
done
