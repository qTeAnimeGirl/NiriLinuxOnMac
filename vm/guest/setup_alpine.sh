#!/bin/sh
# vm/guest/setup_alpine.sh
# Prepares an Alpine Linux rootfs environment with Wayland and Mesa Venus Vulkan libraries.

set -e

echo "=== Installing Alpine Wayland and Graphics Stack ==="
apk update
apk add --no-cache \
    musl \
    libxkbcommon \
    wayland-libs-client \
    wayland-libs-cursor \
    mesa-vulkan-virtio \
    mesa-dri-gallium \
    vulkan-loader \
    foot \
    vulkan-tools \
    strace \
    busybox

echo "=== Compiling niri_vsock_guest ==="
gcc -O2 -Wall -Wextra -pthread /tmp/niri_vsock_guest.c -o /usr/local/bin/niri_vsock_guest
chmod +x /usr/local/bin/niri_vsock_guest

echo "=== Setup Completed Successfully ==="
