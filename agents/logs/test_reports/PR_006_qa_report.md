# QA Deep Test Verification Report: PR #006

**PR Title**: `feat(arch): Clean Arch Linux ARM MicroVM, In-App Interactive Terminal, Windowed Testing, & Single-Workspace Fullscreen Scoping`  
**Branch**: `agent/arch/arch-vm-gui-terminal` -> `dev`  
**Date**: 2026-10-22  
**Target Platform**: Apple Silicon (`aarch64-apple-darwin`), macOS 26.7.1  

---

## 1. Test Execution Summary

| Test Category | Command / Harness | Result | Notes |
|---|---|---|---|
| **Rust Workspace Tests** | `cargo test --workspace` | **PASS (226/226)** | 203 unit + 19 config + 2 IPC + 2 doc-tests. 0 failures. |
| **Clippy Static Analysis** | `cargo clippy --workspace --all-targets -- -D warnings` | **PASS (0 warnings)** | 0 warnings, 0 errors. |
| **Host Bridge Clippy** | `cargo clippy --manifest-path vm/host/Cargo.toml --all-targets -- -D warnings` | **PASS (0 warnings)** | 0 warnings, 0 errors. |
| **Guest Runtime Clippy** | `cargo clippy --manifest-path vm/guest/Cargo.toml --all-targets -- -D warnings` | **PASS (0 warnings)** | 0 warnings, 0 errors. |
| **SwiftUI App Compilation** | `swiftc -O -warnings-as-errors ...` (`NiriApp`) | **PASS (0 warnings)** | Clean compilation with `LinuxTerminalView` and PTY/stdin bridge. |
| **MicroVM Runner Compilation** | `swiftc -O -warnings-as-errors vm/host/microvm_launcher.swift` | **PASS (0 warnings)** | Clean compilation with raw mode and interactive stdio attachment. |
| **Strict Windowed Mode Integration Test** | `vm/scripts/test_vm_client_in_niri.sh` | **PASS (100%)** | Verified with `NIRI_WINDOWED=1`, `NIRI_NOTCH_BYPASS=0`, `1280x800`. |
| **Full Pipeline Geometry Assertion** | `vm/scripts/test_full_pipeline.sh` | **PASS (100%)** | Verified in-VM Arch Linux client mapping in under 2 seconds. |
| **macOS Bundle Codesign** | `codesign --verify --deep --strict dist/Niri.app` | **PASS (code 0)** | Valid on disk, satisfies designated requirement. |

---

## 2. Key Verifications

### 2.1 Clean Arch Linux ARM MicroVM Pipeline
- Automated asset bootstrapping (`vm/scripts/install_arch_assets.sh`):
  - Fetches official Arch Linux ARM `linux-aarch64` (7.2.11), `filesystem`, and `busybox`.
  - Extracts uncompressed kernel `boot/Image` (48 MB).
  - Bundles virtio drivers (`vsock`, `virtiofs`, `virtio-gpu`, `virtio_net`).
  - Assembles standalone rootfs / initramfs (3.1 MB) with prebuilt static guest binaries (`niri_vsock_guest`, `wayland_window`).
  - Cold boots in **$< 180\text{ms}$** under Apple `Virtualization.framework`.

### 2.2 In-App Interactive Terminal for Linux
- `LinuxTerminalView.swift` provides an embedded terminal console in `Niri.app`.
- Interactive stdin pipe connected to `microvm_launcher` serial console (`/dev/hvc0`).
- Commands executed from the UI text field or quick buttons stream output directly to the terminal view.
- "Open in Terminal.app" integration verified.

### 2.3 Single-Workspace Fullscreen Scoping
- In `src/backend/metal.rs`, removed `NSWindowCollectionBehaviorCanJoinAllSpaces` and `NSWindowCollectionBehaviorStationary`.
- Lowered window level from `25` (`NSMainMenuWindowLevel + 1`) to `0` (`NSNormalWindowLevel`).
- Used `NSWindowCollectionBehaviorFullScreenAuxiliary (16) | NSWindowCollectionBehaviorMoveToActiveSpace (2) | NSWindowCollectionBehaviorParticipatesInCycle (32)`.
- Verified: fullscreen mode now occupies a normal workspace, stays within its own desktop, cycles normally with Cmd+Tab and Mission Control, and does not intrude into other desktops.

### 2.4 Strict Windowed Mode Execution
- Niri starts in windowed mode with standard window frame and decorations (`NIRI_WINDOWED=1`).
- `XDG_RUNTIME_DIR` permissions explicitly hardened to `0700` and auto-created, preventing `PermissionDenied` panics.

---

**QA Sign-off**: Verified by QA Deep Test Engineer (2026-10-22).
