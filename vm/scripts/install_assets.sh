#!/usr/bin/env bash
# vm/scripts/install_assets.sh
# Automated Asset Installer & Bootstrapping Pipeline for Niri Linux MicroVM on macOS (ARM64)
# Downloads Alpine aarch64 kernel & matching modules, extracts uncompressed Image,
# builds static guest binaries, and bundles custom initramfs with virtio-vsock drivers.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
IMAGES_DIR="${REPO_ROOT}/vm/images"
ALPINE_MAIN="https://dl-cdn.alpinelinux.org/alpine/v3.20/main/aarch64"
ALPINE_NETBOOT="https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/aarch64/netboot"
LINUX_VIRT_PKG="linux-virt-6.6.142-r0.apk"

mkdir -p "${IMAGES_DIR}"
mkdir -p "${REPO_ROOT}/target"

echo "============================================================"
echo "Niri Linux MicroVM Asset Installer & Initializer"
echo "Target Architecture: aarch64-apple-darwin -> aarch64 Linux"
echo "Output Directory:    ${IMAGES_DIR}"
echo "============================================================"

# --- STEP 1: Download Alpine Kernel Package & Initramfs ---
LINUX_PKG_PATH="${IMAGES_DIR}/${LINUX_VIRT_PKG}"
INITRAMFS_SRC="${IMAGES_DIR}/initramfs-virt.orig"

if [[ ! -f "${LINUX_PKG_PATH}" ]]; then
    echo "[FETCH] Downloading Alpine Linux virt kernel package (${LINUX_VIRT_PKG})..."
    curl -fSL "${ALPINE_MAIN}/${LINUX_VIRT_PKG}" -o "${LINUX_PKG_PATH}"
else
    echo "[CACHE] Using cached kernel package: ${LINUX_PKG_PATH}"
fi

if [[ ! -f "${INITRAMFS_SRC}" ]]; then
    echo "[FETCH] Downloading Alpine aarch64 initramfs (initramfs-virt)..."
    curl -fSL "${ALPINE_NETBOOT}/initramfs-virt" -o "${INITRAMFS_SRC}"
else
    echo "[CACHE] Using cached initramfs: ${INITRAMFS_SRC}"
fi

# Extract vmlinuz-virt from package
VMLINUZ_PATH="${IMAGES_DIR}/vmlinuz-virt"
if [[ ! -f "${VMLINUZ_PATH}" || "${LINUX_PKG_PATH}" -nt "${VMLINUZ_PATH}" ]]; then
    echo "[EXTRACT] Extracting vmlinuz-virt from kernel package..."
    tar -xzf "${LINUX_PKG_PATH}" -C "${IMAGES_DIR}" boot/vmlinuz-virt
    mv -f "${IMAGES_DIR}/boot/vmlinuz-virt" "${VMLINUZ_PATH}"
    rmdir "${IMAGES_DIR}/boot" 2>/dev/null || true
fi

# --- STEP 2: Decompress Kernel to Uncompressed Image for Apple VZLinuxBootLoader ---
KERNEL_IMAGE="${IMAGES_DIR}/Image"
if [[ ! -f "${KERNEL_IMAGE}" || "${VMLINUZ_PATH}" -nt "${KERNEL_IMAGE}" ]]; then
    echo "[DECOMPRESS] Extracting uncompressed Linux kernel Image from vmlinuz-virt..."
    python3 -c "
import zlib, sys

kernel_in = '${VMLINUZ_PATH}'
image_out = '${KERNEL_IMAGE}'

with open(kernel_in, 'rb') as f:
    data = f.read()

# Locate gzip header magic: 1F 8B 08
idx = data.find(b'\x1f\x8b\x08')
if idx < 0:
    print('[ERROR] Could not find gzip stream signature in kernel', file=sys.stderr)
    sys.exit(1)

print(f'[DECOMPRESS] Found kernel gzip payload at byte offset {idx}')
decompressor = zlib.decompressobj(16 + zlib.MAX_WBITS)
decompressed = decompressor.decompress(data[idx:])

with open(image_out, 'wb') as out:
    out.write(decompressed)

print(f'[DECOMPRESS] Extracted uncompressed Image ({len(decompressed)} bytes)')
"
    ln -sf "${KERNEL_IMAGE}" "${IMAGES_DIR}/vmlinuz"
fi

# --- STEP 3: Build Static Linux Guest Proxy & Wayland Window Client ---
echo "[BUILD] Compiling static aarch64-unknown-linux-musl guest utilities..."
LLD_PATH="$(rustc --print sysroot)/lib/rustlib/aarch64-apple-darwin/bin/gcc-ld/ld.lld"
mkdir -p "${REPO_ROOT}/vm/guest/.cargo"
cat << EOF > "${REPO_ROOT}/vm/guest/.cargo/config.toml"
[target.aarch64-unknown-linux-musl]
linker = "${LLD_PATH}"
EOF

cargo build --manifest-path "${REPO_ROOT}/vm/guest/Cargo.toml" --target aarch64-unknown-linux-musl --release

GUEST_PROXY_BIN="${REPO_ROOT}/vm/guest/target/aarch64-unknown-linux-musl/release/niri_vsock_guest"
GUEST_CLIENT_BIN="${REPO_ROOT}/vm/guest/target/aarch64-unknown-linux-musl/release/wayland_window"

if [[ ! -f "${GUEST_PROXY_BIN}" || ! -f "${GUEST_CLIENT_BIN}" ]]; then
    echo "[ERROR] Guest binaries build failed!"
    exit 1
fi
echo "[BUILD] Successfully compiled static guest binaries."

# --- STEP 4: Assemble Custom Alpine Initramfs with vsock Modules, Client & Proxy ---
CUSTOM_INITRAMFS="${IMAGES_DIR}/initramfs.cpio.gz"
echo "[BUNDLE] Assembling customized microVM initramfs..."

STAGE_DIR=$(mktemp -d /tmp/niri-initramfs-stage-XXXXXX)
pushd "${STAGE_DIR}" >/dev/null

# 4a. Unpack original Alpine initramfs
gzip -dc "${INITRAMFS_SRC}" | cpio -idm 2>/dev/null

# 4b. Extract essential kernel modules (vsock and virtiofs) from linux-virt package
mkdir -p lib/modules
tar -xzf "${LINUX_PKG_PATH}" -C . \
    'lib/modules/*/kernel/net/vmw_vsock/*' \
    'lib/modules/*/kernel/fs/fuse/*' 2>/dev/null || true

# Decompress any .ko.gz files to .ko for fast insmod
find lib/modules -name "*.ko.gz" -exec gzip -d {} + 2>/dev/null || true

# 4c. Inject guest binaries
mkdir -p bin usr/bin usr/local/bin
cp "${GUEST_PROXY_BIN}" bin/niri_vsock_guest
cp "${GUEST_CLIENT_BIN}" bin/wayland_window
chmod 755 bin/niri_vsock_guest bin/wayland_window

# 4d. Inject PID 1 /init script
cat << 'EOF' > init
#!/bin/sh
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin
/bin/busybox --install -s 2>/dev/null || true

# Mount pseudo filesystems
mount -t proc none /proc 2>/dev/null || true
mount -t sysfs none /sys 2>/dev/null || true
mount -t devtmpfs none /dev 2>/dev/null || true
mount -t tmpfs none /run 2>/dev/null || true
mount -t tmpfs none /tmp 2>/dev/null || true

# Load VirtIO vsock and virtio-fs kernel drivers in order
for mod in vsock vmw_vsock_virtio_transport_common vmw_vsock_virtio_transport fuse virtiofs; do
    find /lib/modules -name "${mod}.ko" -exec insmod {} \; 2>/dev/null || true
done

# Setup runtime directories
mkdir -p /run/user/1000 /dev/shm
mount -t tmpfs none /dev/shm 2>/dev/null || true

# Mount virtio-fs host share if tag exists
if grep -q virtiofs /proc/filesystems 2>/dev/null; then
    mount -t virtiofs host_share /dev/shm 2>/dev/null || true
fi

chmod 700 /run/user/1000
chmod 1777 /dev/shm

export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=wayland-0

echo "[GUEST INIT] MicroVM booted. Starting vsock Wayland proxy..."
/bin/niri_vsock_guest &
PROXY_PID=$!

# Wait for wayland-0 socket to be ready
TRIES=0
while [ ! -S /run/user/1000/wayland-0 ] && [ $TRIES -lt 30 ]; do
    usleep 20000 2>/dev/null || sleep 0.05
    TRIES=$((TRIES + 1))
done

if [ -S /run/user/1000/wayland-0 ]; then
    echo "[GUEST INIT] Wayland socket /run/user/1000/wayland-0 ready!"
    echo "[GUEST INIT] Launching static Wayland window client..."
    /bin/wayland_window &
    CLIENT_PID=$!
else
    echo "[GUEST INIT ERROR] Wayland socket not ready after timeout"
fi

# Keep init alive
while true; do
    sleep 3600
done
EOF
chmod 755 init

# 4e. Repack initramfs
find . | cpio -H newc -o 2>/dev/null | gzip -9 > "${CUSTOM_INITRAMFS}"
popd >/dev/null
rm -rf "${STAGE_DIR}"

echo "[BUNDLE] Created customized initramfs: ${CUSTOM_INITRAMFS}"

# --- STEP 5: Compile & Sign Host Virtualization Launcher ---
echo "[SIGN] Building and signing Apple Virtualization launcher..."
BIN_PATH="${REPO_ROOT}/target/microvm_launcher"
swiftc -O "${REPO_ROOT}/vm/host/microvm_launcher.swift" -o "${BIN_PATH}"
codesign --force --sign - --entitlements "${REPO_ROOT}/vm/host/entitlements.plist" "${BIN_PATH}"

echo "============================================================"
echo "INSTALLATION & ASSET BOOTSTRAP COMPLETE!"
echo "Kernel Image:     ${KERNEL_IMAGE}"
echo "Initramfs Image:  ${CUSTOM_INITRAMFS}"
echo "Host Launcher:    ${BIN_PATH}"
echo "============================================================"
