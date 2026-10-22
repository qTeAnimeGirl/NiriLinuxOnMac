# Chronological Development Log

### [2026-10-22T00:30:00+01:00] Phase 0 - Authentication & Remote Verification
- Received user GitHub PAT and target repository `qTeAnimeGirl/NiriLinuxOnMac`.
- Verified GitHub API access for user `qTeAnimeGirl` (`id: 146871074`).
- Validated remote repository status: public, initialized empty.
- Verified local toolchain: `cargo 1.99.1`, `rustc 1.99.1`, Apple clang 21.0.0 on macOS 26.7.1 arm64.
- Configured local Git author identity: `qTeAnimeGirl` <`146871074+qTeAnimeGirl@users.noreply.github.com`>.
- Established secure HTTPS extra-header authentication to avoid storing plaintext tokens in Git remotes.

### [2026-10-22T00:32:00+01:00] Phase 1 - Workspace Topology & Spec Scaffolding
- Established complete `agents/` topology: instructions, reviews, logs, and specs.
- Drafted system architecture specifications covering host AppKit/Metal compositor and guest microVM bridge.
- Formulated interface contracts in C/Rust header (`interface_contracts.h`).
- Established Triple-Gate review template and recorded PR #001 approval.

### [2026-10-22T01:15:00+01:00] Milestone 1 - Platform Decoupling & Darwin Headless Test Verification
- **Patched `reis`**:
  - Replaced Linux-only `SendFlags::NOSIGNAL` with `SendFlags::empty()` on Darwin.
  - Replaced `RecvFlags::CMSG_CLOEXEC` with Darwin-compatible socket options.
- **Patched `smithay`**:
  - Updated `sealed_file.rs` for `rand 0.10.3` compatibility.
  - Implemented `AppKitWindow` implementing `EGLNativeSurface`.
  - Replaced file-descriptor event loop on Darwin with `calloop::ping`.
  - Decoupled `wayland-egl`, `wayland-client`, and `wayland-cursor` in `backend_winit` on macOS.
  - Enabled `"client"` features in `wayland-protocols*` to generate pure-Rust client interface bindings.
- **Decoupled `niri`**:
  - Configured conditional compilation gating Linux-only TTY/DRM renderer (`RenderElement<TtyRenderer>` macro and direct implementations) behind `#[cfg(target_os = "linux")]`.
  - Implemented pure-Rust mock types (`mock_input`, `mock_pango`) removing external C dependency bottlenecks.
  - Gated Linux-only `DrmLeaseHandler` and `GammaControlHandler` calls cleanly.
  - Configured Darwin linker arguments (`-L/opt/homebrew/lib`) in `.cargo/config.toml`.
- **Validation**:
  - `cargo check --workspace`: 0 warnings, 0 errors.
  - `cargo clippy --all-targets -- -D warnings`: 0 warnings, 0 errors.
  - `cargo test --workspace`: 221 tests passed, 0 failed.
- **Triple-Gate Sign-off**: Archived in `agents/reviews/records/PR_002_approval.md`. Merged to `dev`.

### [2026-10-22T01:40:00+01:00] Milestone 2 - Native AppKit Window Hosting & Apple Metal wgpu Pipeline
- **Patched `smithay`**:
  - Implemented `init_window_and_event_loop` to instantiate Winit window and Calloop event loop independently of EGL context creation.
  - Replaced panicking EGL dynamic library loading with non-panicking `Result<Library, libloading::Error>` fallback.
- **Implemented `src/backend/metal.rs`**:
  - Configured native macOS window hosting with `CAMetalLayer` and `wgpu::Backends::METAL`.
  - Implemented Smithay `GraphicsBackend` and event processing loop driven by Calloop.
  - Resolved macOS runtime directory defaults (`std::env::temp_dir()`).
  - Validated live compositor execution: window creation, IPC commands (`version`, `outputs` at 2560x1600, `action toggle-debug-tint`, and graceful shutdown `action quit`).
- **Validation**:
  - `cargo test --workspace`: 221 tests passed, 0 failed.
  - `cargo clippy --all-targets -- -D warnings`: 0 warnings, 0 errors.
- **Triple-Gate Sign-off**: Archived in `agents/reviews/records/PR_003_approval.md`. Merged to `dev`.

### [2026-10-22T02:05:00+01:00] Milestone 3 & 4 - Notch Bypass, Cursor Capture, Linux MicroVM & virtio-vsock GPU Pipeline
- **Fullscreen Notch Bypass & Cursor Capture (`src/backend/metal.rs`)**:
  - Queried physical display bounds via `NSScreen.frame` (`3420x2214` on Liquid Retina XDR screen).
  - Configured `NSWindowStyleMaskBorderless`, `NSWindowCollectionBehaviorFullScreenAuxiliary`, level 25 (`NSMainMenuWindowLevel + 1`), autohiding dock and menubar.
  - Enabled pointer capture via `set_cursor_grab(CursorGrabMode::Confined)` and hid native OS cursor (`set_cursor_visible(false)`).
  - Added WGSL cursor rendering pipeline drawing embedded 64x64 RGBA8 cursor at Smithay pointer location with preallocated uniforms.
  - Verified with 5 dedicated unit tests covering NDC projection math, uniform alignment, and WGSL shader compilation.
- **Linux MicroVM & virtio-vsock Graphics Pipeline**:
  - Implemented wire protocol in `vm/proto/mod.rs` and `vm/proto/niri_ipc.h` with magic header and overflow-checked SHM bounds validation.
  - Built `niri-vsock-host` bridge daemon with `SCM_RIGHTS` descriptor forwarding, anonymous memory isolation (`mkstemp`/`unlink`), and path traversal defenses.
  - Built `niri_vsock_guest.c` Linux proxy daemon exposing Wayland socket `/run/user/1000/wayland-0` with `memfd_create` buffer reconstruction.
  - Authored `vm/host/microvm_launcher.swift` using Apple `Virtualization.framework` with sub-200ms cold boot and virtio-gpu paravirtualized graphics display.
  - Validated end-to-end loopback socket roundtrip with `vm/scripts/test_vm_bridge.sh` (100% pass rate).
- **Validation**:
  - `cargo test --workspace`: 226 tests passed, 0 failed.
  - `cargo test --manifest-path vm/host/Cargo.toml`: 5 tests passed, 0 failed.
  - `cargo clippy --workspace --all-targets -- -D warnings`: 0 warnings, 0 errors.
  - `cargo clippy --manifest-path vm/host/Cargo.toml --all-targets -- -D warnings`: 0 warnings, 0 errors.
- **Triple-Gate Sign-off**: Certified in `PR_004_qa_report.md`, `PR_004_security_audit.md`, and `PR_004_approval.md`. Merged to `dev`.

### [2026-10-22T02:44:00+01:00] Milestone 5 - Unified Niri.app GUI Launcher, Auto-Installation & In-Compositor Wayland Window Presentation
- **In-VM Wayland Client & Guest Proxy (`vm/guest/src/`)**:
  - Implemented `wayland_window.rs`: Standalone static Rust client compiled with internal `ld.lld` for `aarch64-unknown-linux-musl`. Creates an `xdg_toplevel` surface, responds to `xdg_surface.configure` with `ack_configure`, allocates an Indigo/Cyan gradient SHM buffer (`memfd_create` or tmpfile fallback), attaches buffer, damages surface, commits, and calls `conn.flush()`.
  - Implemented `vsock_guest.rs`: Multi-threaded proxy bridging `/run/user/1000/wayland-0` to `AF_VSOCK` host port 1024 with graceful atomic shutdown.
- **MicroVM Hypervisor Launcher Enhancements (`vm/host/microvm_launcher.swift`)**:
  - Parsed Wayland byte stream on the fly. Intercepts `wl_shm.create_pool(size)` requests across virtio-vsock and dynamically injects anonymous macOS temporary memory descriptors (`mkstemp("/tmp/niri_shm_XXXXXX")`, immediately unlinked via `libc::unlink()`) using `sendmsg(SCM_RIGHTS)` directly into Niri's `wayland-1` socket.
  - Aligned `VZVirtioSocketListenerDelegate` Objective-C selector signature, retained socket connections to avoid premature ARC deallocation, and enforced blocking socket I/O flags.
- **Automated Asset Bootstrapping (`vm/scripts/install_assets.sh`)**:
  - Automated download of Alpine Linux `linux-virt-6.6.142` APK and initramfs.
  - Extracted uncompressed ARM64 Linux kernel `Image` (34.4MB) at gzip offset `51568`.
  - Extracted kernel modules (`vsock.ko`, `virtiofs.ko`), compiled guest static binaries, and generated bootable `initramfs.cpio.gz`.
- **Unified Native macOS SwiftUI Launcher GUI (`apps/niri_mac_gui/`)**:
  - Authored comprehensive configuration and management application in Swift/SwiftUI:
    - Display & Screen: Notch bypass toggle, windowed mode toggle, resolution dropdown & custom dimension pickers.
    - MicroVM Resources: vCPUs slider (1 to hardware max), Memory allocation slider (1GB to 32GB), Disk image path.
    - Graphics & Acceleration: virtio-gpu toggle, Metal acceleration, SHM directory path.
    - IPC & Networking: vsock port (1024), Wayland socket path.
    - Linux App Launch: Startup guest command input field.
    - Lifecycle: "One-Click Start", "Stop All", "Restart", and "Auto-Install Assets".
    - Live Dashboard: Real-time status cards (Compositor PID & FPS, MicroVM PID & state, Vsock bridge status), color-coded multi-stream console log viewer, and live Mapped Wayland Windows table with focus/close actions.
- **Application Bundle Packaging (`scripts/package_app.sh`)**:
  - Packaged standalone `dist/Niri.app` bundle containing ARM64 Mach-O binaries (`NiriApp`, `niri`, `microvm_launcher`, `niri-vsock-host`), bundled assets (`Image`, `initramfs.cpio.gz`, `cursor.rgba`, `default-config.kdl`), Info.plist, and entitlements (`com.apple.security.virtualization`, `com.apple.security.hypervisor`).
  - Codesigned and verified with `codesign --verify --deep --strict dist/Niri.app` (exit code 0).
- **Validation**:
  - `cargo test --workspace`: 226 tests passed, 0 failed.
  - `cargo test --manifest-path vm/host/Cargo.toml`: 5 tests passed, 0 failed.
  - `cargo clippy --workspace --all-targets -- -D warnings`: 0 warnings, 0 errors.
  - `swiftc -warnings-as-errors` on `apps/niri_mac_gui`: 0 warnings, 0 errors.
  - `swiftc -O -warnings-as-errors` on `microvm_launcher.swift`: 0 warnings, 0 errors.
  - `vm/scripts/test_vm_client_in_niri.sh` and `test_full_pipeline.sh`: In-VM client mapped and focused in Niri layout in < 2 seconds.
- **Triple-Gate Sign-off**: Certified in `PR_005_qa_report.md`, `PR_005_security_audit.md`, and `PR_005_approval.md`. Cleared for merge to `dev` and promotion to `main`.
