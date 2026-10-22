#!/usr/bin/env bash
# vm/scripts/launch_qemu.sh
# Fallback runner for Niri MicroVM using QEMU with Hypervisor.framework (HVF)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

KERNEL="${1:-${REPO_ROOT}/vm/images/vmlinuz}"
INITRD="${2:-${REPO_ROOT}/vm/images/initramfs.cpio.gz}"
SHARED_DIR="${3:-/tmp/niri-shm}"

mkdir -p "${SHARED_DIR}"

if ! command -v qemu-system-aarch64 >/dev/null 2>&1; then
    echo "[WARN] qemu-system-aarch64 is not installed."
    echo "Install via: brew install qemu"
    echo "Using Apple Virtualization runner instead..."
    exec "${SCRIPT_DIR}/launch_vz.sh" --kernel "${KERNEL}" --initrd "${INITRD}" --shared-dir "${SHARED_DIR}"
fi

echo "[RUN] Launching MicroVM via QEMU HVF..."
exec qemu-system-aarch64 \
    -M virt,highmem=on \
    -accel hvf \
    -cpu host \
    -smp 4 \
    -m 2048 \
    -kernel "${KERNEL}" \
    -initrd "${INITRD}" \
    -append "console=ttyAMA0 root=/dev/vda rw init=/init quiet" \
    -device virtio-gpu-pci \
    -virtfs local,path="${SHARED_DIR}",mount_tag=host_share,security_model=none,id=virtfs0 \
    -chardev socket,id=vsock_chardev,path=/tmp/niri-vsock-1024.sock,server=on,wait=off \
    -nographic
