# syntax=docker/dockerfile:1
# SPDX-FileCopyrightText: 2026 Openchip and Software Technologies, S.L.
# SPDX-License-Identifier: Apache-2.0
#
# Internal build environment of the SDK tarball; not published.
#
# AlmaLinux 8 has glibc 2.28, so the SDK built here runs on any Linux
# distribution with glibc >= 2.28. The image holds the build tools and the
# pinned crosstool-NG, and no SDK source. scripts/build-sdk.sh runs inside
# it and fetches the rest. build/builder/builder.def is the Apptainer
# equivalent, for hosts without Docker; keep the two in step.
#
# pins.hcl is generated from sdk.lock.yaml by `make lock`. Build with
# `make builder`.

# pins.hcl sets the digest-pinned base image. The default is a placeholder
# that satisfies the Dockerfile linter: a build without pins.hcl starts
# from scratch and fails at dnf.
ARG BASE_IMAGE=scratch

FROM ${BASE_IMAGE} AS builder

ENV LC_ALL=C
ENV TZ=Etc/UTC
ENV PATH=/opt/rh/gcc-toolset-14/root/usr/bin:/opt/crosstool-ng/bin:$PATH

COPY install-packages.sh build-crosstool-ng.sh /usr/local/libexec/sdk-builder/
RUN /usr/local/libexec/sdk-builder/install-packages.sh

ARG CROSSTOOLS_NG_REPO
ARG CROSSTOOLS_NG_COMMIT
RUN /usr/local/libexec/sdk-builder/build-crosstool-ng.sh \
        "${CROSSTOOLS_NG_REPO}" "${CROSSTOOLS_NG_COMMIT}"

# crosstool-NG refuses to run as root. Run this image with
# --user "$(id -u):$(id -g)", the repository at /src, and a writable,
# empty directory mounted at /opt/sdk; see `make release`.
WORKDIR /src
