# Swarm Operations Dashboard

## Current Sprint: Milestone 1 & 2 Bootstrap
**Focus**: Platform Decoupling, Headless macOS Compilation, and AppKit/Metal Host Pipeline.

### Task Board

| Task ID | Description | Assignee | Status | Target Gate |
|---|---|---|---|---|
| M1-T1 | Decouple Linux subsystems (DRM, GBM, libinput, seatd) behind `#[cfg(target_os = "linux")]` | Rust/Smithay Engineer | In Progress | Gate 1 (QA) |
| M1-T2 | Implement mock/headless backend abstraction for `aarch64-apple-darwin` | Rust/Smithay Engineer | Queued | Gate 1 (QA) |
| M1-T3 | Headless integration test harness & CI headless target build | QA Deep Test Engineer | Queued | Gate 1 (QA) |
| M2-T1 | AppKit window container + CAMetalLayer swapchain integration | Rust/Smithay Engineer | Queued | Gate 1 (QA) |
| M3-T1 | Wayland UNIX domain socket forwarding to Smithay Calloop loop | VM & Graphics Engineer | Queued | Gate 2 (Sec) |
| M4-T1 | MicroVM runner (Virtualization.framework / QEMU) + virtio-vsock tunnel | VM & Graphics Engineer | Queued | Gate 2 (Sec) |

---

### Pull Request & Gate Sign-off Matrix

| PR # | Branch | Title | QA Gate | Security Gate | Code Review Gate | Status |
|---|---|---|---|---|---|---|
| #1 | `agent/arch/repo-init` | Phase 0/1: Scaffold Swarm Architecture & Repo Topology | ✅ PASS | ✅ PASS | ✅ APPROVED | MERGED to `dev` |

---

### Swarm Roster
- **Lead Architect**: Top-level system design, crate decoupling, task manifest, release authority.
- **Rust / Smithay Engineer**: Host macOS AppKit/Metal port, Smithay backend abstraction, Calloop integration.
- **VM & Graphics Engineer**: Linux guest runtime, virtio-gpu, vsock Wayland tunnel, shared memory.
- **QA & Deep Test Engineer**: Dual-loop TDD, synthetic event injection, frame capture, benchmarks.
- **Security Engineer**: VM escape auditing, IPC fuzzer, memory safety, entitlements inspection.
- **Code Reviewer**: Rust idioms, clippy -D warnings, zero hot-path allocation, lock contention.
- **DevOps & Release Engineer**: Toolchain standardization, guest rootfs caching, CI workflow automation.
