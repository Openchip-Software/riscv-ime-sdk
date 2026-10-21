# SPDX-FileCopyrightText: 2026 Openchip and Software Technologies, S.L.
# SPDX-License-Identifier: Apache-2.0

# IME SDK — build entry point. The build graph is docker-bake.hcl; this
# file passes it the pins rendered from sdk.lock.yaml.
#
#   make lock                resolve components.yaml -> sdk.lock.yaml + build/*/pins.hcl
#   make sdk                 build the SDK image from source
#   make toolchain | qemu    build one component from source
#   make hashes              print the component image tags CI looks for
#
# CI reuses component images from GHCR; `make sdk` always builds from source.
#
# Don't set DOCKER_BUILDKIT=0. The Dockerfiles fetch the component repos
# with ADD of git sources and read the components as named build contexts,
# which only BuildKit understands.

LOCK        := sdk.lock.yaml
YQ          := yq
COMPONENTS  := toolchain qemu

VERSION     := $(shell $(YQ) -r '.sdk_version' $(LOCK))
REGISTRY    ?= ghcr.io/openchip-software

# docker-bake.hcl tags the SDK image $(REGISTRY)/riscv-ime-sdk:openchip-v$(VERSION).
# Set IMAGE to use another tag.
IMAGE       ?= $(REGISTRY)/riscv-ime-sdk:openchip-v$(VERSION)

# Base name of the .sif and .tar.xz files, matching the image tag.
DIST        := riscv-ime-sdk-openchip-v$(VERSION)

export REGISTRY
export LOCK_DIGEST := $(shell sha256sum $(LOCK) | cut -d' ' -f1)

BAKE := docker buildx bake -f docker-bake.hcl $(foreach s,$(COMPONENTS) sdk,-f build/$(s)/pins.hcl)
TAG  := $(if $(filter command line,$(origin IMAGE)),--set sdk.tags=$(IMAGE))

.PHONY: all sdk $(COMPONENTS) lock pins check hashes print clean
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

sdk:
	$(BAKE) $(TAG) --set sdk.output=type=docker sdk

$(COMPONENTS):
	$(BAKE) $@

## Component image tags: the git tree hash of build/<component> at HEAD.
## Uncommitted changes are not included.
hashes:
	@for c in $(COMPONENTS); do \
	    t=$$(git rev-parse -q --verify "HEAD:build/$$c") || { echo "build/$$c is not in HEAD" >&2; exit 1; }; \
	    echo "$(REGISTRY)/riscv-ime-sdk-$$c:$$t"; \
	done

## Show the resolved bake definition
print:
	@$(BAKE) --print $(TAG) sdk

$(DIST).sif: sdk build/sdk/sdk.def
	# --build-arg / %arguments templating needs apptainer >= 1.3.
	apptainer build --build-arg SDK_VERSION=$(VERSION) $@ build/sdk/sdk.def

$(DIST).tar.xz: sdk
	docker save $(IMAGE) | xz -T0 > $@

clean:
	rm -f riscv-ime-sdk-*.sif riscv-ime-sdk-*.tar.xz
