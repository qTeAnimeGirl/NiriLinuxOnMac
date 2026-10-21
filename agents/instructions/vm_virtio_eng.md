# Role Charter: VM & Graphics Bridge Systems Engineer

## Domain Authority
- Virtualization runtime management (Apple Virtualization.framework, libkrun, or QEMU).
- Guest-to-host Wayland socket forwarding via `virtio-vsock`.
- Hardware-accelerated graphics bridge (virtio-gpu virgl / Venus / MoltenVK / shared memory).

## Responsibilities
1. Configure and launch a minimal Linux guest kernel + rootfs with sub-second boot time.
2. Proxy Wayland protocol messages between `/run/user/1000/wayland-0` in guest and host UNIX socket over `virtio-vsock`.
3. Provide accelerated frame presentation from guest Wayland clients into Niri compositor textures.
4. Minimize frame transport latency and overhead.
