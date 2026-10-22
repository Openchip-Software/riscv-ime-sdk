#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Openchip and Software Technologies, S.L.
# SPDX-License-Identifier: Apache-2.0
#
# audit-linkage.sh — list the shared libraries and the glibc symbol version
# floor of every host ELF file under an SDK prefix.
#
#   audit-linkage.sh <sdk-prefix>
#
# Target ELF files (the riscv64 sysroot, target libraries) are skipped:
# only files built for the machine running this script are audited.
# Prints one "== <path>" block per file with its ldd output, then the
# highest GLIBC_x.y symbol version any of them requires.

set -euo pipefail

prefix="${1:?usage: audit-linkage.sh <sdk-prefix>}"
prefix="${prefix%/}"

# `file` names x86_64 as "x86-64" and aarch64 as "ARM aarch64".
host_arch=$(uname -m | sed 's/_/-/')

host_elfs() {
    find "$prefix" -type f \( -perm -u+x -o -name '*.so' -o -name '*.so.*' \) -print0 |
    while IFS= read -r -d '' f; do
        desc=$(file -b "$f")
        [[ "$desc" == ELF* ]] || continue
        [[ "$desc" == *"$host_arch"* ]] || continue
        printf '%s\n' "$f"
    done
}

mapfile -t elfs < <(host_elfs | sort)

for f in "${elfs[@]}"; do
    echo "== ${f#"$prefix"/}"
    ldd "$f" 2>&1 | sed 's/^/   /' || true
done

echo "== glibc floor:"
for f in "${elfs[@]}"; do
    objdump -T "$f" 2>/dev/null || true
done | grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' | sort -Vu | tail -n 1
