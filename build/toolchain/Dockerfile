# syntax=docker/dockerfile:1
#
# riscv64 cross toolchain: crosstool-NG builds binutils, gcc, glibc and gdb
# into /opt/openchip/toolchain.
#
# Every input of this image lives in this directory, and nothing outside it
# is read. CI tags the image with the git tree hash of build/toolchain, so
# any change here produces a new tag and a rebuild, and no other change
# does. pins.hcl is generated from sdk.lock.yaml by `make lock`.
#
# To force a rebuild with unchanged inputs, bump this number: 1

ARG BASE_IMAGE

FROM ${BASE_IMAGE} AS buildtools

ENV LC_ALL=C
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

RUN apt-get update \
    && apt-get install -y ca-certificates \
                    build-essential autoconf bison flex gawk git make \
                    texinfo help2man libncurses5-dev python3-dev python3-distutils-extra \
                    libtool libtool-bin unzip wget curl rsync \
    && rm -rf /var/lib/apt/lists/*

FROM buildtools AS crosstool-ng

ARG CROSSTOOLS_NG_REPO
ARG CROSSTOOLS_NG_COMMIT

# BuildKit fetches the public repo itself, with no credentials.
ADD ${CROSSTOOLS_NG_REPO}#${CROSSTOOLS_NG_COMMIT} /src/crosstool-ng

# ADD drops .git, so git-version-gen cannot run `git describe`. It reads
# .tarball-version instead, which must start with a digit.
WORKDIR /src/crosstool-ng
RUN printf '0+openchip.%.12s\n' "${CROSSTOOLS_NG_COMMIT}" > .tarball-version \
    && ./bootstrap \
    && ./configure --prefix=/opt/crosstool-ng \
    && make -j"$(nproc)" install

FROM buildtools AS build

ARG GCC_REPO
ARG GCC_COMMIT
ARG BINUTILS_GDB_REPO
ARG BINUTILS_GDB_COMMIT

ADD ${GCC_REPO}#${GCC_COMMIT} /src/gcc
ADD ${BINUTILS_GDB_REPO}#${BINUTILS_GDB_COMMIT} /src/binutils
COPY --link --from=crosstool-ng /opt/crosstool-ng /opt/crosstool-ng

# crosstool-NG refuses to run as root. The toolchain is built in place at
# its final prefix, so no path in it refers to the build host.
RUN useradd -m build \
    && install -d -o build -g build /opt/openchip /work

USER build
WORKDIR /work

# crosstool-NG checks out a devel source as <pkg>-git-<first 8 hex digits
# of the commit>, then packs it into its local tarball directory. When that
# tarball already exists it uses it and never contacts the repo. Pack the
# sources fetched above under that name, so that crosstool-NG needs no
# network access for them, and still runs its usual devel source steps: it
# replaces config.guess and config.sub, and it touches the generated
# autotools files so that make does not try to regenerate them.
RUN mkdir -p "${HOME}/src" \
    && for spec in "gcc ${GCC_COMMIT}" "binutils ${BINUTILS_GDB_COMMIT}"; do \
           set -- $spec; \
           name="$1-git-$(printf %.8s "$2")"; \
           tar -C /src --transform "s|^$1|${name}|" -cjf "${HOME}/src/${name}.tar.bz2" "$1" || exit 1; \
       done

COPY defconfig.in /work/defconfig.in

# The package version names the gcc commit, not the SDK version, so that
# an SDK version bump does not change this image.
RUN sed -e "s|@GCC_URL@|${GCC_REPO}|g" \
        -e "s|@GCC_REVISION@|${GCC_COMMIT}|g" \
        -e "s|@BINUTILS_URL@|${BINUTILS_GDB_REPO}|g" \
        -e "s|@BINUTILS_REVISION@|${BINUTILS_GDB_COMMIT}|g" \
        -e "s|@PKGVERSION@|OpenChip-IME-$(printf %.12s "${GCC_COMMIT}")|g" \
        defconfig.in > defconfig \
    && ! grep -n '@[A-Z_]*@' defconfig \
    && /opt/crosstool-ng/bin/ct-ng defconfig

# The console log only shows lines that crosstool-NG classifies as errors,
# which drops the linker and compiler diagnostics. On failure, print the
# matching lines of the full build.log and the memory state, then fail.
# On success, delete the build tree in the same step so that the layer
# does not keep it.
RUN /opt/crosstool-ng/bin/ct-ng build."$(nproc)" || { \
        echo "=== build.log: errors with context ==="; \
        grep -nE -B10 -A2 'undefined reference|collect2|error:|memory exhausted|Killed|signal 9' build.log | tail -n 400; \
        echo "=== build.log: last 100 lines ==="; \
        tail -n 100 build.log; \
        echo "=== memory ==="; \
        free -h; \
        exit 1; \
    } \
    && rm -rf /work/.build "${HOME}/src"

# The published image: the installed toolchain and nothing else.
FROM scratch AS toolchain
COPY --link --chown=0:0 --from=build /opt/openchip/toolchain /opt/openchip/toolchain
