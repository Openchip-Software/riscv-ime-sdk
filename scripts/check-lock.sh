#!/usr/bin/env bash
# check-lock.sh — components.yaml, sdk.lock.yaml and build/*/pins.hcl agree.
#
# `make lock` writes the lock from the manifest and renders the pins from
# the lock. This script fails when any of the three was edited without
# running it. Run in CI on every PR, and by `make check`.

set -uo pipefail

MANIFEST="${MANIFEST:-components.yaml}"
LOCK="${LOCK:-sdk.lock.yaml}"

command -v yq >/dev/null || { echo "check-lock: yq required" >&2; exit 1; }

fail=0
bad() {
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        printf '::error::%s\n' "$*"
    else
        printf 'FAIL: %s\n' "$*"
    fi
    fail=1
}

# same <what> <manifest value> <lock value>
same() {
    [[ "$2" == "$3" ]] || bad "$1: manifest '$2' != lock '$3' — run 'make lock'"
}

echo "==> manifest and lock agree"
version=$(yq -r '.sdk_version' "$MANIFEST")
same sdk_version "$version" "$(yq -r '.sdk_version' "$LOCK")"
# A release is tagged openchip-v<sdk_version>, and the sdk workflow accepts
# only openchip-vYYYY.MM.DD.
[[ "$version" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}$ ]] \
    || bad "sdk_version '$version' is not YYYY.MM.DD"
for c in $(yq -r '.components | keys | .[]' "$MANIFEST"); do
    same "$c ref"  "$(yq -r ".components.\"$c\".ref"  "$MANIFEST")" \
                   "$(yq -r ".components.\"$c\".resolved_from" "$LOCK")"
    same "$c repo" "$(yq -r ".components.\"$c\".repo" "$MANIFEST")" \
                   "$(yq -r ".components.\"$c\".repo" "$LOCK")"
done
same base_image "$(yq -r '.base_image' "$MANIFEST")" \
                "$(yq -r '.base_image.resolved_from' "$LOCK")"

# The component image tags are git tree hashes of build/<stage>, so the pins
# must be in those directories. Render them from the lock and compare with
# the files on disk, then put the files back.
echo "==> build/*/pins.hcl match the lock"
saved=$(mktemp -d)
trap 'rm -rf "$saved"' EXIT
for f in build/*/pins.hcl; do
    mkdir -p "$saved/$(dirname "$f")"
    cp "$f" "$saved/$f"
done
./scripts/make-lock.sh --render 2>/dev/null
for f in build/*/pins.hcl; do
    if ! diff -u "$saved/$f" "$f"; then
        bad "$f differs from $LOCK — run 'make pins'"
    fi
    cp "$saved/$f" "$f"
done

[[ "$fail" == 0 ]] && echo "  clean"
exit "$fail"
