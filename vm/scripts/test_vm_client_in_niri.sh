#!/usr/bin/env bash
# vm/scripts/test_vm_client_in_niri.sh
# End-to-end live test: Runs Niri on macOS, launches the Linux MicroVM,
# executes a Wayland client inside the VM, and verifies the window in Niri.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "============================================================"
echo "Niri MicroVM Live In-Compositor Window Integration Test"
echo "============================================================"

# Ensure launcher is built and signed
swiftc -O "${REPO_ROOT}/vm/host/microvm_launcher.swift" -o "${REPO_ROOT}/target/microvm_launcher"
codesign --force --sign - --entitlements "${REPO_ROOT}/vm/host/entitlements.plist" "${REPO_ROOT}/target/microvm_launcher"

# Ensure assets are installed
if [[ ! -f "${REPO_ROOT}/vm/images/Image" || ! -f "${REPO_ROOT}/vm/images/initramfs.cpio.gz" ]]; then
    echo "[SETUP] Missing VM assets, running install_assets.sh..."
    "${SCRIPT_DIR}/install_assets.sh"
fi

TEST_RUNTIME=$(mktemp -d /tmp/niri-live-test-XXXXXX)
chmod 700 "${TEST_RUNTIME}"
export XDG_RUNTIME_DIR="${TEST_RUNTIME}"

echo "[NIRI] Starting Niri compositor in background..."
"${REPO_ROOT}/target/debug/niri" > "${TEST_RUNTIME}/niri.log" 2>&1 &
NIRI_PID=$!

# Wait for Niri Wayland socket to appear
WAYLAND_SOCK="${TEST_RUNTIME}/wayland-1"
TRIES=0
while [[ ! -S "${WAYLAND_SOCK}" && $TRIES -lt 150 ]]; do
    if [[ -S "${TEST_RUNTIME}/wayland-0" ]]; then
        WAYLAND_SOCK="${TEST_RUNTIME}/wayland-0"
        break
    fi
    sleep 0.1
    TRIES=$((TRIES + 1))
done

if [[ ! -S "${WAYLAND_SOCK}" ]]; then
    echo "[ERROR] Niri Wayland socket did not appear after timeout!"
    cat "${TEST_RUNTIME}/niri.log"
    kill -TERM "${NIRI_PID}" 2>/dev/null || true
    rm -rf "${TEST_RUNTIME}"
    exit 1
fi
echo "[NIRI] Live Wayland socket active at: ${WAYLAND_SOCK}"

# Locate Niri IPC socket
NIRI_IPC_SOCK=""
TRIES=0
while [[ -z "${NIRI_IPC_SOCK}" && $TRIES -lt 30 ]]; do
    NIRI_IPC_SOCK=$(grep -o "/.*niri\.wayland-[0-9]\.[0-9]*\.sock" "${TEST_RUNTIME}/niri.log" | head -n 1 || true)
    if [[ -z "${NIRI_IPC_SOCK}" ]]; then
        # Search temporary directory for niri socket
        NIRI_IPC_SOCK=$(ls -t "${TMPDIR:-/tmp}"/niri.wayland-*.sock 2>/dev/null | head -n 1 || true)
    fi
    sleep 0.1
    TRIES=$((TRIES + 1))
done

echo "[NIRI] IPC socket active at: ${NIRI_IPC_SOCK}"
export NIRI_SOCKET="${NIRI_IPC_SOCK}"

# Query Niri version via IPC
"${REPO_ROOT}/target/debug/niri" msg version

# Launch MicroVM connecting to Niri's Wayland socket
echo "[VM] Launching Linux MicroVM via Apple Virtualization..."
"${REPO_ROOT}/target/microvm_launcher" \
    --kernel "${REPO_ROOT}/vm/images/Image" \
    --initrd "${REPO_ROOT}/vm/images/initramfs.cpio.gz" \
    --cpus 2 \
    --memory 1024 \
    --wayland-socket "${WAYLAND_SOCK}" \
    --cmdline "console=hvc0 root=/dev/vda rw init=/init quiet loglevel=3 panic=-1" > "${TEST_RUNTIME}/vm.log" 2>&1 &
VM_PID=$!

echo "[TEST] Waiting for in-VM Wayland client window to commit..."
WINDOW_DETECTED=0
for i in $(seq 1 50); do
    sleep 0.5
    WINDOWS_OUTPUT=$("${REPO_ROOT}/target/debug/niri" msg windows 2>&1 || true)
    if echo "${WINDOWS_OUTPUT}" | grep -q -E "(MicroVM Linux Wayland Client|org.niri.microvm.client)"; then
        echo "[SUCCESS] Found in-VM Wayland window in Niri compositor!"
        echo "============================================================"
        echo "${WINDOWS_OUTPUT}"
        echo "============================================================"
        WINDOW_DETECTED=1
        break
    else
        if [[ $i -ge 6 && -n "${WINDOWS_OUTPUT}" ]]; then
            echo "[POLL $i] windows output: ${WINDOWS_OUTPUT}"
        fi
    fi
done

# If not detected yet, check logs
if [[ "${WINDOW_DETECTED}" -eq 0 ]]; then
    echo "[WARN] Window not found within 10s. Dumping VM and Niri logs:"
    echo "--- VM LOG ---"
    cat "${TEST_RUNTIME}/vm.log" | tail -n 30
    echo "--- NIRI LOG ---"
    cat "${TEST_RUNTIME}/niri.log" | tail -n 30
fi

# Clean shutdown
echo "[CLEANUP] Stopping MicroVM and Niri..."
kill -INT "${VM_PID}" 2>/dev/null || true
"${REPO_ROOT}/target/debug/niri" msg action quit --skip-confirmation 2>/dev/null || true
wait "${NIRI_PID}" 2>/dev/null || true
rm -rf "${TEST_RUNTIME}"

if [[ "${WINDOW_DETECTED}" -eq 1 ]]; then
    echo "[PASS] In-VM Wayland client integration test SUCCESS (100%)!"
    exit 0
else
    echo "[FAIL] Window did not appear in Niri."
    exit 1
fi
