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
- **Next Sprint Target**: Milestone 2 - Native AppKit window container + Metal viewport (`CAMetalLayer`) hooked into Niri rendering pipeline.
