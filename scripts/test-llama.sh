#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Openchip and Software Technologies, S.L.
# SPDX-License-Identifier: Apache-2.0
#
# test-llama.sh — build llama.cpp with the Zvvm (IME) kernels with the SDK
# toolchain, run it on the SDK's qemu-riscv64, and check that the Zvvm
# kernels ran. `make test-llama` and the test-llama CI job run this script.
#
#   SDK_SIF=riscv-ime-sdk-openchip-v<version>.sif scripts/test-llama.sh
#   SDK_IMAGE=riscv-ime-sdk:openchip-v<version>  scripts/test-llama.sh
#
# Every SDK tool runs in the SDK image: with `apptainer exec` when SDK_SIF
# is set, else with `docker run` of SDK_IMAGE. The image has no CMake or
# Ninja, so the script downloads pinned release binaries of both and runs
# them in the image as well. The host needs bash, git, curl, sha256sum,
# tar, and apptainer or docker.
#
# The test fails if any of these checks fails:
#   1. CMake configures the ggml CPU backend for riscv64 with Zvvm.
#   2. llama-completion contains vqmmacc.vv and vfwmmacc.vv instructions.
#   3. For each model and VLEN, llama-completion exits 0, and the Zvvm
#      counters show that the GEMM path of the model's weight type and the
#      flash-attention path ran.
#
# Environment:
#   SDK_SIF       Apptainer image of the SDK
#   SDK_IMAGE     Docker image of the SDK; used when SDK_SIF is not set
#   TEST_DIR      work directory (default: out/test-llama)
#   TEST_CACHE    download cache: models and tools (default: $TEST_DIR/downloads)
#   LLAMA_REF     llama.cpp commit or branch to test (default: LLAMA_COMMIT below)
#   LLAMA_VLENS   VLENs to run, 512 to 4096 (default: "512 2048")
#   JOBS          parallel compile jobs (default: nproc)
#   THREADS       llama.cpp threads (default: nproc, at most 4)

set -euo pipefail

# --- Pins ------------------------------------------------------------------

# llama.cpp with the Zvvm kernels: branch riscv-zvvm. The kernels target the
# components of SDK openchip-v2026.11.06.
LLAMA_REPO=https://gitlab.com/vrull-public/llama.cpp.git
LLAMA_COMMIT=cceb774de1236c3379686652b60131a7e2f44307

CMAKE_VERSION=4.5.1
CMAKE_SHA256=83b71181fb62b4fe8f26067a9321448572e7a43bd04ff6c7f54a24c33698f16d
NINJA_VERSION=1.13.2
NINJA_SHA256=5749cbc4e668273514150a80e387a957f933c6ed3f5f11e03fb30955e2bbead6

# Models: <file> <Hugging Face repo> <revision> <sha256> <counter that must be > 0>
# LFM2 has attention layers, so both models also exercise flash attention.
MODELS=(
    "LFM2-350M-Q4_0.gguf LiquidAI/LFM2-350M-GGUF 8fdc9d526b7ed346b19257551b05816c7912ecc2 8e3ebc1c608dc8683adf8c3b3e6a40e2f4eab22aa33b908bff2ac03a1c16d796 zvvm_mul_mat_q"
    "LFM2-350M-F16.gguf LiquidAI/LFM2-350M-GGUF 8fdc9d526b7ed346b19257551b05816c7912ecc2 379ffdcbf08147c0313f6f1ce7ff558a2bc935eda633f4b46c52347032419c42 zvvm_mul_mat_f16"
)

# The QEMU CPU of the llama.cpp Zvvm README.
QCPU="rv64,v=true,x-zvvm=true,x-zvvmm=true,x-zvvmmbw=true,x-zvvmtls=true,x-zvvfmm=true,x-zvvfmmf=true,x-zvvfmmh=true,x-zvvfmmhf=true,x-zvvfmmmx=true,x-zvfofp8min=true,zfhmin=true,zvfhmin=true,zfh=true,zvfh=true"

# A Zvvm GEMM runs only when the prompt has at least M tile tokens: 32 at
# VLEN 4096. This prompt has more than 32 tokens.
PROMPT="The RISC-V vector extension lets one instruction process many data elements at once. Matrix extensions go further: a single instruction multiplies two small matrices held in vector registers and adds the result to an accumulator tile. Explain in two sentences why this helps large language models during prompt processing:"

# --- Setup -----------------------------------------------------------------

LLAMA_REF=${LLAMA_REF:-$LLAMA_COMMIT}
LLAMA_VLENS=${LLAMA_VLENS:-512 2048}
JOBS=${JOBS:-$(nproc)}
THREADS=${THREADS:-$(( $(nproc) < 4 ? $(nproc) : 4 ))}

fail=0
bad() {
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        printf '::error::%s\n' "$*"
    else
        printf 'FAIL: %s\n' "$*"
    fi
    fail=1
}
die() { bad "$*"; exit 1; }

for t in git curl sha256sum tar; do
    command -v "$t" >/dev/null || die "$t not found in PATH"
done

if [[ -n "${SDK_SIF:-}" ]]; then
    [[ -f "$SDK_SIF" ]] || die "SDK_SIF=$SDK_SIF: no such file"
    command -v apptainer >/dev/null || die "SDK_SIF is set, but apptainer is not in PATH"
    echo "SDK: $SDK_SIF (apptainer)"
elif [[ -n "${SDK_IMAGE:-}" ]]; then
    command -v docker >/dev/null || die "SDK_IMAGE is set, but docker is not in PATH"
    docker image inspect "$SDK_IMAGE" >/dev/null 2>&1 || die "SDK_IMAGE=$SDK_IMAGE: no such local image"
    echo "SDK: $SDK_IMAGE (docker)"
else
    die "set SDK_SIF to the SDK Apptainer image or SDK_IMAGE to the SDK Docker image"
fi

mkdir -p "${TEST_DIR:=out/test-llama}"
TEST_DIR=$(cd "$TEST_DIR" && pwd -P)
mkdir -p "${TEST_CACHE:=$TEST_DIR/downloads}"
TEST_CACHE=$(cd "$TEST_CACHE" && pwd -P)
SRC=$TEST_DIR/llama.cpp
BUILD=$TEST_DIR/build
TOOLS=$TEST_DIR/tools
LOGS=$TEST_DIR/logs
rm -rf "$LOGS"
mkdir -p "$TOOLS" "$LOGS"

# sdk <cmd> [args...]: run a command in the SDK image, in TEST_DIR, with
# TEST_DIR and TEST_CACHE mounted at their host paths.
sdk() {
    if [[ -n "${SDK_SIF:-}" ]]; then
        apptainer exec --bind "$TEST_DIR" --bind "$TEST_CACHE" --pwd "$TEST_DIR" \
            "$SDK_SIF" "$@"
    else
        docker run --rm -u "$(id -u):$(id -g)" -e HOME="$TEST_DIR" \
            -v "$TEST_DIR:$TEST_DIR" -v "$TEST_CACHE:$TEST_CACHE" -w "$TEST_DIR" \
            "$SDK_IMAGE" "$@"
    fi
}

# fetch <url> <sha256> <file in TEST_CACHE>: download once, verify always.
fetch() {
    local url=$1 sum=$2 out=$TEST_CACHE/$3
    if [[ ! -f "$out" ]] || ! echo "$sum  $out" | sha256sum -c --status; then
        echo "==> download $url"
        curl -fL --retry 3 --progress-bar -o "$out.part" "$url"
        echo "$sum  $out.part" | sha256sum -c --status \
            || die "$3: sha256 is not $sum"
        mv "$out.part" "$out"
    fi
}

# --- Tools -----------------------------------------------------------------

cmake_dir=cmake-$CMAKE_VERSION-linux-x86_64
fetch "https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION/$cmake_dir.tar.gz" \
      "$CMAKE_SHA256" "$cmake_dir.tar.gz"
fetch "https://github.com/ninja-build/ninja/releases/download/v$NINJA_VERSION/ninja-linux.zip" \
      "$NINJA_SHA256" "ninja-$NINJA_VERSION-linux.zip"
CMAKE=$TOOLS/$cmake_dir/bin/cmake
NINJA=$TOOLS/ninja-$NINJA_VERSION/ninja
if [[ ! -x "$CMAKE" ]]; then
    tar -xzf "$TEST_CACHE/$cmake_dir.tar.gz" -C "$TOOLS"
fi
if [[ ! -x "$NINJA" ]]; then
    mkdir -p "$(dirname "$NINJA")"
    # The CMake release is an x86-64 Linux binary and also runs on the host.
    (cd "$(dirname "$NINJA")" && "$CMAKE" -E tar xf "$TEST_CACHE/ninja-$NINJA_VERSION-linux.zip")
fi

# --- Source ----------------------------------------------------------------

echo "==> llama.cpp $LLAMA_REF"
[[ -d "$SRC/.git" ]] || git init -q "$SRC"
git -C "$SRC" fetch -q --depth 1 "$LLAMA_REPO" "$LLAMA_REF"
git -C "$SRC" -c advice.detachedHead=false checkout -q --force FETCH_HEAD
git -C "$SRC" log -1 --format='    %H %s'

# --- Build -----------------------------------------------------------------

echo "==> configure"
# Configure from scratch, so that no cached result of an earlier run is used.
rm -f "$BUILD/CMakeCache.txt"
# The link is static, but FindOpenMP picks libgomp.so, and the static link
# of llama-completion then fails. Name the static libgomp.a instead.
libgomp=$(sdk riscv64-openchip-linux-gnu-gcc -print-file-name=libgomp.a)
sdk "$CMAKE" -S "$SRC" -B "$BUILD" -G Ninja -DCMAKE_MAKE_PROGRAM="$NINJA" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=riscv64 \
    -DCMAKE_C_COMPILER=riscv64-openchip-linux-gnu-gcc \
    -DCMAKE_CXX_COMPILER=riscv64-openchip-linux-gnu-g++ \
    -DCMAKE_EXE_LINKER_FLAGS=-static -DBUILD_SHARED_LIBS=OFF \
    -DOpenMP_gomp_LIBRARY="$libgomp" \
    -DGGML_NATIVE=OFF -DGGML_CPU_RISCV64_ZVVM=ON -DLLAMA_OPENSSL=OFF \
    > "$LOGS/configure.log" 2>&1 || { tail -n 40 "$LOGS/configure.log"; die "configure failed"; }
# Without CMAKE_SYSTEM_PROCESSOR=riscv64 the build succeeds without Zvvm code.
grep -q 'riscv64 detected' "$LOGS/configure.log" \
    || bad "configure did not print 'riscv64 detected': the build has no Zvvm code"

echo "==> build llama-completion ($JOBS jobs)"
sdk "$CMAKE" --build "$BUILD" --target llama-completion -j "$JOBS" \
    > "$LOGS/build.log" 2>&1 || { tail -n 40 "$LOGS/build.log"; die "build failed"; }
LC=$BUILD/bin/llama-completion

echo "==> IME instructions in llama-completion"
sdk riscv64-openchip-linux-gnu-objdump -d --no-show-raw-insn "$LC" > "$LOGS/llama-completion.dis"
for insn in vqmmacc.vv vfwmmacc.vv; do
    n=$(grep -c "[[:space:]]$insn[[:space:]]" "$LOGS/llama-completion.dis" || true)
    printf '    %-12s %s\n' "$insn" "$n"
    [[ "$n" -gt 0 ]] || bad "llama-completion has no $insn instruction"
done
rm -f "$LOGS/llama-completion.dis"

# --- Run -------------------------------------------------------------------

for m in "${MODELS[@]}"; do
    read -r file repo rev sum counter <<< "$m"
    fetch "https://huggingface.co/$repo/resolve/$rev/$file" "$sum" "$file"
    for vlen in $LLAMA_VLENS; do
        name=${file%.gguf}-vlen$vlen
        log=$LOGS/$name.log
        counters=$LOGS/$name.counters
        echo "==> run $file at VLEN $vlen"
        # ZVVM_COUNTER_EVERY=1 writes the counters after every tile, so the
        # file holds the final counts when the program exits.
        if ! sdk env ZVVM_COUNTER_LOG="$counters" ZVVM_COUNTER_EVERY=1 \
                qemu-riscv64 -cpu "$QCPU,vlen=$vlen" "$LC" \
                -m "$TEST_CACHE/$file" -no-cnv -p "$PROMPT" \
                -c 512 -t "$THREADS" -fa on --temp 0 -n 16 \
                > "$log" 2>&1 < /dev/null; then
            tail -n 20 "$log"
            bad "$name: llama-completion failed; see $log"
            continue
        fi
        if grep -q 'no kernel leaf' "$log"; then
            bad "$name: no Zvvm kernel for VLEN $vlen"
        fi
        if [[ ! -s "$counters" ]]; then
            bad "$name: no Zvvm counters were written: no Zvvm kernel ran"
            continue
        fi
        sed 's/^/    /' "$counters"
        for c in "$counter" zvvm_flash_attn; do
            v=$(sed -n "s/^$c=//p" "$counters")
            [[ "${v:-0}" -gt 0 ]] || bad "$name: $c is ${v:-missing}, expected > 0"
        done
    done
done

if [[ "$fail" -ne 0 ]]; then
    echo "test-llama: FAILED; logs in $LOGS"
    exit 1
fi
echo "test-llama: passed; logs in $LOGS"
