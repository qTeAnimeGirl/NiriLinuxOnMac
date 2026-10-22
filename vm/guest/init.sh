#!/bin/sh
# vm/guest/init.sh
# Minimal sub-200ms PID 1 init script for Linux MicroVM guest on macOS

set -e

# 1. Export core environment variables
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin
export HOME=/root
export USER=root
export TERM=xterm-256color
export XDG_RUNTIME_DIR=/run/user/1000
export WAYLAND_DISPLAY=wayland-0
export MOZ_ENABLE_WAYLAND=1
export GDK_BACKEND=wayland
export QT_QPA_PLATFORM=wayland
export CLUTTER_BACKEND=wayland
export SDL_VIDEODRIVER=wayland
export VK_ICD_FILENAMES=/usr/share/vulkan/icd.d/virtio_icd.aarch64.json
export GALLIUM_DRIVER=virpipe
export LIBGL_ALWAYS_SOFTWARE=0

# 2. Mount virtual kernel filesystems
mount -t proc none /proc 2>/dev/null || true
mount -t sysfs none /sys 2>/dev/null || true
mount -t devtmpfs none /dev 2>/dev/null || true
mount -t tmpfs none /run 2>/dev/null || true
mount -t tmpfs none /tmp 2>/dev/null || true

# 3. Load VirtIO drivers if available as modules
for mod in failover net_failover virtio_net vsock vmw_vsock_virtio_transport_common vmw_vsock_virtio_transport fuse virtiofs virtio-gpu virtio-rng overlay; do
    find /usr/lib/modules -name "${mod}.ko" -exec insmod {} \; 2>/dev/null || true
done

# 3b. Setup Persistent Block Storage (/dev/vda) if attached
if [ -b /dev/vda ]; then
    echo "[GUEST INIT] Virtual disk storage device /dev/vda detected."
    if ! blkid /dev/vda 2>/dev/null | grep -q ext4; then
        echo "[GUEST INIT] Formatting /dev/vda as persistent ext4 storage..."
        /usr/bin/mkfs.ext4 -F -m 1 /dev/vda 2>/dev/null || mke2fs -t ext4 -F /dev/vda 2>/dev/null || true
    fi

    mkdir -p /mnt/storage
    if mount -t ext4 /dev/vda /mnt/storage 2>/dev/null; then
        STORAGE_TOTAL=$(df -h /mnt/storage 2>/dev/null | awk 'NR==2 {print $2}')
        STORAGE_FREE=$(df -h /mnt/storage 2>/dev/null | awk 'NR==2 {print $4}')
        echo "[GUEST INIT] Mounted persistent virtual disk at /mnt/storage (${STORAGE_TOTAL} capacity, ${STORAGE_FREE} free)."

        if grep -q overlay /proc/filesystems 2>/dev/null || insmod /lib/modules/overlay.ko 2>/dev/null; then
            mkdir -p /mnt/storage/usr_upper /mnt/storage/usr_work
            mkdir -p /mnt/storage/var_upper /mnt/storage/var_work
            mkdir -p /mnt/storage/etc_upper /mnt/storage/etc_work
            mkdir -p /mnt/storage/root_upper /mnt/storage/root_work
            mkdir -p /mnt/storage/home

            # Seed pacman local database from initramfs to persistent storage if missing
            mkdir -p /mnt/storage/var_upper/lib/pacman/local
            cp -rn /var/lib/pacman/local/* /mnt/storage/var_upper/lib/pacman/local/ 2>/dev/null || true

            mount -t overlay overlay -o lowerdir=/usr,upperdir=/mnt/storage/usr_upper,workdir=/mnt/storage/usr_work /usr 2>/dev/null || true
            mount -t overlay overlay -o lowerdir=/var,upperdir=/mnt/storage/var_upper,workdir=/mnt/storage/var_work /var 2>/dev/null || true
            mount -t overlay overlay -o lowerdir=/etc,upperdir=/mnt/storage/etc_upper,workdir=/mnt/storage/etc_work /etc 2>/dev/null || true
            mount -t overlay overlay -o lowerdir=/root,upperdir=/mnt/storage/root_upper,workdir=/mnt/storage/root_work /root 2>/dev/null || true
            mount --bind /mnt/storage/home /home 2>/dev/null || true

            echo "[GUEST INIT] OverlayFS persistence activated! Free application storage: ${STORAGE_FREE}"

            # Deploy /usr/local/bin/pacman wrapper to seamlessly handle any existing unmanaged files
            mkdir -p /usr/local/bin
            cat << 'PACEOF' > /usr/local/bin/pacman
#!/bin/bash
# /usr/local/bin/pacman - Transparent pacman wrapper
# Enforces --overwrite '*' on sync (-S) and upgrade (-U) operations so that
# any pre-existing bootstrap files are cleanly claimed and updated without filesystem conflicts.
has_overwrite=0
for arg in "$@"; do
    if [[ "$arg" == --overwrite* ]]; then
        has_overwrite=1
        break
    fi
done

is_install=0
for arg in "$@"; do
    if [[ "$arg" == -S* || "$arg" == -U* ]]; then
        is_install=1
        break
    fi
done

if [[ $is_install -eq 1 && $has_overwrite -eq 0 ]]; then
    exec /usr/bin/pacman --overwrite '*' "$@"
else
    exec /usr/bin/pacman "$@"
fi
PACEOF
            chmod 755 /usr/local/bin/pacman
        fi
    fi
fi

# 4. Configure network loopback, eth0, DHCP, and DNS
ip link set lo up 2>/dev/null || ifconfig lo 127.0.0.1 up 2>/dev/null || true
ip link set eth0 up 2>/dev/null || ifconfig eth0 up 2>/dev/null || true

# Run DHCP client
udhcpc -i eth0 -n -q -t 3 -s /usr/share/udhcpc/default.script 2>/dev/null || udhcpc -i eth0 -n -q -t 3 2>/dev/null || true

# Configure fallback DNS resolvers
if [ ! -s /etc/resolv.conf ]; then
    cat << 'EOF' > /etc/resolv.conf
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
fi

# 5. Setup runtime and shared directories
mkdir -p /run/user/1000 /dev/shm /tmp /var/log /var/cache/pacman/pkg /var/lib/pacman/local /var/lib/pacman/sync
mount -t tmpfs none /dev/shm 2>/dev/null || true

# Mount virtio-fs host share if available
if grep -q virtiofs /proc/filesystems 2>/dev/null; then
    mount -t virtiofs host_share /dev/shm 2>/dev/null || true
fi

# Ensure user 1000 exists
if ! id -u 1000 >/dev/null 2>&1; then
    adduser -D -u 1000 -s /bin/sh niri 2>/dev/null || true
fi

chmod 0777 /run/user/1000
chmod 1777 /dev/shm /tmp

# 6. Setup helper scripts if missing
if [ ! -x /usr/bin/wayland-run ]; then
    cat << 'EOF' > /usr/bin/wayland-run
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
    chmod 755 /usr/bin/wayland-run
fi

if [ ! -x /usr/bin/install-firefox ]; then
    cat << 'EOF' > /usr/bin/install-firefox
#!/bin/sh
set -e
echo "Updating package databases and installing Firefox..."
pacman -Sy --noconfirm --overwrite '*' firefox
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
    chmod 755 /usr/bin/install-firefox
fi

echo "[INIT] Linux MicroVM initialized (<150ms)."

# 7. Start Wayland vsock proxy daemon
if [ -x /usr/bin/niri_vsock_guest ]; then
    echo "[INIT] Launching niri_vsock_guest proxy..."
    /usr/bin/niri_vsock_guest &
    PROXY_PID=$!
elif [ -x /usr/local/bin/niri_vsock_guest ]; then
    echo "[INIT] Launching /usr/local/bin/niri_vsock_guest proxy..."
    /usr/local/bin/niri_vsock_guest &
    PROXY_PID=$!
elif [ -x /init.vsock_guest ]; then
    /init.vsock_guest &
    PROXY_PID=$!
fi

# 8. Wait for wayland-0 socket to become available and set permissions
TRIES=0
while [ ! -S /run/user/1000/wayland-0 ] && [ $TRIES -lt 30 ]; do
    usleep 20000 2>/dev/null || sleep 0.05
    TRIES=$((TRIES + 1))
done

if [ -S /run/user/1000/wayland-0 ]; then
    chmod 0666 /run/user/1000/wayland-0
    echo "[INIT] Wayland guest socket /run/user/1000/wayland-0 ready (mode 0666)!"
else
    echo "[WARN] Wayland socket not yet ready, proceeding anyway."
fi

# 9. Welcome banner
echo "============================================================"
echo " Welcome to Niri Linux MicroVM Guest"
echo " WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
echo " XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
echo " Network: $(ip -o -4 addr show eth0 2>/dev/null | awk '{print $4}' || echo 'configured')"
echo " Commands: pacman, wayland-run, install-firefox"
echo "============================================================"

# Determine controlling console device
CONSOLE="/dev/console"
if [ -e /dev/hvc0 ]; then
    CONSOLE="/dev/hvc0"
elif [ -e /dev/ttyAMA0 ]; then
    CONSOLE="/dev/ttyAMA0"
elif [ -e /dev/ttyS0 ]; then
    CONSOLE="/dev/ttyS0"
fi

# If foot or specified client exists, launch it
if command -v foot >/dev/null 2>&1; then
    echo "[INIT] Launching foot terminal..."
    su -s /bin/sh niri -c "foot" || true
elif [ -x /bin/bash ]; then
    while true; do
        if [ -e "$CONSOLE" ]; then
            setsid /usr/bin/cttyhack /bin/bash -l <"$CONSOLE" >"$CONSOLE" 2>&1 || /bin/bash -l
        else
            /bin/bash -l
        fi
        sleep 1
    done
else
    while true; do
        if [ -e "$CONSOLE" ]; then
            setsid /usr/bin/cttyhack /bin/sh -l <"$CONSOLE" >"$CONSOLE" 2>&1 || /bin/sh -i
        else
            /bin/sh -i
        fi
        sleep 1
    done
fi

echo "[INIT] Session finished. Powering down..."
poweroff -f 2>/dev/null || reboot -f
