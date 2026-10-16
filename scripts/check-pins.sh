#!/usr/bin/env bash
# check-pins.sh — the mechanical enforcement behind "one home for every pin".
#
# Without this, refs drift back out of the lock and into Dockerfiles, CI
# YAML and defconfigs within a few months, and the design quietly decays.
# Run in CI on every PR.

set -uo pipefail

fail=0
note() { printf '  %s\n' "$*"; }
bad()  { printf 'FAIL: %s\n' "$*"; fail=1; }

# Files permitted to name a component repo. build/*/pins.hcl are rendered
# from the lock by `make lock`, and guard.yml fails when they differ from
# it. Everything else must receive repo URLs as build args from the pins.
PIN_ALLOWLIST='^(components\.yaml|sdk\.lock\.yaml|build/[^/]+/pins\.hcl|README\.md|scripts/check-pins\.sh|\.github/)'

# Prose may legitimately discuss internal hosts and dead flags. These
# checks are about the *build path*, so the README and this script are
# excluded from them. The credential and internal-hostname checks
# below are deliberately NOT excluded — those must never appear anywhere.
PROSE=(':(exclude)README.md' ':(exclude)scripts/check-pins.sh')

files=$(git ls-files)

echo "==> no credentials"
# Pattern requires >=20 chars after the prefix so this script never matches
# itself. Covers GitLab PATs, deploy tokens and GitHub PATs.
if git grep -nIE '(glpat|gldt)-[A-Za-z0-9_.-]{20,}|gh[pousr]_[A-Za-z0-9]{30,}' -- . ; then
    bad "credential-shaped string in tracked files"
else
    note "clean"
fi

echo "==> no internal hostnames"
if git grep -nIE '(gitlab|harbor[a-z.]*)\.(devtools\.)?openchip\.local' -- . ; then
    bad "internal hostname in tracked files"
else
    note "clean"
fi

echo "==> no private gitlab.com/vrull refs"
if git grep -nI 'gitlab\.com/vrull' -- . "${PROSE[@]}" ; then
    bad "private VRULL GitLab reference in the build path"
else
    note "clean"
fi

echo "==> component refs live only in the lock"
# ime-sdk is this repo — its own OCI source label and def-file URL are not
# component pins. Only the four component repos must live in the lock.
hits=$(git grep -nIiE 'github\.com/Openchip-Software/riscv-ime-(crosstool-NG|gcc|binutils|qemu)' -- . \
       | grep -vE "$PIN_ALLOWLIST" || true)
if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits"
    bad "component repo named outside the lock/manifest"
else
    note "clean"
fi

echo "==> BuildKit not disabled"
# The component Dockerfiles fetch sources with ADD of a git URL, and
# build/sdk reads toolchain and qemu as named build contexts. Both need
# BuildKit.
# `^[^#]*` so a comment explaining the flag's absence does not trip it.
if git grep -nIE '^[^#]*DOCKER_BUILDKIT=0' -- . "${PROSE[@]}" ; then
    bad "DOCKER_BUILDKIT=0 breaks ADD of git sources and the named build contexts"
else
    note "clean"
fi

echo "==> lock is resolved"
if grep -n 'PLACEHOLDER' sdk.lock.yaml 2>/dev/null; then
    bad "sdk.lock.yaml contains PLACEHOLDER values"
else
    note "clean"
fi

exit "$fail"
