#!/usr/bin/env bash
# vm/scripts/launch_vz.sh
# Automated launcher for Niri MicroVM using Apple Virtualization.framework

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BIN_PATH="${REPO_ROOT}/target/microvm_launcher"

# Compile launcher if needed
if [[ ! -f "${BIN_PATH}" || "${REPO_ROOT}/vm/host/microvm_launcher.swift" -nt "${BIN_PATH}" ]]; then
    echo "[BUILD] Compiling Apple Virtualization launcher..."
    mkdir -p "${REPO_ROOT}/target"
    swiftc -O "${REPO_ROOT}/vm/host/microvm_launcher.swift" -o "${BIN_PATH}"
fi

# Ensure shared SHM directory exists
mkdir -p /tmp/niri-shm

echo "[RUN] Launching MicroVM via Virtualization.framework..."
exec "${BIN_PATH}" "$@"
