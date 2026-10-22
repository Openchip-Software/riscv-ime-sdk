# SPDX-FileCopyrightText: 2026 Openchip and Software Technologies, S.L.
# SPDX-License-Identifier: Apache-2.0
#
# env.sh — set up a shell for the IME SDK. Source it, do not run it:
#
#   . <sdk>/share/sdk/env.sh
#
# Every path is computed from this file's location, so the SDK works from
# wherever it was extracted. bash and zsh find this file by themselves.
# Other shells must set SDK_ROOT to the SDK directory before sourcing.
#
# Sets SDK_ROOT, SDK_SYSROOT and PATH. Also sets the variables of the
# previous SDK container images: RISCV_SYSROOT, QEMU_LD_PREFIX (so that
# qemu-riscv64 finds the target's dynamic loader and libraries), and
# QEMU_CPU (the CPU model with the IME extension) unless already set.

if [ -n "${BASH_SOURCE:-}" ]; then
    _sdk_env_file=${BASH_SOURCE[0]}
elif [ -n "${ZSH_VERSION:-}" ]; then
    eval '_sdk_env_file=${(%):-%x}'
else
    _sdk_env_file=
fi

if [ -n "$_sdk_env_file" ]; then
    SDK_ROOT=$(cd "$(dirname "$_sdk_env_file")/../.." && pwd)
elif [ -z "${SDK_ROOT:-}" ]; then
    echo "env.sh: this shell cannot locate env.sh; set SDK_ROOT first" >&2
    unset _sdk_env_file
    return 1
fi
unset _sdk_env_file

SDK_SYSROOT=$SDK_ROOT/riscv64-openchip-linux-gnu/sysroot
RISCV_SYSROOT=$SDK_SYSROOT
QEMU_LD_PREFIX=$SDK_SYSROOT
QEMU_CPU=${QEMU_CPU:-max,x-zvvm=true,vlen=2048}
case ":$PATH:" in
    *":$SDK_ROOT/bin:"*) ;;
    *) PATH=$SDK_ROOT/bin:$PATH ;;
esac
export SDK_ROOT SDK_SYSROOT RISCV_SYSROOT QEMU_LD_PREFIX QEMU_CPU PATH
