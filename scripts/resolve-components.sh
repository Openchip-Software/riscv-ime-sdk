#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Openchip and Software Technologies, S.L.
# SPDX-License-Identifier: Apache-2.0
#
# resolve-components.sh — choose, for each component, between its GHCR image
# and a build from source. `make sdk` passes the output to docker buildx bake.
#
# The image references come from `make hashes`. For each component image
# that exists, stdout gets
#
#   --set sdk.contexts.<component>=docker-image://<image>@sha256:...
#
# pinned by digest. A component without an image gets no flag, and bake
# builds it from source. One notice per component goes to stderr, plus a
# warning for a component with uncommitted changes, which the hash ignores.
# In GitHub Actions, each pinned reference is also written to $GITHUB_OUTPUT as
# <component>=<reference>.

set -euo pipefail

refs=$(make -s --no-print-directory hashes)
for ref in $refs; do
    c=${ref##*/riscv-ime-sdk-}
    c=${c%%:*}
    t=${ref##*:}; t=${t:0:7}
    git diff --quiet HEAD -- "build/$c" ||
        printf '%-10s %s  ⚠ uncommitted changes in build/%s are ignored (hash is taken from HEAD)\n' "$c" "$t" "$c" >&2
    if digest=$(docker buildx imagetools inspect "$ref" --format '{{.Manifest.Digest}}' 2>&1); then
        pinned="${ref%:*}@$digest"
        printf '%-10s %s  ✓ prebuilt image found, reusing %s\n' "$c" "$t" "$pinned" >&2
        echo "--set sdk.contexts.$c=docker-image://$pinned"
        if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "$c=$pinned" >> "$GITHUB_OUTPUT"; fi
    elif grep -qiE 'not found|manifest unknown|name unknown|unauthorized|denied' <<< "$digest"; then
        # GHCR answers "denied" for a private image without credentials.
        printf '%-10s %s  ⚠ no prebuilt image (%s not found or not readable) — building from source (this can take hours)\n' "$c" "$t" "$ref" >&2
    else
        # A registry or network error: a build of several hours would not help.
        echo "$digest" >&2
        exit 1
    fi
done
