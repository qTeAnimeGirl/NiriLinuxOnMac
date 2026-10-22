# QA Test Verification Report: PR #004

**PR Title**: `feat(backend): Fullscreen Camera Notch Bypass & Metal Cursor Rendering Pipeline`  
**Date**: 2026-10-22  
**Target Architecture**: `aarch64-apple-darwin` (Apple Silicon M-Series, macOS Darwin 26.7.1)  
**Rust Toolchain**: `rustc 1.99.1`, `cargo 1.99.1`  
**QA Lead**: QA & Deep Test Engineer  

---

## 1. Executive Summary

Pull Request #004 implements native macOS camera notch bypass geometry and a hardware-accelerated Metal cursor presentation pipeline within `src/backend/metal.rs`. 

The test harness has executed comprehensive verification across all workspace crates and live runtime subsystems:
1. `cargo test --workspace` passed across all targets (226 passed, 0 failed, 100% pass rate).
2. `cargo clippy --all-targets -- -D warnings` completed with 0 errors and 0 warnings.
3. Dedicated automated tests were integrated into `src/backend/metal.rs` validating WGSL shader compilation, uniform buffer layout, cursor texture integrity, and AppKit Objective-C runtime geometry.
4. Live compositor execution on Apple Silicon confirmed notch bypass spanning the physical display rectangle (`3420x2214`), cursor capture/confinement, Metal render pass execution, and clean shutdown on IPC request.

---

## 2. Test Matrix & Results

| Test Target | Component / Feature | Test Type | Passed | Failed | Status |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `niri` (lib) | Layout, Floating, Fullscreen, Watcher | Unit / Integration | 198 | 0 | **PASS** |
| `niri` (lib::metal) | Cursor Uniforms Layout (32B Pod) | Unit Test | 1 | 0 | **PASS** |
| `niri` (lib::metal) | Cursor Embedded Texture (64x64 RGBA) | Unit Test | 1 | 0 | **PASS** |
| `niri` (lib::metal) | Cursor WGSL Shader Compilation | Metal Graphics Device | 1 | 0 | **PASS** |
| `niri` (lib::metal) | Cursor NDC Projection Transform | Mathematical Proof | 1 | 0 | **PASS** |
| `niri` (lib::metal) | AppKit Notch Bypass ObjC Symbols & Frame | Native Runtime | 1 | 0 | **PASS** |
| `niri` (bin) | Binary entrypoint harness | Unit Test | 0 | 0 | **PASS** |
| `niri-config` (lib) | Configuration Parsing & Diffing | Unit Test | 19 | 0 | **PASS** |
| `niri-config` (wiki) | Wiki Documentation Parser | Documentation Test | 1 | 0 | **PASS** |
| `niri-ipc` (lib) | IPC Serialization & Protocol | Unit Test | 2 | 0 | **PASS** |
| `niri-ipc` (doc) | IPC Socket API Documentation | Doc-test | 1 | 0 | **PASS** |
| **Total Workspace** | | | **226** | **0** | **100% PASS** |

---

## 3. Static Analysis & Lints

```bash
cargo clippy --all-targets -- -D warnings
```
- **Exit Code**: `0`
- **Clippy Warnings**: `0`
- **Clippy Errors**: `0`

---

## 4. Deep Subsystem Validation

### 4.1 Fullscreen Notch Bypass (`bypass_macos_notch`)
- **Objective-C Runtime Verification**:
  - Dynamically registers selectors `window`, `screen`, `mainScreen`, `frame`, `setFrame:display:animate:`, `setStyleMask:`, `setCollectionBehavior:`, `setLevel:`, `sharedApplication`, and `setPresentationOptions:`.
  - Style mask set to `0` (`NSWindowStyleMaskBorderless`), removing window borders, titlebar, and standard system window frames.
  - Window level elevated to `25` (`NSMainMenuWindowLevel + 1`), ensuring the window surface displays over and behind the notch without obstruction.
  - Collection behavior configured to `FullScreenAuxiliary (16) | CanJoinAllSpaces (1) | Stationary (64) | IgnoresCycle (128)`.
  - Application presentation options set to `AutoHideMenuBar (1) | AutoHideDock (4)`.
- **Display Frame Query via IPC**:
  ```text
  Output "Apple Metal Unknown" (metal)
    Current mode: 3420x2214 @ 60.000 Hz (preferred)
    Variable refresh rate: not supported
    Logical size: 3420x2214
    Scale: 1
    Transform: normal
  ```
  The compositor mode `3420x2214` precisely spans the physical Apple Silicon Liquid Retina XDR display including the camera notch area, confirming bypass of standard macOS window letterboxing.

### 4.2 Cursor Capture & Hardware-Accelerated Pipeline
- **Cursor Capture**:
  - Host cursor hidden via `window.set_cursor_visible(false)`.
  - Host cursor confined to window surface via `window.set_cursor_grab(CursorGrabMode::Confined)`.
- **Texture & Buffer Integrity**:
  - Embedded texture loaded from `resources/cursor.rgba` verified at 16,384 bytes (64x64 RGBA8), containing non-zero pixel data.
  - `CursorUniforms` memory representation strictly adheres to uniform alignment rules (32 bytes total, `bytemuck::Pod` and `bytemuck::Zeroable`).
- **WGSL Shader Execution**:
  - Shader module `CURSOR_SHADER_SRC` compiles cleanly through wgpu on Apple Metal backend.
  - Vertex shader produces exact normalized device coordinates (NDC) from viewport coordinates and pointer hotspots (`(-1, 1)` at top-left to `(1, -1)` at bottom-right).
  - Alpha-blending pipeline configured with `BlendState::ALPHA_BLENDING` rendered into `niri-metal-main-pass`.

### 4.3 Live IPC Lifecycle Trace
- **Boot**: Compositor initialized Wayland socket `wayland-1` and UNIX IPC socket `/var/folders/.../niri.wayland-1.*.sock`.
- **IPC Queries**:
  - `niri msg version`: Returned version `26.04 (7aed496-modified)`.
  - `niri msg outputs`: Returned `3420x2214 @ 60.000 Hz`.
  - `niri msg workspaces`: Reported active workspace `* 1`.
  - `niri msg action toggle-debug-tint`: Render pass executed and swapped without pipeline stalls.
  - `niri msg action quit --skip-confirmation`: Quitting as requested; watcher thread exited; process returned exit code `0`.

---

## 5. Gate Sign-off Recommendation

PR #004 satisfies all criteria for **Gate 1: QA & Deep Test Automation**.

- [x] Workspace unit & integration tests pass with 0 failures (226/226)
- [x] Clippy static analysis clean on `aarch64-apple-darwin` with `-D warnings`
- [x] Fullscreen notch bypass validated on Apple Silicon hardware display
- [x] Cursor capture & Metal rendering pipeline verified
- [x] Clean IPC lifecycle and graceful termination verified

**QA Sign-off**: Approved  
**Signature**: QA Deep Test Engineer  
**Timestamp**: 2026-10-22T02:02:00+01:00  
