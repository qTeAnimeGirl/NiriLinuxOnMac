#!/usr/bin/env bash
# vm/scripts/test_vm_bridge.sh
# End-to-end integration and sanity test for Niri virtio-vsock Wayland bridge pipeline

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "=== STEP 1: Unit Testing Protocol ABI and Bounds Checking ==="
rustc --edition=2021 --test "${REPO_ROOT}/vm/proto/mod.rs" -o /tmp/test_proto_abi
/tmp/test_proto_abi
rm -f /tmp/test_proto_abi
echo "[OK] Protocol ABI and SHM bounds verification passed."

echo "=== STEP 2: Building Host Bridge (niri-vsock-host) ==="
cargo build --manifest-path "${REPO_ROOT}/vm/host/Cargo.toml"
HOST_BIN="${REPO_ROOT}/vm/host/target/debug/niri-vsock-host"
echo "[OK] Host bridge compiled successfully."

echo "=== STEP 3: Compiling Guest Wayland Proxy Daemon ==="
clang -Wall -Wextra -Werror -pthread "${REPO_ROOT}/vm/guest/niri_vsock_guest.c" -o /tmp/test_guest_proxy
echo "[OK] Guest proxy compiled successfully."

echo "=== STEP 4: Compiling Apple Virtualization MicroVM Launcher ==="
swiftc -O "${REPO_ROOT}/vm/host/microvm_launcher.swift" -o /tmp/test_vz_launcher
/tmp/test_vz_launcher --help >/dev/null
echo "[OK] Apple Virtualization launcher compiled and validated."

echo "=== STEP 5: End-to-End Bridge Loopback Socket Test ==="
TEST_DIR=$(mktemp -d /tmp/niri-bridge-test-XXXXXX)
MOCK_NIRI_SOCK="${TEST_DIR}/niri-wayland.sock"
VSOCK_BRIDGE_SOCK="${TEST_DIR}/vsock-bridge.sock"
GUEST_WAYLAND_SOCK="${TEST_DIR}/guest-wayland.sock"
SHARED_SHM_DIR="${TEST_DIR}/shm"
mkdir -p "${SHARED_SHM_DIR}"

# 5a. Start Mock Niri Wayland Server
python3 -c "
import socket, sys, os

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind('${MOCK_NIRI_SOCK}')
server.listen(1)
print('[MOCK NIRI] Listening on ${MOCK_NIRI_SOCK}')
sys.stdout.flush()

conn, _ = server.accept()
print('[MOCK NIRI] Host bridge connected!')
sys.stdout.flush()

data = conn.recv(1024)
print(f'[MOCK NIRI] Received {len(data)} bytes: {data}')
conn.sendall(b'WAYLAND_SERVER_HELLO')
conn.close()
server.close()
" &
MOCK_SERVER_PID=$!
sleep 0.2

# 5b. Start Host Bridge daemon
"${HOST_BIN}" \
    --wayland-socket "${MOCK_NIRI_SOCK}" \
    --listen-socket "${VSOCK_BRIDGE_SOCK}" \
    --shared-dir "${SHARED_SHM_DIR}" &
HOST_BRIDGE_PID=$!
sleep 0.3

# 5c. Start Guest Proxy daemon
/tmp/test_guest_proxy \
    --socket "${GUEST_WAYLAND_SOCK}" \
    --fallback-socket "${VSOCK_BRIDGE_SOCK}" &
GUEST_PROXY_PID=$!
sleep 0.3

# 5d. Run mock Wayland client
python3 -c "
import socket, sys, time, os

sock_path = '${GUEST_WAYLAND_SOCK}'
for _ in range(50):
    if os.path.exists(sock_path):
        break
    time.sleep(0.05)

client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.connect(sock_path)
print('[CLIENT] Connected to guest proxy socket!')
client.sendall(b'MOCK_WAYLAND_CLIENT_INIT')

resp = client.recv(1024)
print(f'[CLIENT] Received response from compositor: {resp}')
assert resp == b'WAYLAND_SERVER_HELLO', f'Unexpected response: {resp}'
print('[CLIENT] Round-trip bridge test SUCCESS!')
client.close()
"

# 5e. Cleanup
kill -TERM "${GUEST_PROXY_PID}" 2>/dev/null || true
kill -TERM "${HOST_BRIDGE_PID}" 2>/dev/null || true
wait "${MOCK_SERVER_PID}" 2>/dev/null || true
rm -rf "${TEST_DIR}" /tmp/test_guest_proxy /tmp/test_vz_launcher

echo "============================================================"
echo "ALL VM & GRAPHICS BRIDGE VERIFICATION TESTS PASSED (100%)!"
echo "============================================================"
