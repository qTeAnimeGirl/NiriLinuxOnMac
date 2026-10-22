#!/usr/bin/env bash
# vm/scripts/launch_libkrun.sh
# Runner for Niri MicroVM leveraging libkrun with Venus Vulkan over MoltenVK

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

KERNEL="${1:-${REPO_ROOT}/vm/images/vmlinuz}"
INITRD="${2:-${REPO_ROOT}/vm/images/initramfs.cpio.gz}"
SHARED_DIR="${3:-/tmp/niri-shm}"
VSOCK_PORT="1024"

mkdir -p "${SHARED_DIR}"

# Check for krunvm / libkrun
if ! command -v krunvm >/dev/null 2>&1 && ! command -v krun >/dev/null 2>&1; then
    echo "============================================================"
    echo "[INFO] libkrun / krunvm not found in system PATH."
    echo "To install libkrun with native Venus Vulkan 3D acceleration on macOS:"
    echo "  brew tap slp/krun"
    echo "  brew install krunvm libkrun"
    echo "============================================================"
    echo "Falling back to Apple Virtualization runner: launch_vz.sh"
    exec "${SCRIPT_DIR}/launch_vz.sh" --kernel "${KERNEL}" --initrd "${INITRD}" --shared-dir "${SHARED_DIR}"
fi

echo "[RUN] Launching MicroVM with libkrun (Venus Vulkan 3D Enabled)..."
# Set environment for virglrenderer Venus on MoltenVK
export VIRGL_DEBUG=venus
export VK_ICD_FILENAMES=/opt/homebrew/share/vulkan/icd.d/MoltenVK_icd.json

if command -v krunvm >/dev/null 2>&1; then
    exec krunvm run --cpus 4 --mem 2048 --vsock "${VSOCK_PORT}" --workdir "${SHARED_DIR}" "${KERNEL}"
fi
