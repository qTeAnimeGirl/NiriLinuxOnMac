#!/usr/bin/env bash
# vm/scripts/install_arch_assets.sh
# Automated Arch Linux ARM Asset Installer & Bootstrapping Pipeline for Niri Linux MicroVM on macOS (Apple Silicon ARM64)
# Downloads official Arch Linux ARM aarch64 kernel, core packages providing pacman and shared libraries,
# builds static guest binaries, configures network/DNS, SSL certs, and bundles a full Arch Linux ARM initramfs.

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

    if [[ -f "${dest_file}" && -s "${dest_file}" ]]; then
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

find_or_fetch_pkg() {
    local repo="$1"
    local pkg_name="$2"

    # Check existing files in IMAGES_DIR
    local clean_name="${pkg_name//+/}"
    for f in "${IMAGES_DIR}/${pkg_name}-"[0-9]*.pkg.tar.* "${IMAGES_DIR}/${clean_name}"*[0-9]*.pkg.tar.*; do
        if [[ -f "$f" && -s "$f" ]]; then
            echo "$f"
            return 0
        fi
    done

    # Fetch from mirror
    local escaped_pkg="${pkg_name//+/%2B}"
    local pattern="${escaped_pkg}-[0-9][^\"]*\.pkg\.tar\.[^\"]*"
    local dest_file_name=""
    dest_file_name=$(curl -s "${ARCH_MIRROR_PRIMARY}/${repo}/" | grep -o "${pattern}" | head -n 1 || true)
    if [[ -z "${dest_file_name}" ]]; then
        dest_file_name=$(curl -s "${ARCH_MIRROR_BACKUP}/${repo}/" | grep -o "${pattern}" | head -n 1 || true)
    fi

    if [[ -z "${dest_file_name}" ]]; then
        echo "[ERROR] Could not find package ${pkg_name} in ${repo}!" >&2
        return 1
    fi

    local target_path="${IMAGES_DIR}/${dest_file_name}"
    fetch_pkg "${repo}" "${pattern}" "${dest_file_name}" "${target_path}" >&2
    echo "${target_path}"
}

# 1a. Kernel package (linux-aarch64)
LINUX_PKG_PATH=""
for existing in "${IMAGES_DIR}"/linux-aarch64-*.pkg.tar.*; do
    if [[ -f "${existing}" && -s "${existing}" ]]; then
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

# 1b. Core Arch Linux ARM packages providing pacman, bash, coreutils, curl, ssl, and runtime libraries
CORE_PACKAGE_LIST=(
    "filesystem"
    "busybox"
    "glibc"
    "gcc-libs"
    "libgcc"
    "libstdc++"
    "bash"
    "coreutils"
    "readline"
    "ncurses"
    "pacman"
    "pacman-mirrorlist"
    "archlinux-keyring"
    "archlinuxarm-keyring"
    "libarchive"
    "curl"
    "openssl"
    "gpgme"
    "libgpg-error"
    "libassuan"
    "libseccomp"
    "zlib"
    "bzip2"
    "xz"
    "zstd"
    "lz4"
    "acl"
    "attr"
    "libcap"
    "gmp"
    "e2fsprogs"
    "libverto"
    "icu"
    "libxml2"
    "ca-certificates"
    "ca-certificates-utils"
    "libnghttp2"
    "libnghttp3"
    "libngtcp2"
    "libpsl"
    "krb5"
    "keyutils"
    "libssh2"
    "libidn2"
    "libunistring"
    "brotli"
)

RESOLVED_PACKAGES=()
echo "[RESOLVE] Checking core Arch Linux ARM packages..."
for pkg in "${CORE_PACKAGE_LIST[@]}"; do
    repo="core"
    if [[ "$pkg" == "busybox" ]]; then
        repo="extra"
    fi
    pkg_path=$(find_or_fetch_pkg "${repo}" "${pkg}")
    RESOLVED_PACKAGES+=("${pkg_path}")
done

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

# 4a. Unpack all core Arch Linux ARM packages
echo "[BUNDLE] Extracting Arch Linux packages..."
for pkg_path in "${RESOLVED_PACKAGES[@]}"; do
    echo "  -> Unpacking $(basename "${pkg_path}")..."
    tar -xf "${pkg_path}" -C "${STAGE_DIR}" \
        --exclude='.PKGINFO' \
        --exclude='.MTREE' \
        --exclude='.BUILDINFO' \
        --exclude='.INSTALL' \
        --exclude='usr/share/man/*' \
        --exclude='usr/share/doc/*' \
        2>/dev/null || true
done

# 4b. Ensure essential busybox applets and symlinks
mkdir -p usr/bin usr/lib lib etc/profile.d usr/share/udhcpc
for applet in find insmod lsmod rmmod modprobe ip ifconfig route udhcpc setsid cttyhack awk sed grep dmesg ping ping6 traceroute netstat which less vi reboot poweroff; do
    if [[ ! -e "usr/bin/${applet}" ]]; then
        ln -sf busybox "usr/bin/${applet}"
    fi
done

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
alpm:x:998:998:alpm:/var/empty:/usr/bin/nologin
alarm:x:1000:1000:Arch User:/home/alarm:/bin/bash
EOF

cat << 'EOF' > etc/group
root:x:0:root
wheel:x:10:root,alarm
alpm:x:998:
users:x:100:alarm
alarm:x:1000:
EOF

# 4d. Configure pacman.conf and mirrorlist
mkdir -p etc/pacman.d var/lib/pacman/sync var/lib/pacman/local var/cache/pacman/pkg var/log
cat << 'EOF' > etc/pacman.conf
#
# /etc/pacman.conf - Niri Arch Linux ARM MicroVM configuration
#
[options]
HoldPkg     = pacman glibc
Architecture = aarch64
CheckSpace
SigLevel    = Never
LocalFileSigLevel = Optional
DisableSandboxFilesystem
DisableSandboxSyscalls
ParallelDownloads = 5

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[alarm]
Include = /etc/pacman.d/mirrorlist

[aur]
Include = /etc/pacman.d/mirrorlist
EOF

cat << 'EOF' > etc/pacman.d/mirrorlist
Server = http://fl.us.mirror.archlinuxarm.org/$arch/$repo
Server = http://ca.us.mirror.archlinuxarm.org/$arch/$repo
Server = http://nj.us.mirror.archlinuxarm.org/$arch/$repo
Server = http://mirror.archlinuxarm.org/$arch/$repo
EOF

# 4e. Setup SSL certificate trust store
mkdir -p etc/ssl/certs etc/ca-certificates/extracted
if [[ -f /etc/ssl/cert.pem ]]; then
    cp -f /etc/ssl/cert.pem etc/ssl/certs/ca-certificates.crt
    cp -f /etc/ssl/cert.pem etc/ssl/cert.pem
    cp -f /etc/ssl/cert.pem etc/ca-certificates/extracted/tls-ca-bundle.pem
    ln -sf ca-certificates.crt etc/ssl/certs/ca-bundle.crt 2>/dev/null || true
fi

# 4f. Setup udhcpc default script
cat << 'EOF' > usr/share/udhcpc/default.script
#!/bin/sh
[ -z "$1" ] && exit 1
case "$1" in
    deconfig)
        ip addr flush dev "$interface" 2>/dev/null || ifconfig "$interface" 0.0.0.0 2>/dev/null || true
        ;;
    renew|bound)
        ip addr add "${ip}/${subnet:-24}" dev "$interface" 2>/dev/null || ifconfig "$interface" "$ip" ${subnet:+netmask $subnet} up 2>/dev/null || true
        if [ -n "$router" ]; then
            for r in $router; do
                ip route add default via "$r" dev "$interface" 2>/dev/null || route add default gw "$r" dev "$interface" 2>/dev/null || true
            done
        fi
        if [ -n "$dns" ]; then
            echo -n > /etc/resolv.conf
            for d in $dns; do
                echo "nameserver $d" >> /etc/resolv.conf
            done
        fi
        ;;
esac
exit 0
EOF
chmod 755 usr/share/udhcpc/default.script

# 4g. Setup Wayland environment in profile and bashrc
cat << 'EOF' > etc/profile
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=wayland-0
export MOZ_ENABLE_WAYLAND=1
export GDK_BACKEND=wayland
export QT_QPA_PLATFORM=wayland
export CLUTTER_BACKEND=wayland
export SDL_VIDEODRIVER=wayland
export TERM=xterm-256color
EOF

mkdir -p root home/alarm
cat << 'EOF' > root/.bashrc
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=wayland-0
export MOZ_ENABLE_WAYLAND=1
export GDK_BACKEND=wayland
export QT_QPA_PLATFORM=wayland
export CLUTTER_BACKEND=wayland
export SDL_VIDEODRIVER=wayland
alias ll='ls -la'
EOF
cp -f root/.bashrc home/alarm/.bashrc

# 4h. Create helper scripts /usr/bin/wayland-run and /usr/bin/install-firefox
cat << 'EOF' > usr/bin/wayland-run
#!/bin/sh
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=wayland-0
export MOZ_ENABLE_WAYLAND=1
export GDK_BACKEND=wayland
export QT_QPA_PLATFORM=wayland
export CLUTTER_BACKEND=wayland
export SDL_VIDEODRIVER=wayland
exec "$@"
EOF
chmod 755 usr/bin/wayland-run

cat << 'EOF' > usr/bin/install-firefox
#!/bin/sh
set -e
echo "============================================================"
echo "Installing Firefox via Arch Linux pacman..."
echo "============================================================"
pacman -Sy --noconfirm firefox
echo "Launching Firefox under Wayland..."
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=wayland-0
export MOZ_ENABLE_WAYLAND=1
export GDK_BACKEND=wayland
export QT_QPA_PLATFORM=wayland
export CLUTTER_BACKEND=wayland
export SDL_VIDEODRIVER=wayland
MOZ_ENABLE_WAYLAND=1 firefox &
echo "Firefox launched in background!"
EOF
chmod 755 usr/bin/install-firefox

# 4i. Extract essential VirtIO, network, and VSOCK kernel modules
echo "[BUNDLE] Extracting VirtIO, Net, and VSOCK kernel modules..."
tar -xf "${LINUX_PKG_PATH}" -C "${STAGE_DIR}" \
  'usr/lib/modules/*/kernel/drivers/char/hw_random/virtio-rng.ko' \
  'usr/lib/modules/*/kernel/drivers/gpu/drm/virtio/virtio-gpu.ko' \
  'usr/lib/modules/*/kernel/drivers/net/net_failover.ko' \
  'usr/lib/modules/*/kernel/drivers/net/virtio_net.ko' \
  'usr/lib/modules/*/kernel/drivers/virtio/*' \
  'usr/lib/modules/*/kernel/fs/fuse/*' \
  'usr/lib/modules/*/kernel/net/core/failover.ko' \
  'usr/lib/modules/*/kernel/net/vmw_vsock/*' 2>/dev/null || true

mkdir -p lib/modules
find usr/lib/modules -name "*.ko" -exec cp -f {} lib/modules/ \; 2>/dev/null || true

# 4j. Inject guest binaries
cp -f "${GUEST_PROXY_BIN}" usr/bin/niri_vsock_guest
cp -f "${GUEST_CLIENT_BIN}" usr/bin/wayland_window
chmod 755 usr/bin/niri_vsock_guest usr/bin/wayland_window

# 4k. Create Arch Linux PID 1 /init script
cat << 'EOF' > init
#!/bin/sh
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin
export USER=root
export HOME=/root
export TERM=xterm-256color

export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=wayland-0
export MOZ_ENABLE_WAYLAND=1
export GDK_BACKEND=wayland
export QT_QPA_PLATFORM=wayland
export CLUTTER_BACKEND=wayland
export SDL_VIDEODRIVER=wayland

# 0. Ensure busybox applets are linked
/usr/bin/busybox --install -s /usr/bin 2>/dev/null || true

# 1. Mount essential pseudo-filesystems
mount -t proc none /proc 2>/dev/null || true
mount -t sysfs none /sys 2>/dev/null || true
mount -t devtmpfs none /dev 2>/dev/null || true
mount -t tmpfs none /run 2>/dev/null || true
mount -t tmpfs none /tmp 2>/dev/null || true

# 2. Update dynamic linker cache
/usr/bin/ldconfig 2>/dev/null || true

# 3. Load VirtIO kernel drivers
for mod in failover net_failover virtio_net vsock vmw_vsock_virtio_transport_common vmw_vsock_virtio_transport fuse virtiofs virtio-gpu virtio-rng; do
    if [ -f "/lib/modules/${mod}.ko" ]; then
        insmod "/lib/modules/${mod}.ko" 2>/dev/null || true
    elif command -v find >/dev/null 2>&1; then
        find /usr/lib/modules -name "${mod}.ko" -exec insmod {} \; 2>/dev/null || true
    fi
done

# 4. Setup network interface, DHCP, and DNS
ip link set lo up 2>/dev/null || ifconfig lo 127.0.0.1 up 2>/dev/null || true
ip link set eth0 up 2>/dev/null || ifconfig eth0 up 2>/dev/null || true
udhcpc -i eth0 -n -q -t 3 -s /usr/share/udhcpc/default.script 2>/dev/null || udhcpc -i eth0 -n -q -t 3 2>/dev/null || true

if [ ! -s /etc/resolv.conf ]; then
    cat << 'RESEOF' > /etc/resolv.conf
nameserver 1.1.1.1
nameserver 8.8.8.8
RESEOF
fi

# 5. Setup runtime directories and permissions
mkdir -p /run/user/1000 /dev/shm /tmp /var/log /var/cache/pacman/pkg /var/lib/pacman/local /var/lib/pacman/sync
mount -t tmpfs none /dev/shm 2>/dev/null || true

# Mount virtio-fs host share if tag exists
if grep -q virtiofs /proc/filesystems 2>/dev/null; then
    mount -t virtiofs host_share /dev/shm 2>/dev/null || true
fi

chmod 0777 /run/user/1000 2>/dev/null || true
chmod 1777 /dev/shm 2>/dev/null || true
chmod 1777 /tmp 2>/dev/null || true

# 6. Start vsock Wayland proxy
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
    chmod 0666 /run/user/1000/wayland-0
    echo "[GUEST INIT] Wayland socket /run/user/1000/wayland-0 ready (mode 0666)!"
    if [ -x /usr/bin/wayland_window ]; then
        echo "[GUEST INIT] Launching static Wayland client window..."
        /usr/bin/wayland_window &
        CLIENT_PID=$!
    fi
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
echo "  Kernel: $(uname -r) | pacman ready"
echo "  Network: $(ip -o -4 addr show eth0 2>/dev/null | awk '{print $4}' || echo 'configured')"
echo "  Wayland: /run/user/1000/wayland-0 (0666)"
echo "  Commands: pacman, wayland-run, install-firefox"
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

# Run interactive login shell on console
while true; do
    if [ -e "$CONSOLE" ]; then
        setsid /usr/bin/cttyhack /bin/bash -l <"$CONSOLE" >"$CONSOLE" 2>&1 || \
        setsid /usr/bin/cttyhack /bin/sh -l <"$CONSOLE" >"$CONSOLE" 2>&1 || \
        /bin/bash -l <"$CONSOLE" >"$CONSOLE" 2>&1 || \
        /bin/sh -l <"$CONSOLE" >"$CONSOLE" 2>&1
    else
        /bin/bash -l || /bin/sh -l
    fi
    echo "[GUEST] Shell exited. Respawning in 1s..."
    sleep 1
done
EOF
chmod 755 init

# 4l. Repack initramfs
echo "[BUNDLE] Repacking Arch Linux initramfs archive..."
find . | cpio -H newc -o 2>/dev/null | gzip -1 > "${CUSTOM_INITRAMFS}"
popd >/dev/null
rm -rf "${STAGE_DIR}"

echo "[BUNDLE] Created customized Arch Linux initramfs: ${CUSTOM_INITRAMFS} ($(stat -f%z "${CUSTOM_INITRAMFS}" 2>/dev/null || stat -c%s "${CUSTOM_INITRAMFS}") bytes)"

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
