# SPDX-FileCopyrightText: 2026 Openchip and Software Technologies, S.L.
# SPDX-License-Identifier: Apache-2.0

# IME SDK — build entry point. The build graph is docker-bake.hcl; this
# file passes it the pins rendered from sdk.lock.yaml.
#
#   make lock                resolve components.yaml -> sdk.lock.yaml + build/*/pins.hcl
#   make sdk                 build the SDK image, reusing component images
#                            from GHCR as CI does
#   make toolchain | qemu    build one component from source
#   make hashes              print the component image tags CI looks for
#
#   make release             build dist/: SDK tarball, source tarball, SHA256SUMS
#   make release-apptainer   the same, with the Apptainer builder (no Docker)
#   make verify              run scripts/verify-sdk.sh on dist/
#
# Don't set DOCKER_BUILDKIT=0. The Dockerfiles fetch the component repos
# with ADD of git sources and read the components as named build contexts,
# which only BuildKit understands.

LOCK        := sdk.lock.yaml
YQ          := yq
COMPONENTS  := toolchain qemu

VERSION     := $(shell $(YQ) -r '.sdk_version' $(LOCK))
REGISTRY    ?= ghcr.io/openchip-software

# docker-bake.hcl tags the SDK image riscv-ime-sdk:openchip-v$(VERSION), a
# local name: the SDK image is never pushed. Set IMAGE to use another tag.
IMAGE       ?= riscv-ime-sdk:openchip-v$(VERSION)

# Base name of the .sif and .tar.xz files, matching the image tag.
DIST        := riscv-ime-sdk-openchip-v$(VERSION)

export REGISTRY
export LOCK_DIGEST := $(shell sha256sum $(LOCK) | cut -d' ' -f1)

BAKE := docker buildx bake -f docker-bake.hcl $(foreach s,$(COMPONENTS) sdk,-f build/$(s)/pins.hcl)
TAG  := $(if $(filter command line,$(origin IMAGE)),--set sdk.tags=$(IMAGE))

.PHONY: all sdk $(COMPONENTS) lock pins check hashes print clean \
        builder release release-apptainer verify
.DEFAULT_GOAL := all

all: $(DIST).sif $(DIST).tar.xz

## Resolve components.yaml -> sdk.lock.yaml, then render build/*/pins.hcl
lock:
	./scripts/make-lock.sh

## Render build/*/pins.hcl from the existing lock
pins:
	./scripts/make-lock.sh --render

## Guard: no secrets, no internal hosts, no pins outside the lock, and
## manifest, lock and pins agree
check:
	./scripts/check-pins.sh
	./scripts/check-lock.sh

## Reuse each component image that GHCR has under the `make hashes` tag;
## build the others from source. CI sets SDK_OUTPUT=type=cacheonly.
SDK_OUTPUT ?= type=docker
sdk:
	flags=$$(./scripts/resolve-components.sh) && \
	$(BAKE) $(TAG) $$flags --set sdk.output=$(SDK_OUTPUT) sdk
	@echo "==> Built $(IMAGE)"

$(COMPONENTS):
	$(BAKE) $@

## Component image tags: the git tree hash of build/<component> at HEAD.
## Uncommitted changes are not included. CI appends HASH_SUFFIX to the
## tags of its from-scratch runs.
HASH_SUFFIX ?=
hashes:
	@for c in $(COMPONENTS); do \
	    t=$$(git rev-parse -q --verify "HEAD:build/$$c") || { echo "build/$$c is not in HEAD" >&2; exit 1; }; \
	    echo "$(REGISTRY)/riscv-ime-sdk-$$c:$$t$(HASH_SUFFIX)"; \
	done

## Show the resolved bake definition
print:
	@$(BAKE) --print $(TAG) sdk

$(DIST).sif: sdk build/sdk/sdk.def
	# --build-arg / %arguments templating needs apptainer >= 1.3.
	apptainer build --build-arg SDK_VERSION=$(VERSION) $@ build/sdk/sdk.def
	@echo "==> Wrote $@"

$(DIST).tar.xz: sdk
	docker save $(IMAGE) | xz -T0 > $@
	@echo "==> Wrote $@"

clean:
	rm -f riscv-ime-sdk-*.sif riscv-ime-sdk-*.tar.xz

## SDK tarball. The builder image and builder.sif are internal build
## environments, not published.

# builder_pin <KEY>: KEY = "value" from build/builder/pins.hcl.
builder_pin = $(shell sed -n 's/^ *$(1) *= *"\(.*\)"$$/\1/p' build/builder/pins.hcl)
BUILDER_ARGS = BASE_IMAGE=$(call builder_pin,BASE_IMAGE) \
               CROSSTOOLS_NG_REPO=$(call builder_pin,CROSSTOOLS_NG_REPO) \
               CROSSTOOLS_NG_COMMIT=$(call builder_pin,CROSSTOOLS_NG_COMMIT)
BUILDER_IMAGE ?= riscv-ime-sdk-builder:local
# The SDK is built at /opt/sdk inside the builder; this is that directory.
SDK_PREFIX_DIR := $(CURDIR)/work/prefix

builder:
	docker build $(addprefix --build-arg ,$(BUILDER_ARGS)) -t $(BUILDER_IMAGE) build/builder

# --build-arg / {{ }} templating needs apptainer >= 1.3.
builder.sif: build/builder/builder.def build/builder/pins.hcl $(wildcard build/builder/*.sh)
	apptainer build --fakeroot --force $(addprefix --build-arg ,$(BUILDER_ARGS)) $@ $<

release: builder
	mkdir -p $(SDK_PREFIX_DIR)
	docker run --rm --user "$$(id -u):$$(id -g)" -e JOBS \
	    -v "$(CURDIR):/src" -v "$(SDK_PREFIX_DIR):/opt/sdk" -w /src \
	    $(BUILDER_IMAGE) scripts/build-sdk.sh

release-apptainer: builder.sif
	mkdir -p $(SDK_PREFIX_DIR)
	apptainer exec --cleanenv --env JOBS=$${JOBS:-} --bind "$(SDK_PREFIX_DIR):/opt/sdk" \
	    --pwd "$(CURDIR)" builder.sif scripts/build-sdk.sh

verify:
	scripts/verify-sdk.sh
