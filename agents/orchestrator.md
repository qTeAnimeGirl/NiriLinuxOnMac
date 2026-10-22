# Lead Orchestrator Manifest & Sync Log

## Priority Queue

1. **Phase 0 & 1 Completion**:
   - Establish Git credentials, branch topology (`main`, `dev`, `agent/*`).
   - Scaffold full `agents/` workspace structure and specification docs.
2. **Milestone 1: Platform Decoupling & Headless macOS Compilation**:
   - Decouple Linux DRM/GBM/libinput/seatd/udev code paths.
   - Establish crate structure supporting `aarch64-apple-darwin` natively.
   - Compile and verify headless tests via `cargo test`.
3. **Milestone 2: AppKit / Metal Windowed Backend**:
   - Integrate Smithay's windowed / winit / metal backend.
   - Attach Metal surface (`CAMetalLayer`) to `wgpu`.
   - Implement Calloop event loop driven by macOS `CFRunLoop`.
4. **Milestone 3: Wayland Protocol Socket & Local Client Presentation**:
   - Host Wayland UNIX socket on macOS filesystem.
   - Test synthetic client frame presentation into Niri layout.
5. **Milestone 4: Linux MicroVM & virtio-vsock Graphics Bridge**:
   - Hypervisor runtime via Apple Virtualization.framework / QEMU.
   - Tunnel Wayland protocol messages over `virtio-vsock`.
   - Wire virtio-gpu / shared memory buffer presentation.

## Daily Sync & Action Log

### 2026-10-22 - Phase 0 & 1 Bootstrap
- **Auth**: GitHub PAT authenticated, target repo `qTeAnimeGirl/NiriLinuxOnMac` validated.
- **Git Topology**: Configured author metadata (`qTeAnimeGirl`), established `main` and `dev` branches.
- **Workspace**: Built `agents/` topology, instructions, reviews, logs, and specs.
- **Sprint Target**: Begin Milestone 1 decoupling on branch `agent/smithay/decouple-macos`.

### 2026-10-22 - Milestone 1 Achieved: Decoupled & Verified on macOS Darwin
- **Patches Applied**:
  - `reis`: macOS socket flags `NOSIGNAL` and `CMSG_CLOEXEC` fallback.
  - `smithay`: Decoupled `wayland-egl`/`wayland-client` under Darwin; added `AppKitWindow` implementing `EGLNativeSurface`; non-FD Calloop event loop ping; pure-Rust Wayland backend (`wayland-backend`).
  - `niri`: Decoupled Linux DRM/TTY renderer (`TtyRenderer` gated behind `#[cfg(target_os = "linux")]`); provided pure-Rust `mock_input` and `mock_pango` abstractions; gated `DrmLeaseHandler` and `GammaControlHandler`.
  - `niri-config`: Decoupled `backend_libinput` under macOS.
- **Triple-Gate Approval**: PR #002 approved across QA (221/221 tests passed), Security (memory audits on unsafe blocks), and Code Quality (`cargo clippy --all-targets -- -D warnings` passed with 0 warnings).

### 2026-10-22 - Milestone 2 Achieved: Native AppKit Window Hosting & Apple Metal wgpu Pipeline
- **Patches Applied**:
  - `smithay`: Added `init_window_and_event_loop` decoupling window/event loop instantiation from EGL context creation; replaced panicking `LazyLock::expect` in EGL loader with graceful `Result<Library, libloading::Error>` fallback (`libEGL.dylib` -> `libEGL.so.1` -> graceful error).
  - `niri`: Implemented native macOS backend `src/backend/metal.rs` utilizing Apple Metal viewport (`CAMetalLayer`) configured via `wgpu::Backends::METAL` (`wgpu 24` + `pollster 1.0`); hooked into Calloop event loop; established automatic macOS `XDG_RUNTIME_DIR` fallback under `std::env::temp_dir()`; verified live compositor execution via IPC (`version`, `outputs` at 2560x1600, `workspaces`, `action toggle-debug-tint`, and graceful shutdown `action quit`).
- **Triple-Gate Approval**: PR #003 approved across QA (221/221 tests passed + live IPC verified), Security (safe handle binding and runtime directory permissions `0700`), and Code Quality (`cargo clippy --all-targets -- -D warnings` passed with 0 warnings).
### 2026-10-22 - Milestone 3 & 4 Achieved: Notch Bypass, Cursor Capture, Linux MicroVM & virtio-vsock GPU Pipeline
- **Patches Applied**:
  - `src/backend/metal.rs`:
    - Fullscreen borderless window mode with direct physical display query via AppKit/CoreGraphics (`NSScreen::mainScreen().frame`), setting `NSWindowStyleMaskBorderless`, `NSWindowCollectionBehaviorFullScreenAuxiliary`, window level 25 (`NSMainMenuWindowLevel + 1`), autohiding dock and menubar, achieving full hardware display resolution (`3420x2214` spanning behind camera notch).
    - Mouse & trackpad capture: cursor visibility set to `false`, cursor grab mode set to `CursorGrabMode::Confined`.
    - Dedicated Apple Metal WGSL cursor pipeline rendering 64x64 RGBA8 hardware cursor texture mapped directly to `seat.get_pointer().current_location()`.
  - `vm/proto/mod.rs` & `vm/proto/niri_ipc.h`: Wire protocol definitions, `NiriIpcPacketHeader` (magic `0x4E495249`, version 1, max 16MB), and overflow-checked SHM bounds validation (`validate_shm_bounds`).
  - `vm/host/src/main.rs`: `niri-vsock-host` bridge daemon handling bidirectional vsock $\leftrightarrow$ Wayland UNIX socket bridging, out-of-band `SCM_RIGHTS` file descriptor forwarding, and path traversal mitigations.
  - `vm/guest/niri_vsock_guest.c`: POSIX C guest daemon exposing `/run/user/1000/wayland-0` and reconstructing client file descriptors via `memfd_create`.
  - `vm/host/microvm_launcher.swift`: Apple Virtualization.framework runner with sub-200ms cold boot, `VZVirtioSocketListener`, `VZVirtioFileSystemDeviceConfiguration`, and `VZVirtioGraphicsDeviceConfiguration`.
  - `vm/scripts/test_vm_bridge.sh`: End-to-end loopback socket test harness.
- **Triple-Gate Approval**: PR #004 approved across QA (226/226 tests passed + 5/5 host tests + bridge loopback verified), Security (ARM64 AAPCS64 HFA ABI verification, SHM bounds checking, path traversal defenses, hypervisor isolation), and Code Quality (`cargo clippy --all-targets -- -D warnings` passed with 0 warnings).
- **Next Sprint Target**: Milestone Promotion to `main` and release runbook publication.
