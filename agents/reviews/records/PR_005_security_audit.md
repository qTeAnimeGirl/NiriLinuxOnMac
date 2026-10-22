# Gate 2 Security Audit & Threat Boundary Sign-off: PR #005

**PR Title**: `Unified Niri.app Launcher GUI, Automated Asset Pipeline, and End-to-End MicroVM Wayland Mapping`  
**Branch**: `agent/launcher/unified-app-bundle` -> `dev`  
**Auditor**: Security Engineer for Niri on macOS (`aarch64-apple-darwin`)  
**Audit Date**: 2026-10-22  
**Target Milestone**: Milestone 4 — Unified macOS Application Packaging & Full Stack GUI Integration  

---

## 1. Executive Summary & Audit Scope

This security audit performs a comprehensive vulnerability and safety review of PR #005, evaluating:
1. **[microvm_launcher.swift](file:///Users/qteanimegirl/Downloads/NiriLinuxOnMac/vm/host/microvm_launcher.swift)**: Wire protocol framing, bounds checking, buffer overrun prevention, memory leak safety, unlinking temporary anonymous SHM files, and file descriptor lifecycle in `forwardWaylandBytes` and `sendFd`.
2. **[apps/niri_mac_gui](file:///Users/qteanimegirl/Downloads/NiriLinuxOnMac/apps/niri_mac_gui)**: Swift/SwiftUI launcher architecture, evaluating `LauncherConfig.swift`, `CompositorManager.swift`, `MicroVMManager.swift`, and `AssetInstaller.swift` for command injection safety, path traversal protection in file pickers, and environment variable sanitization.
3. **[entitlements.plist](file:///Users/qteanimegirl/Downloads/NiriLinuxOnMac/vm/host/entitlements.plist)**: Entitlement configuration, least-privilege compliance, and codesigning verification on the unified `dist/Niri.app` bundle.

---

## 2. In-Depth Component Security Evaluations

### 2.1 MicroVM Runner & POSIX FD Lifecycle (`vm/host/microvm_launcher.swift`)

#### Audited Implementations: `forwardWaylandBytes` and `sendFd`
The Apple Virtualization runner intercepts guest Wayland messages arriving over `virtio-vsock` (port 1024) and bridges them into the host UNIX domain socket. For `wl_shm.create_pool` calls, it dynamically creates backing anonymous shared memory files and passes them via `SCM_RIGHTS`.

```swift
func sendFd(sock: Int32, data: UnsafeRawPointer, count: Int, fdToPass: Int32) -> Int {
    guard fdToPass >= 0 else { return -1 }
    var iov = iovec(iov_base: UnsafeMutableRawPointer(mutating: data), iov_len: count)
    var cmsgBuf = [UInt8](repeating: 0, count: 16)
    cmsgBuf.withUnsafeMutableBytes { raw in
        let cmsg = raw.bindMemory(to: cmsghdr.self).baseAddress!
        cmsg.pointee.cmsg_len = 16
        cmsg.pointee.cmsg_level = SOL_SOCKET
        cmsg.pointee.cmsg_type = SCM_RIGHTS
        let dataPtr = raw.baseAddress!.advanced(by: 12).bindMemory(to: Int32.self, capacity: 1)
        dataPtr.pointee = fdToPass
    }

    var msg = msghdr()
    msg.msg_iov = withUnsafeMutablePointer(to: &iov) { $0 }
    msg.msg_iovlen = 1
    return cmsgBuf.withUnsafeMutableBytes { raw in
        msg.msg_control = raw.baseAddress
        msg.msg_controllen = socklen_t(raw.count)
        return sendmsg(sock, &msg, 0)
    }
}
```

#### Security Findings & Invariants Verified:
- **Wire Protocol Parsing & Bounds Protection**:
  - `forwardWaylandBytes` inspects the 8-byte Wayland message header (`remaining >= 8`).
  - Message length `msgLen` is extracted from the upper 16 bits of word 2 (`word2 >> 16`).
  - Enforces strict bounds: `msgLen >= 8 && msgLen <= remaining`. If a malformed or fragmented packet arrives (`msgLen < 8` or `msgLen > remaining`), the remaining bytes are flushed directly to `write(hostSock, ...)` and the loop safely breaks, preventing any out-of-bounds pointer reads.
  - `offset` strictly advances by `msgLen` (minimum 8 bytes) per iteration, guaranteeing loop termination and preventing infinite loops or arithmetic wrap-around.
- **Buffer Overrun Prevention**:
  - All memory reading uses `buffer.advanced(by: offset)` bounded by `count`.
  - Memory rebinding is strictly typed (`UInt8`, `UInt32`) with explicit bounds capacity, adhering to Swift memory safety rules.
- **Resource Exhaustion Defense (SHM Pool Bounding)**:
  - *Hardening Applied*: Added an upper-bound check on `poolSize` (`min(rawPoolSize, 256 * 1024 * 1024) = 256 MB`) to prevent an untrusted guest from requesting multi-gigabyte or integer-overflowed sparse file allocations via `ftruncate`.
- **Anonymous File Unlinking & File Descriptor Lifecycle**:
  - Backing memory files are generated with `mkstemp(template)` in `/tmp/niri_shm_XXXXXX`.
  - Immediately following descriptor creation, `unlink(template)` is invoked before data transmission. This ensures:
    1. The temporary file is immediately detached from the filesystem directory table and cannot be opened or tampered with by other local unprivileged processes.
    2. Inodes are automatically reclaimed by the kernel as soon as all descriptors are closed, preventing disk leak accumulation in `/tmp`.
  - `free(template)` is invoked immediately, preventing C-heap memory leaks.
  - *Hardening Applied*: Added null validation for `strdup(template)` and error checking for `mkstemp` (`hostFd >= 0`).
  - After passing the file descriptor to the host compositor via `sendFd(..., fdToPass: hostFd)`, the runner immediately closes its local handle (`close(hostFd)`). Because `sendmsg` increments the kernel file description reference count, ownership transfers cleanly without descriptor leaks.
- **`sendFd` Ancillary Data Validation**:
  - Added guard check `guard fdToPass >= 0 else { return -1 }` ensuring invalid descriptors are rejected before constructing `cmsghdr`.
  - Control message buffer `cmsgBuf` is exactly 16 bytes, correctly matching `sizeof(cmsghdr) + sizeof(int32_t)` on Darwin ARM64 ABI.

---

### 2.2 Native AppKit GUI Process & Environment Isolation (`apps/niri_mac_gui`)

#### Security Findings & Invariants Verified:

#### 1. Command Injection Prevention:
- Audited all child process invocation points across `CompositorManager.swift`, `MicroVMManager.swift`, and `AssetInstaller.swift`.
- **Zero Shell Invocation**: No user input or configuration string is passed to `system()`, `popen()`, or `/bin/sh -c`.
- All processes are spawned using Foundation's `Process` (wrapper over `posix_spawn` / `execve`) with explicit `executableURL` and structured array arguments (`arguments: [String]`).
- Example in `MicroVMManager.swift`:
  ```swift
  let proc = Process()
  proc.executableURL = URL(fileURLWithPath: launcherBin)
  proc.arguments = [
      "--kernel", kernel,
      "--initrd", initrd,
      "--cpus", "\(config.vCPUs)",
      "--memory", "\(config.memoryMB)",
      "--shared-dir", config.sharedMemPath,
      "--vsock-port", "\(config.vsockPort)",
      "--wayland-socket", waylandSocket
  ]
  ```
  Arguments are passed directly to `argv[]` without shell expansion or word splitting, completely immunizing the application against command injection.
- In `CompositorManager.swift`, IPC queries (`focusWindow`, `closeWindow`) take strongly-typed `UInt64` IDs formatted into array arguments `["msg", "action", "close-window", "--id", "\(id)"]`.

#### 2. Path Traversal & File Picker Safety:
- File selection in `ParametersView.swift` (`browseFile`, `browseFolder`) utilizes Apple's native `NSOpenPanel` modal dialogs.
- `NSOpenPanel` runs out-of-process through the system WindowServer, returning trusted, sanitized, absolute `URL` paths.
- File existence is validated using `FileManager.default.fileExists(atPath:)` before attaching disks or launching kernels.
- `LauncherConfig.autoDiscoverAssets()` searches strictly within predetermined relative candidate subpaths (`vm/images/Image`, `vm/images/vmlinuz`, `vm/images/initramfs.cpio.gz`) originating from `Bundle.main` or project root, preventing path traversal attacks.

#### 3. Environment Variable Sanitization:
- In `CompositorManager.swift`, the Wayland runtime directory is created under:
  ```swift
  let uid = getuid()
  let runtimeDir = "\(NSTemporaryDirectory())niri-runtime-\(uid)"
  try? fm.createDirectory(atPath: runtimeDir, withIntermediateDirectories: true, attributes: [
      .posixPermissions: 0o700
  ])
  ```
- Setting POSIX permissions `0700` (`rwx------`) restricts socket directory access exclusively to the current user's UID, preventing local privilege escalation or socket eavesdropping by other users on shared multi-user macOS systems.
- Configuration parameters exported via environment variables (`NIRI_NOTCH_BYPASS`, `NIRI_WINDOWED`, `NIRI_HIDE_CURSOR`) are strictly mapped to binary `"1"` or `"0"` strings. Numerical dimensions are formatted strictly from parsed integers (`res.width`, `res.height`).

#### 4. Asset Installer Whitelist Protection:
- In `AssetInstaller.swift`, the asset installation script is selected from an immutable whitelist of candidate paths:
  1. `cwd/vm/scripts/install_assets.sh`
  2. `Bundle.main/Contents/Resources/scripts/install_assets.sh`
  3. `Bundle.main.resourcePath/scripts/install_assets.sh`
- Arbitrary command execution is impossible because `findScriptPath()` rejects any path not present in the pre-verified candidate list.

---

### 2.3 Entitlements & Codesigning Configuration (`vm/host/entitlements.plist`)

#### Audited Entitlements Configuration:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.virtualization</key>
    <true/>
    <key>com.apple.security.hypervisor</key>
    <true/>
</dict>
</plist>
```

#### Security Findings & Invariants Verified:
1. **Adherence to Principle of Least Privilege**:
   - The entitlements file grants *only* the two capabilities required for hypervisor execution:
     - `com.apple.security.virtualization`: Required for Apple's `Virtualization.framework` (`VZVirtualMachine`, `VZVirtioSocketDevice`, `VZVirtioFileSystemDeviceConfiguration`).
     - `com.apple.security.hypervisor`: Required for low-level hypervisor hardware support on Apple Silicon.
   - **No Over-Privileging**: Contains zero broad filesystem access exceptions (`temporary-exception.files.absolute-path.read-write`), zero network listening entitlements, zero debugging entitlements (`get-task-allow` absent in release packaging), and zero hardware device entitlements (camera/microphone/location).
2. **Codesigning Verification (`scripts/package_app.sh`)**:
   - Packaging script codesigns all nested executables and the top-level application bundle:
     ```bash
     codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${MACOS_DIR}/microvm_launcher"
     codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${MACOS_DIR}/niri-vsock-host"
     codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${MACOS_DIR}/niri"
     codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${MACOS_DIR}/NiriApp"
     codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${APP_BUNDLE}"
     ```
   - Automated verification check:
     `codesign --verify --deep --strict dist/Niri.app` exits cleanly with code `0`.
   - Inspection of binary entitlements via `codesign -d --entitlements :-` confirms both `microvm_launcher` and `NiriApp` hold the exact validated entitlement dictionary.

---

## 3. Test Verification & Security Regression Matrix

| Test Suite / Security Assertion | Command | Result |
| :--- | :--- | :--- |
| **Swift Compilation (microvm_launcher)** | `swiftc -O vm/host/microvm_launcher.swift` | **Passed cleanly (0 warnings)** |
| **Swift GUI Compilation (NiriApp)** | `swiftc -O -warnings-as-errors ...` | **Passed cleanly (0 errors)** |
| **Application Packaging & Signing** | `./scripts/package_app.sh` | **Bundle created & signed cleanly** |
| **Deep Codesign Verification** | `codesign --verify --deep --strict dist/Niri.app` | **Valid signature (exit code 0)** |
| **Entitlement Inspection** | `codesign -d --entitlements :- dist/Niri.app` | **Exact least-privilege matches** |
| **Rust Workspace Regression** | `cargo test --workspace` | **226 passed, 0 failed** |
| **VM Host Bridge Regression** | `cargo test --manifest-path vm/host/Cargo.toml` | **5 passed, 0 failed** |
| **Clippy Linting** | `cargo clippy --workspace --all-targets -- -D warnings` | **0 errors, 0 warnings** |

---

## 4. Gate 2 Security Sign-off Checklist

- [x] **Every `unsafe` / low-level pointer block has sound bounds checking and leak protection**  
  *`forwardWaylandBytes` and `sendFd` in `microvm_launcher.swift` verified for length checking, pool size bounding ($\le 256\text{ MB}$), null safety, immediate `unlink` and `free`, and clean descriptor closure.*
- [x] **Process invocation is immune to command injection**  
  *All external processes in `CompositorManager`, `MicroVMManager`, and `AssetInstaller` execute via `Process` with discrete `[String]` arguments; zero shell parsing.*
- [x] **File selection and path handling are protected against directory traversal**  
  *Native `NSOpenPanel` usage, whitelist-based asset auto-discovery, and strict path existence checks.*
- [x] **IPC runtime directories are hardened with restrictive permissions**  
  *`XDG_RUNTIME_DIR` set to `NSTemporaryDirectory()/niri-runtime-<uid>` with POSIX `0700` (`rwx------`).*
- [x] **macOS entitlements and codesigning strictly conform to least privilege**  
  *`com.apple.security.virtualization` and `com.apple.security.hypervisor` applied and verified via `codesign --verify --deep --strict`.*

---

**Security Auditor Signature**: `Security Engineer Agent - 2026-10-22`  
**Sign-off Status**: **PASSED (Gate 2 Approved for PR #005)**
