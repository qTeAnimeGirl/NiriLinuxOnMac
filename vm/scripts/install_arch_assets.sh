#!/usr/bin/env bash
# vm/scripts/install_arch_assets.sh
# Automated Arch Linux ARM Asset Installer & Bootstrapping Pipeline for Niri Linux MicroVM on macOS (Apple Silicon ARM64)
# Downloads official Arch Linux ARM aarch64 kernel & matching virtio modules, extracts uncompressed Image,
# builds static guest binaries (with pre-compiled fallbacks), and bundles custom Arch Linux initramfs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
IMAGES_DIR="${REPO_ROOT}/vm/images"
PREBUILT_DIR="${REPO_ROOT}/vm/guest/prebuilt/aarch64"
TARGET_DIR="${REPO_ROOT}/target"

ARCH_MIRROR_PRIMARY="http://fl.us.mirror.archlinuxarm.org/aarch64"
ARCH_MIRROR_BACKUP="http://ca.us.mirror.archlinuxarm.org/aarch64"

mkdir -p "${IMAGES_DIR}"
mkdir -p "${TARGET_DIR}"
mkdir -p "${PREBUILT_DIR}"

echo "============================================================"
echo "Arch Linux ARM MicroVM Asset Installer & Initializer"
echo "Target Architecture: aarch64 (Apple Silicon Darwin -> Arch ARM Linux)"
echo "Images Directory:    ${IMAGES_DIR}"
echo "Prebuilt Fallback:   ${PREBUILT_DIR}"
echo "============================================================"

# --- STEP 1: Discover & Download Arch Linux ARM Packages ---
fetch_pkg() {
    local repo="$1"
    local pattern="$2"
    local default_name="$3"
    local dest_file="$4"

    if [[ -f "${dest_file}" ]]; then
        echo "[CACHE] Using cached package: $(basename "${dest_file}")"
        return 0
    fi

    echo "[FETCH] Querying mirror for latest ${pattern} in ${repo}..."
    local pkg_name=""
    pkg_name=$(curl -s "${ARCH_MIRROR_PRIMARY}/${repo}/" | grep -o "${pattern}" | head -n 1 || true)
    if [[ -z "${pkg_name}" ]]; then
        pkg_name=$(curl -s "${ARCH_MIRROR_BACKUP}/${repo}/" | grep -o "${pattern}" | head -n 1 || true)
    fi
    if [[ -z "${pkg_name}" ]]; then
        pkg_name="${default_name}"
    fi

    echo "[FETCH] Downloading ${pkg_name} from ${repo}..."
    if ! curl -fSL "${ARCH_MIRROR_PRIMARY}/${repo}/${pkg_name}" -o "${dest_file}" 2>/dev/null; then
        echo "[FETCH] Retrying from backup mirror..."
        curl -fSL "${ARCH_MIRROR_BACKUP}/${repo}/${pkg_name}" -o "${dest_file}"
    fi
    echo "[FETCH] Successfully downloaded $(basename "${dest_file}")."
}

# 1a. Kernel package (linux-aarch64)
LINUX_PKG_PATH=""
for existing in "${IMAGES_DIR}"/linux-aarch64-*.pkg.tar.*; do
    if [[ -f "${existing}" ]]; then
        LINUX_PKG_PATH="${existing}"
        break
    fi
done

if [[ -z "${LINUX_PKG_PATH}" ]]; then
    LINUX_PKG_PATH="${IMAGES_DIR}/linux-aarch64-7.2.11-1-aarch64.pkg.tar.xz"
    fetch_pkg "core" 'linux-aarch64-[0-9][^"]*\.pkg\.tar\.[^"]*' "linux-aarch64-7.2.11-1-aarch64.pkg.tar.xz" "${LINUX_PKG_PATH}"
else
    echo "[CACHE] Using cached kernel package: $(basename "${LINUX_PKG_PATH}")"
fi

# 1b. Filesystem package (filesystem)
FS_PKG_PATH=""
for existing in "${IMAGES_DIR}"/filesystem-*.pkg.tar.*; do
    if [[ -f "${existing}" ]]; then
        FS_PKG_PATH="${existing}"
        break
    fi
done

if [[ -z "${FS_PKG_PATH}" ]]; then
    FS_PKG_PATH="${IMAGES_DIR}/filesystem-2025.10.12-1-any.pkg.tar.xz"
    fetch_pkg "core" 'filesystem-[0-9][^"]*\.pkg\.tar\.[^"]*' "filesystem-2025.10.12-1-any.pkg.tar.xz" "${FS_PKG_PATH}"
else
    echo "[CACHE] Using cached filesystem package: $(basename "${FS_PKG_PATH}")"
fi

# 1c. Busybox package (static core utilities & shell)
BUSYBOX_PKG_PATH=""
for existing in "${IMAGES_DIR}"/busybox-*.pkg.tar.*; do
    if [[ -f "${existing}" ]]; then
        BUSYBOX_PKG_PATH="${existing}"
        break
    fi
done

if [[ -z "${BUSYBOX_PKG_PATH}" ]]; then
    BUSYBOX_PKG_PATH="${IMAGES_DIR}/busybox-1.36.1-4-aarch64.pkg.tar.xz"
    fetch_pkg "extra" 'busybox-[0-9][^"]*\.pkg\.tar\.[^"]*' "busybox-1.36.1-4-aarch64.pkg.tar.xz" "${BUSYBOX_PKG_PATH}"
else
    echo "[CACHE] Using cached busybox package: $(basename "${BUSYBOX_PKG_PATH}")"
fi

# --- STEP 2: Extract Uncompressed ARM64 Kernel Image ---
KERNEL_IMAGE="${IMAGES_DIR}/Image"
if [[ ! -f "${KERNEL_IMAGE}" || "${LINUX_PKG_PATH}" -nt "${KERNEL_IMAGE}" ]]; then
    echo "[EXTRACT] Extracting uncompressed ARM64 kernel Image from Arch package..."
    tar -xf "${LINUX_PKG_PATH}" -C "${IMAGES_DIR}" boot/Image
    mv -f "${IMAGES_DIR}/boot/Image" "${KERNEL_IMAGE}"
    rm -rf "${IMAGES_DIR}/boot" 2>/dev/null || true
    ln -sf "${KERNEL_IMAGE}" "${IMAGES_DIR}/vmlinuz"
    echo "[EXTRACT] Kernel Image ready ($(stat -f%z "${KERNEL_IMAGE}" 2>/dev/null || stat -c%s "${KERNEL_IMAGE}") bytes)."
else
    echo "[CACHE] Using existing kernel Image: ${KERNEL_IMAGE}"
fi

# --- STEP 3: Compile or Use Pre-compiled Guest Binaries ---
GUEST_PROXY_BIN="${REPO_ROOT}/vm/guest/target/aarch64-unknown-linux-musl/release/niri_vsock_guest"
GUEST_CLIENT_BIN="${REPO_ROOT}/vm/guest/target/aarch64-unknown-linux-musl/release/wayland_window"

HAVE_RUST=0
if command -v cargo >/dev/null 2>&1 && rustup target list 2>/dev/null | grep -q "aarch64-unknown-linux-musl (installed)"; then
    HAVE_RUST=1
fi

if [[ $HAVE_RUST -eq 1 ]]; then
    echo "[BUILD] Compiling static aarch64-unknown-linux-musl guest utilities with cargo..."
    LLD_PATH="$(rustc --print sysroot)/lib/rustlib/aarch64-apple-darwin/bin/gcc-ld/ld.lld"
    mkdir -p "${REPO_ROOT}/vm/guest/.cargo"
    cat << EOF > "${REPO_ROOT}/vm/guest/.cargo/config.toml"
[target.aarch64-unknown-linux-musl]
linker = "${LLD_PATH}"
EOF
    if cargo build --manifest-path "${REPO_ROOT}/vm/guest/Cargo.toml" --target aarch64-unknown-linux-musl --release; then
        echo "[BUILD] Successfully compiled guest binaries via cargo."
        mkdir -p "${PREBUILT_DIR}"
        cp -f "${GUEST_PROXY_BIN}" "${PREBUILT_DIR}/niri_vsock_guest"
        cp -f "${GUEST_CLIENT_BIN}" "${PREBUILT_DIR}/wayland_window"
    else
        echo "[WARN] Cargo build returned non-zero; falling back to pre-compiled guest binaries."
    fi
fi

# Fallback check
if [[ ! -f "${GUEST_PROXY_BIN}" || ! -f "${GUEST_CLIENT_BIN}" ]]; then
    if [[ -f "${PREBUILT_DIR}/niri_vsock_guest" && -f "${PREBUILT_DIR}/wayland_window" ]]; then
        echo "[FALLBACK] Using pre-compiled guest binaries from ${PREBUILT_DIR}..."
        mkdir -p "$(dirname "${GUEST_PROXY_BIN}")"
        cp -f "${PREBUILT_DIR}/niri_vsock_guest" "${GUEST_PROXY_BIN}"
        cp -f "${PREBUILT_DIR}/wayland_window" "${GUEST_CLIENT_BIN}"
    else
        echo "[ERROR] Missing guest binaries and no prebuilt fallback found!"
        exit 1
    fi
fi

# --- STEP 4: Assemble Arch Linux ARM Initramfs / Rootfs ---
CUSTOM_INITRAMFS="${IMAGES_DIR}/initramfs.cpio.gz"
echo "[BUNDLE] Assembling customized Arch Linux ARM initramfs..."

STAGE_DIR=$(mktemp -d /tmp/arch-initramfs-stage-XXXXXX)
pushd "${STAGE_DIR}" >/dev/null

# 4a. Unpack Arch Linux base filesystem
echo "[BUNDLE] Extracting Arch Linux filesystem structure..."
tar -xf "${FS_PKG_PATH}" -C "${STAGE_DIR}" --exclude='.PKGINFO' --exclude='.MTREE' --exclude='.BUILDINFO'

# 4b. Unpack Arch Linux BusyBox
echo "[BUNDLE] Installing Arch Linux BusyBox core utilities..."
tar -xf "${BUSYBOX_PKG_PATH}" -C "${STAGE_DIR}" --exclude='.PKGINFO' --exclude='.MTREE' --exclude='.BUILDINFO' usr/bin/busybox

# Ensure essential symlinks exist
mkdir -p usr/bin usr/lib lib etc/profile.d
ln -sf busybox usr/bin/sh
ln -sf busybox usr/bin/bash
ln -sf busybox usr/bin/ash
ln -sf busybox usr/bin/mount
ln -sf busybox usr/bin/umount
ln -sf busybox usr/bin/insmod
ln -sf busybox usr/bin/modprobe
ln -sf busybox usr/bin/lsmod
ln -sf busybox usr/bin/cttyhack
ln -sf busybox usr/bin/ps
ln -sf busybox usr/bin/kill
ln -sf busybox usr/bin/ls
ln -sf busybox usr/bin/cat

# 4c. Set up official Arch Linux ARM os-release and identification
mkdir -p usr/lib etc
cat << 'EOF' > usr/lib/os-release
NAME="Arch Linux ARM"
PRETTY_NAME="Arch Linux ARM"
ID=archarm
ID_LIKE=arch
BUILD_ID=rolling
ANSI_COLOR="38;2;23;147;209"
HOME_URL="https://archlinuxarm.org/"
DOCUMENTATION_URL="https://archlinuxarm.org/wiki"
SUPPORT_URL="https://archlinuxarm.org/forum"
BUG_REPORT_URL="https://github.com/archlinuxarm/PKGBUILDs/issues"
LOGO=archlinux-logo
EOF
ln -sf ../usr/lib/os-release etc/os-release
touch etc/arch-release

cat << 'EOF' > etc/issue
Arch Linux ARM \r (\l)

EOF

echo "archlinux-arm" > etc/hostname

cat << 'EOF' > etc/passwd
root:x:0:0:root:/root:/bin/bash
alarm:x:1000:1000:Arch User:/home/alarm:/bin/bash
EOF

cat << 'EOF' > etc/group
root:x:0:root
wheel:x:10:root,alarm
users:x:100:alarm
alarm:x:1000:
EOF

# 4d. Extract essential VirtIO and VSOCK kernel modules from Arch package
echo "[BUNDLE] Extracting VirtIO and VSOCK kernel modules..."
tar -xf "${LINUX_PKG_PATH}" -C "${STAGE_DIR}" \
  'usr/lib/modules/*/kernel/drivers/char/hw_random/virtio-rng.ko' \
  'usr/lib/modules/*/kernel/drivers/gpu/drm/virtio/virtio-gpu.ko' \
  'usr/lib/modules/*/kernel/drivers/net/virtio_net.ko' \
  'usr/lib/modules/*/kernel/drivers/virtio/*' \
  'usr/lib/modules/*/kernel/fs/fuse/*' \
  'usr/lib/modules/*/kernel/net/vmw_vsock/*' 2>/dev/null || true

# 4e. Inject guest binaries
cp -f "${GUEST_PROXY_BIN}" usr/bin/niri_vsock_guest
cp -f "${GUEST_CLIENT_BIN}" usr/bin/wayland_window
chmod 755 usr/bin/niri_vsock_guest usr/bin/wayland_window

# 4f. Create Arch Linux PID 1 /init script
cat << 'EOF' > init
#!/bin/sh
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export USER=root
export HOME=/root
export TERM=xterm-256color

# Install all busybox applets
/usr/bin/busybox --install -s /usr/bin 2>/dev/null || true

# Mount essential pseudo-filesystems
mount -t proc none /proc 2>/dev/null || true
mount -t sysfs none /sys 2>/dev/null || true
mount -t devtmpfs none /dev 2>/dev/null || true
mount -t tmpfs none /run 2>/dev/null || true
mount -t tmpfs none /tmp 2>/dev/null || true

# Load VirtIO vsock and virtio-fs kernel drivers in order
for mod in vsock vmw_vsock_virtio_transport_common vmw_vsock_virtio_transport fuse virtiofs virtio-gpu virtio_net virtio-rng; do
    find /usr/lib/modules -name "${mod}.ko" -exec insmod {} \; 2>/dev/null || true
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

echo "[GUEST INIT] Arch Linux ARM MicroVM booted."
echo "[GUEST INIT] Starting vsock Wayland proxy..."
/usr/bin/niri_vsock_guest &
PROXY_PID=$!

# Wait for wayland-0 socket to be ready
TRIES=0
while [ ! -S /run/user/1000/wayland-0 ] && [ $TRIES -lt 30 ]; do
    usleep 20000 2>/dev/null || sleep 0.05
    TRIES=$((TRIES + 1))
done

if [ -S /run/user/1000/wayland-0 ]; then
    echo "[GUEST INIT] Wayland socket /run/user/1000/wayland-0 ready!"
    echo "[GUEST INIT] Launching static Wayland client window..."
    /usr/bin/wayland_window &
    CLIENT_PID=$!
else
    echo "[GUEST INIT WARN] Wayland socket not ready yet; client will retry on socket appearance."
fi

# Print Arch Linux Welcome Banner
echo ""
echo "  ██████╗ ██████╗  ██████╗██╗  ██╗    ███████╗███████╗"
echo " ██╔══██╗██╔══██╗██╔════╝██║  ██║    ██╔════╝██╔════╝"
echo " ███████║██████╔╝██║     ███████║    ███████╗█████╗  "
echo " ██╔══██║██╔══██╗██║     ██╔══██║    ╚════██║██╔══╝  "
echo " ██║  ██║██║  ██║╚██████╗██║  ██║    ███████║███████╗"
echo " ╚═╝  ╚═╝╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝    ╚══════╝╚══════╝"
echo "       Arch Linux ARM (aarch64) MicroVM for Niri"
echo "  Kernel: $(uname -r) | Arch Linux ARM rolling"
echo "  Wayland: /run/user/1000/wayland-0"
echo "============================================================"
echo "Interactive shell ready. Type commands below:"
echo ""

# Determine controlling console device
CONSOLE="/dev/console"
if [ -e /dev/hvc0 ]; then
    CONSOLE="/dev/hvc0"
elif [ -e /dev/ttyAMA0 ]; then
    CONSOLE="/dev/ttyAMA0"
elif [ -e /dev/ttyS0 ]; then
    CONSOLE="/dev/ttyS0"
fi

# Run interactive shell on console with job control enabled, respawning if exited
while true; do
    if [ -e "$CONSOLE" ]; then
        setsid /usr/bin/cttyhack /bin/sh -i <"$CONSOLE" >"$CONSOLE" 2>&1 || \
        /bin/sh -i <"$CONSOLE" >"$CONSOLE" 2>&1
    else
        /bin/sh -i
    fi
    echo "[GUEST] Shell exited. Respawning in 1s..."
    sleep 1
done
EOF
chmod 755 init

# 4g. Repack initramfs
echo "[BUNDLE] Repacking Arch Linux initramfs archive..."
find . | cpio -H newc -o 2>/dev/null | gzip -9 > "${CUSTOM_INITRAMFS}"
popd >/dev/null
rm -rf "${STAGE_DIR}"

echo "[BUNDLE] Created customized Arch Linux initramfs: ${CUSTOM_INITRAMFS}"

# --- STEP 5: Compile & Sign Host Virtualization Launcher ---
echo "[SIGN] Building and signing Apple Virtualization launcher..."
BIN_PATH="${TARGET_DIR}/microvm_launcher"
swiftc -O "${REPO_ROOT}/vm/host/microvm_launcher.swift" -o "${BIN_PATH}"
codesign --force --sign - --entitlements "${REPO_ROOT}/vm/host/entitlements.plist" "${BIN_PATH}"

echo "============================================================"
echo "ARCH LINUX ARM ASSET BOOTSTRAP COMPLETE!"
echo "Kernel Image:     ${KERNEL_IMAGE}"
echo "Initramfs Image:  ${CUSTOM_INITRAMFS}"
echo "Host Launcher:    ${BIN_PATH}"
echo "============================================================"
