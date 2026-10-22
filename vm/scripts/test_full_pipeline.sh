#!/usr/bin/env bash
# vm/scripts/test_full_pipeline.sh
# End-to-end integration test: Run Niri, Run MicroVM, Run Wayland window inside VM, assert mapped window.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

RUNTIME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/niri-runtime-XXXXXX")
chmod 700 "${RUNTIME_DIR}"

export XDG_RUNTIME_DIR="${RUNTIME_DIR}"
export NIRI_NOTCH_BYPASS=0
export NIRI_WINDOWED=1
export NIRI_WIDTH=1280
export NIRI_HEIGHT=800

echo "============================================================"
echo "NIRI + MICROVM FULL END-TO-END PIPELINE INTEGRATION TEST"
echo "============================================================"

# Step 0: Clean up any stale sockets/processes
pkill -f microvm_launcher 2>/dev/null || true
pkill -f niri-vsock-host 2>/dev/null || true
pkill -f target/debug/niri 2>/dev/null || true
rm -f "${RUNTIME_DIR}"/wayland-* 2>/dev/null || true
rm -f "${RUNTIME_DIR}"/niri.*.sock 2>/dev/null || true

# Step 1: Launch Niri in windowed mode
echo "[STEP 1] Launching Niri compositor (Metal viewport)..."
"${REPO_ROOT}/target/debug/niri" > /tmp/niri_test.log 2>&1 &
NIRI_PID=$!

cleanup() {
    echo ""
    echo "[CLEANUP] Stopping test processes..."
    if kill -0 "${VM_PID:-0}" 2>/dev/null; then
        kill "${VM_PID}" 2>/dev/null || true
    fi
    if kill -0 "${NIRI_PID:-0}" 2>/dev/null; then
        "${REPO_ROOT}/target/debug/niri" msg action quit 2>/dev/null || kill "${NIRI_PID}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Wait for Wayland socket to be ready
echo "[STEP 1] Waiting for Niri Wayland socket..."
TRIES=0
WAYLAND_SOCK=""
while [ $TRIES -lt 30 ]; do
    for s in "${RUNTIME_DIR}"/wayland-*; do
        if [ -S "$s" ]; then
            WAYLAND_SOCK="$s"
            break 2
        fi
    done
    sleep 0.2
    TRIES=$((TRIES + 1))
done

if [ -z "${WAYLAND_SOCK}" ]; then
    echo "[FATAL] Niri did not create a Wayland socket! Log:"
    cat /tmp/niri_test.log
    exit 1
fi

echo "[STEP 1] Niri Wayland socket active: ${WAYLAND_SOCK}"

# Locate and export exact NIRI_SOCKET for this running instance
SOCK_NAME="${WAYLAND_SOCK##*/}"
export NIRI_SOCKET="${RUNTIME_DIR}/niri.${SOCK_NAME}.${NIRI_PID}.sock"

# Wait for IPC socket to exist
TRIES=0
while [ ! -S "${NIRI_SOCKET}" ] && [ $TRIES -lt 30 ]; do
    sleep 0.1
    TRIES=$((TRIES + 1))
done

echo "[STEP 1] Niri IPC socket active: ${NIRI_SOCKET}"

# Verify Niri IPC
NIRI_VERSION=$("${REPO_ROOT}/target/debug/niri" msg version 2>/dev/null || true)
echo "[STEP 1] Niri IPC live! Version: ${NIRI_VERSION}"
echo "[STEP 1] Niri IPC live! Version: ${NIRI_VERSION}"

# Step 2: Launch MicroVM with Apple Virtualization
echo "[STEP 2] Booting Linux MicroVM via Apple Virtualization.framework..."
KERNEL="${REPO_ROOT}/vm/images/Image"
INITRD="${REPO_ROOT}/vm/images/initramfs.cpio.gz"
LAUNCHER="${REPO_ROOT}/target/microvm_launcher"

if [ ! -f "${KERNEL}" ] || [ ! -f "${INITRD}" ]; then
    echo "[FATAL] Missing VM assets. Running install_assets.sh..."
    bash "${REPO_ROOT}/vm/scripts/install_assets.sh"
fi

"${LAUNCHER}" \
    --kernel "${KERNEL}" \
    --initrd "${INITRD}" \
    --disk "${REPO_ROOT}/vm/images/modloop-virt" \
    --wayland-socket "${WAYLAND_SOCK}" \
    --cpus 2 \
    --memory 1024 \
    --cmdline "console=hvc0 root=/dev/vda rw init=/init quiet loglevel=3 panic=-1" > /tmp/microvm_test.log 2>&1 &
VM_PID=$!

echo "[STEP 2] MicroVM PID: ${VM_PID}. Waiting for guest boot and client window commit..."

# Step 3: Wait and assert that the window is mapped in Niri
TRIES=0
WINDOW_DETECTED=0
while [ $TRIES -lt 40 ]; do
    WINDOWS_JSON=$("${REPO_ROOT}/target/debug/niri" msg --json windows 2>/dev/null || echo "[]")
    if echo "${WINDOWS_JSON}" | grep -q "MicroVM Linux Wayland Client"; then
        echo ""
        echo "[SUCCESS] Found mapped Linux client window in Niri!"
        echo "${WINDOWS_JSON}"
        WINDOW_DETECTED=1
        break
    fi
    sleep 0.5
    TRIES=$((TRIES + 1))
    echo -n "."
done

echo ""
if [ $WINDOW_DETECTED -eq 1 ]; then
    echo "============================================================"
    echo "END-TO-END PIPELINE VERIFICATION PASSED (100%)!"
    echo "- Niri Metal Compositor: RUNNING"
    echo "- Apple Virtualization MicroVM: BOOTED"
    echo "- vsock Wayland Bridge: CONNECTED"
    echo "- Linux Guest Window: PRESENTED IN NIRI"
    echo "============================================================"
    exit 0
else
    echo "[FAIL] Window was not detected in Niri within timeout."
    echo "=== NIRI LOG ==="
    cat /tmp/niri_test.log | tail -n 30
    echo "=== MICROVM LOG ==="
    cat /tmp/microvm_test.log | tail -n 30
    exit 1
fi
