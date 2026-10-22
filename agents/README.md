# Swarm Operations Dashboard

## Current Sprint: Milestone 5 Production Release
**Focus**: Unified `Niri.app` macOS GUI, Automated Asset Provisioning, and Live In-Compositor MicroVM Wayland Presentation.

### Task Board

| Task ID | Description | Assignee | Status | Target Gate |
|---|---|---|---|---|
| M1-T1 | Decouple Linux subsystems (DRM, GBM, libinput, seatd) behind `#[cfg(target_os = "linux")]` | Rust/Smithay Engineer | ✅ COMPLETED | Triple-Gate Cleared |
| M1-T2 | Implement mock/headless backend abstraction for `aarch64-apple-darwin` | Rust/Smithay Engineer | ✅ COMPLETED | Triple-Gate Cleared |
| M1-T3 | Headless integration test harness & Darwin target build (221/221 passed) | QA Deep Test Engineer | ✅ COMPLETED | Triple-Gate Cleared |
| M2-T1 | AppKit window container + CAMetalLayer swapchain integration | Rust/Smithay Engineer | ✅ COMPLETED | Triple-Gate Cleared |
| M3-T1 | macOS Notch Bypass & Native Confined Cursor Capture + Metal Pipeline | Rust/Smithay Engineer | ✅ COMPLETED | Triple-Gate Cleared |
| M4-T1 | MicroVM runner (Virtualization.framework / QEMU) + virtio-vsock tunnel & GPU bridge | VM & Graphics Engineer | ✅ COMPLETED | Triple-Gate Cleared |
| M5-T1 | In-VM Wayland client (`wayland_window.rs`) & guest proxy daemon (`vsock_guest.rs`) | VM & Graphics Engineer | ✅ COMPLETED | Triple-Gate Cleared |
| M5-T2 | Dynamic `wl_shm.create_pool` interception & host `sendmsg(SCM_RIGHTS)` FD passing | VM & Graphics Engineer | ✅ COMPLETED | Triple-Gate Cleared |
| M5-T3 | Automated Linux Kernel & initramfs asset installer (`vm/scripts/install_assets.sh`) | DevOps & Release Engineer | ✅ COMPLETED | Triple-Gate Cleared |
| M5-T4 | Native SwiftUI Configuration & Dashboard GUI (`apps/niri_mac_gui`) | Rust/Smithay Engineer | ✅ COMPLETED | Triple-Gate Cleared |
| M5-T5 | Turnkey Application Bundle packaging & codesign (`dist/Niri.app`) | DevOps & Release Engineer | ✅ COMPLETED | Triple-Gate Cleared |
| M5-T6 | End-to-end integration test automation (`test_vm_client_in_niri.sh`, `test_full_pipeline.sh`) | QA Deep Test Engineer | ✅ COMPLETED | Triple-Gate Cleared |

---

### Pull Request & Gate Sign-off Matrix

| PR # | Branch | Title | QA Gate | Security Gate | Code Review Gate | Status |
|---|---|---|---|---|---|---|
| #1 | `agent/arch/repo-init` | Phase 0/1: Scaffold Swarm Architecture & Repo Topology | ✅ PASS | ✅ PASS | ✅ APPROVED | MERGED to `dev` |
| #2 | `agent/smithay/decouple-macos` | Milestone 1: Platform Decoupling & Native macOS Darwin Compilation | ✅ PASS (221 tests) | ✅ PASS | ✅ APPROVED (clippy clean) | MERGED to `dev` |
| #3 | `agent/smithay/appkit-metal-backend` | Milestone 2: Native AppKit Window Hosting & Apple Metal wgpu Pipeline | ✅ PASS (221 tests + IPC) | ✅ PASS | ✅ APPROVED (clippy clean) | MERGED to `dev` |
| #4 | `agent/vm/virtio-pipeline` | Milestone 3 & 4: Linux MicroVM, virtio-vsock Wayland IPC, Notch Bypass & Cursor Presentation | ✅ PASS (226 tests + loopback) | ✅ PASS | ✅ APPROVED (clippy clean) | MERGED to `dev` |
| #5 | `agent/app/unified-gui-runner` | Milestone 5: Unified Niri.app Launcher GUI, Automated Asset Pipeline, and End-to-End MicroVM Wayland Mapping | ✅ PASS (226 tests + live pipeline) | ✅ PASS (Sandboxing, Entitlements, mkstemp/unlink) | ✅ APPROVED (Zero warnings Swift/Rust, codesigned) | MERGED to `dev` |
| #6 | `agent/arch/arch-vm-gui-terminal` | Milestone 6: Clean Arch Linux ARM MicroVM, In-App Terminal, Windowed Testing, & Single-Workspace Fullscreen | ✅ PASS (226 tests + windowed live) | ✅ PASS (Stdio sandbox, 0700 XDG, Level 0 space) | ✅ APPROVED (Zero warnings Swift/Rust, codesigned) | CLEARED for MERGE |

---

### Swarm Roster
- **Lead Architect**: Top-level system design, crate decoupling, task manifest, release authority.
- **Rust / Smithay Engineer**: Host macOS AppKit/Metal port, Smithay backend abstraction, Calloop integration.
- **VM & Graphics Engineer**: Linux guest runtime, virtio-gpu, vsock Wayland tunnel, shared memory.
- **QA & Deep Test Engineer**: Dual-loop TDD, synthetic event injection, frame capture, benchmarks.
- **Security Engineer**: VM escape auditing, IPC fuzzer, memory safety, entitlements inspection.
- **Code Reviewer**: Rust idioms, clippy -D warnings, zero hot-path allocation, lock contention.
- **DevOps & Release Engineer**: Toolchain standardization, guest rootfs caching, CI workflow automation.
