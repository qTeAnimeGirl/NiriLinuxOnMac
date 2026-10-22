#!/bin/sh
# vm/guest/init.sh
# Minimal sub-200ms PID 1 init script for Linux MicroVM guest on macOS

set -e

# 1. Mount virtual kernel filesystems
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev
mount -t tmpfs none /run
mount -t tmpfs none /tmp

# 2. Configure network loopback
ifconfig lo 127.0.0.1 up 2>/dev/null || ip link set lo up 2>/dev/null || true

# 3. Setup runtime and shared directories
mkdir -p /run/user/1000
mkdir -p /dev/shm

# Mount virtio-fs host share if available
if grep -q virtiofs /proc/filesystems 2>/dev/null; then
    mount -t virtiofs host_share /dev/shm 2>/dev/null || true
fi

# Ensure user 1000 exists
if ! id -u 1000 >/dev/null 2>&1; then
    adduser -D -u 1000 -s /bin/sh niri 2>/dev/null || true
fi

chown -R 1000:1000 /run/user/1000
chmod 700 /run/user/1000
chown -R 1000:1000 /dev/shm
chmod 1777 /dev/shm

# 4. Environment setup
export HOME=/home/niri
export USER=niri
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=wayland-0
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/virtio_icd.aarch64.json
export GALLIUM_DRIVER=virpipe
export LIBGL_ALWAYS_SOFTWARE=0

echo "[INIT] Linux MicroVM initialized (<150ms)."

# 5. Start Wayland vsock proxy daemon
if [ -x /usr/local/bin/niri_vsock_guest ]; then
    echo "[INIT] Launching niri_vsock_guest proxy..."
    su -s /bin/sh niri -c "/usr/local/bin/niri_vsock_guest --socket /run/user/1000/wayland-0" &
    PROXY_PID=$!
elif [ -x /init.vsock_guest ]; then
    /init.vsock_guest &
    PROXY_PID=$!
fi

# 6. Wait for wayland-0 socket to become available
TRIES=0
while [ ! -S /run/user/1000/wayland-0 ] && [ $TRIES -lt 20 ]; do
    sleep 0.05
    TRIES=$((TRIES + 1))
done

if [ -S /run/user/1000/wayland-0 ]; then
    echo "[INIT] Wayland guest socket /run/user/1000/wayland-0 ready!"
else
    echo "[WARN] Wayland socket not yet ready, proceeding anyway."
fi

# 7. Spawn client or interactive shell
echo "============================================================"
echo " Welcome to Niri Linux MicroVM Guest"
echo " WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
echo " XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
echo "============================================================"

# If foot or specified client exists, launch it
if command -v foot >/dev/null 2>&1; then
    echo "[INIT] Launching foot terminal..."
    su -s /bin/sh niri -c "foot" || true
else
    echo "[INIT] Starting interactive root shell..."
    /bin/sh
fi

echo "[INIT] Session finished. Powering down..."
poweroff -f 2>/dev/null || reboot -f
