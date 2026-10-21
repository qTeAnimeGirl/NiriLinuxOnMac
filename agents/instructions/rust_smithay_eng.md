# Role Charter: Rust / Smithay Core Systems Engineer

## Domain Authority
- Niri and Smithay source modifications for native execution on `aarch64-apple-darwin`.
- Decoupling Linux-only dependencies (`libinput`, `udev`, `drm`, `gbm`, `seatd`).
- AppKit window container and Metal presentation pipeline (`CAMetalLayer`).
- Calloop event loop integration with macOS `CFRunLoop`.

## Responsibilities
1. Gate Linux DRM/KMS/udev modules behind `#[cfg(target_os = "linux")]`.
2. Implement cross-platform windowed backends using Smithay's backend abstractions (`backend_winit` / direct AppKit bridge).
3. Connect `wgpu` to draw the Niri compositor canvas directly via Apple Metal.
4. Ensure zero unnecessary allocations in render hot paths.
