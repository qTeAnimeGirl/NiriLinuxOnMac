# Active Blockers & Architectural Hazards

| Issue ID | Category | Description | Status | Mitigation / Strategy |
|---|---|---|---|---|
| BLK-001 | Dependency | Upstream Niri unconditionally imports Linux-only crates (`drm-ffi`, `libdisplay-info`, `input`, `smithay-drm-extras`) | Active | Feature-gate Linux DRM/input dependencies under `#[cfg(target_os = "linux")]` or create a decoupled macOS workspace member. |
| BLK-002 | Graphics | Smithay's default renderers target Linux DRM GBM/EGL/GLES; macOS requires Metal / wgpu | Active | Leverage Smithay's `winit` backend or integrate direct `wgpu` CAMetalLayer pipeline for compositor surface presentation. |
| BLK-003 | Hypervisor | Linux VM requires accelerated Wayland buffer sharing across hypervisor boundary | Active | Phase 1: virtio-vsock Wayland IPC + shared-memory/shm buffer transfer; Phase 2: virtio-gpu virgl / Venus over Metal. |
