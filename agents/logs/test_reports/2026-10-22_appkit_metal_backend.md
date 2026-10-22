# Test Report: Native AppKit Window Hosting & Metal/wgpu Pipeline
**Date**: 2026-10-22  
**Target Architecture**: `aarch64-apple-darwin` (Apple Silicon M-Series)  
**Branch**: `agent/smithay/appkit-metal-backend`  

---

## 1. Executive Summary

Milestone 2 has verified the complete end-to-end execution of Niri inside a native AppKit window container displaying an Apple Metal hardware-accelerated canvas via `wgpu::Backends::METAL`. The Calloop event loop pumps Winit/AppKit events seamlessly, the compositor binds Wayland and IPC UNIX sockets, and the live instance was verified via IPC message queries (`version`, `outputs`, `workspaces`, `action toggle-debug-tint`, and graceful `action quit`).

---

## 2. Test Execution Trace

### 2.1 Workspace Unit Test Suite
Command: `cargo test --workspace`
- `niri`: 198 passed, 0 failed
- `niri-config`: 19 passed, 0 failed
- `niri-ipc`: 2 passed, 0 failed
- `wiki-parses`: 1 passed, 0 failed
- Doc-tests: 1 passed, 0 failed
- **Total**: 221 passed, 0 failed (100% pass rate)

### 2.2 Live Compositor Boot & IPC Verification
```text
2026-10-22T00:37:54.220574Z  INFO niri: Set default macOS XDG_RUNTIME_DIR to /var/folders/b9/m4743yns00vf4xvv6j7fr_xh0000gn/T/niri-runtime-501
2026-10-22T00:37:54.223561Z  INFO niri: starting version 26.04 (17526e4-modified)
2026-10-22T00:37:54.383758Z DEBUG niri_config: loaded config from "/Users/qteanimegirl/Library/Application Support/niri/config.kdl"
2026-10-22T00:37:54.486999Z DEBUG niri::niri: putting output metal at x=0 y=0
2026-10-22T00:37:54.487395Z  INFO niri: listening on Wayland socket: wayland-1
2026-10-22T00:37:54.487404Z  INFO niri: IPC listening on: /var/folders/b9/m4743yns00vf4xvv6j7fr_xh0000gn/T/niri.wayland-1.13866.sock
```

### 2.3 IPC Query Trace
- **`niri msg version`**:
  ```text
  Compositor version: 26.04 (17526e4-modified)
  CLI version:        26.04 (17526e4-modified)
  ```
- **`niri msg outputs`**:
  ```text
  Output "Apple Metal Unknown" (metal)
    Current mode: 2560x1600 @ 60.000 Hz (preferred)
    Variable refresh rate: not supported
    Physical size: unknown
    Logical position: 0, 0
    Logical size: 2560x1600
    Scale: 1
    Transform: normal
    Available modes:
      2560x1600@60.000 (current, custom, preferred)
  ```
- **`niri msg workspaces`**:
  ```text
  Output "metal":
   * 1
  ```
- **`niri msg action toggle-debug-tint`**: Handled and rendered with exit code 0.
- **`niri msg action quit --skip-confirmation`**:
  ```text
  2026-10-22T00:38:03.043238Z  INFO niri::input: quitting as requested
  2026-10-22T00:38:03.044905Z DEBUG niri::utils::watcher: exiting watcher thread
  Process exited cleanly with code 0.
  ```

---

## 3. Static Analysis & Clippy
Command: `cargo clippy --all-targets -- -D warnings`
- Exit Code: `0`
- Diagnostics: 0 warnings, 0 errors across all workspace members.
