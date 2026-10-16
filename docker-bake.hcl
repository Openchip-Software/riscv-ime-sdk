# docker-bake.hcl — the IME SDK build graph.
#
#   toolchain   build/toolchain   crosstool-NG toolchain, hours
#   qemu        build/qemu        QEMU, minutes
#   sdk         build/sdk         final image; takes toolchain and qemu as
#                                 named contexts
#
# The build args of each target come from build/<target>/pins.hcl, which
# `make lock` renders from sdk.lock.yaml. Bake reads only docker-bake.hcl
# by default, so pass the pin files as well:
#
#   docker buildx bake -f docker-bake.hcl \
#     -f build/toolchain/pins.hcl -f build/qemu/pins.hcl -f build/sdk/pins.hcl sdk
#
# `make sdk` does this. With no overrides, `sdk` builds both components
# from source. To use prebuilt component images instead, override the
# contexts:
#
#   --set sdk.contexts.toolchain=docker-image://<registry>/riscv-ime-sdk-toolchain@sha256:...

variable "REGISTRY" {
  default = "ghcr.io/openchip-software"
}

# sha256 of sdk.lock.yaml, recorded as a label of the SDK image.
variable "LOCK_DIGEST" {
  default = ""
}

group "default" {
  targets = ["sdk"]
}

target "_component" {
  labels = {
    "org.opencontainers.image.source" = "https://github.com/Openchip-Software/riscv-ime-sdk"
  }
}

target "toolchain" {
  inherits = ["_component", "toolchain-pins"]
  context  = "build/toolchain"
  target   = "toolchain"
  labels = {
    "org.opencontainers.image.description" = "IME SDK component: riscv64 cross toolchain"
  }
}

target "qemu" {
  inherits = ["_component", "qemu-pins"]
  context  = "build/qemu"
  target   = "qemu"
  labels = {
    "org.opencontainers.image.description" = "IME SDK component: QEMU with the IME model"
  }
}

# The tag of a local build: the name a release of this sdk_version gets in
# GHCR, and the one build/sdk/sdk.def expects. CI sets its own tag with
# --set sdk.tags.
target "sdk-tag" {
  tags = ["${REGISTRY}/riscv-ime-sdk:openchip-v${SDK_VERSION}"]
}

target "sdk" {
  inherits = ["sdk-pins", "sdk-tag"]
  context  = "build/sdk"
  target   = "sdk"
  contexts = {
    toolchain = "target:toolchain"
    qemu      = "target:qemu"
  }
  args = {
    LOCK_DIGEST = LOCK_DIGEST
  }
  labels = {
    "org.opencontainers.image.source"      = "https://github.com/Openchip-Software/riscv-ime-sdk"
    "org.opencontainers.image.description" = "IME SDK: riscv64 cross toolchain, sysroot and QEMU"
  }
}
