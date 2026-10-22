# Gate 2 Security Audit & Threat Boundary Sign-off: PR #004

**PR Title**: `feat(vm): virtio-vsock Wayland IPC Bridge & Zero-Copy SHM Pipeline`  
**Branch**: `agent/vm-bridge/vsock-pipeline` -> `dev`  
**Auditor**: Security Engineer for Niri on macOS (`aarch64-apple-darwin`)  
**Audit Date**: 2026-10-22  
**Target Milestone**: Milestone 3 — Linux MicroVM Integration & GPU/SHM Acceleration  

---

## 1. Executive Summary & Audit Scope

This formal security audit evaluates the threat boundaries, memory safety invariants, and IPC attack surfaces introduced by the Linux MicroVM bridge and macOS presentation backend. 

### Audited Components
1. **[metal.rs](file:///Users/qteanimegirl/Downloads/NiriLinuxOnMac/src/backend/metal.rs)**: Objective-C runtime interop, `unsafe fn bypass_macos_notch`, selector registration, transmuted `objc_msgSend` signatures on ARM64, pointer validity, and memory leak analysis.
2. **[vm/proto/mod.rs](file:///Users/qteanimegirl/Downloads/NiriLinuxOnMac/vm/proto/mod.rs)** & **[vm/proto/niri_ipc.h](file:///Users/qteanimegirl/Downloads/NiriLinuxOnMac/vm/proto/niri_ipc.h)**: Wire protocol packet deserialization, magic constant verification, payload size bounding, and arithmetic overflow bounds validation (`niri_validate_shm_bounds`, `validate_shm_bounds`).
3. **[vm/host/src/main.rs](file:///Users/qteanimegirl/Downloads/NiriLinuxOnMac/vm/host/src/main.rs)**: Host vsock bridge daemon, `SCM_RIGHTS` ancillary file descriptor passing, path traversal defenses for `virtio-fs` shared memory, and descriptor lifetime management.
4. **[agents/specs/vm_pipeline.md](file:///Users/qteanimegirl/Downloads/NiriLinuxOnMac/agents/specs/vm_pipeline.md)**: MicroVM threat model, hypervisor isolation boundaries, guest-to-host privilege separation, and macOS entitlements.

---

## 2. In-Depth Component Security Evaluations

### 2.1 Objective-C Runtime Interop (`src/backend/metal.rs`)

#### Audited Implementation: `unsafe fn bypass_macos_notch`
The compositor directly interacts with AppKit through dynamic Objective-C runtime calls (`objc_msgSend`, `sel_registerName`, `objc_getClass`) to bypass macOS display notches and achieve uninhibited fullscreen presentation behind system elements.

```rust
// Key Transmuted Function Signatures Audited:
let msg_send_ptr: unsafe extern "C" fn(*mut c_void, *mut c_void) -> *mut c_void;
let msg_send_rect: unsafe extern "C" fn(*mut c_void, *mut c_void) -> NSRect;
let msg_send_void_usize: unsafe extern "C" fn(*mut c_void, *mut c_void, usize);
let msg_send_void_isize: unsafe extern "C" fn(*mut c_void, *mut c_void, isize);
let msg_send_void_rect_bool_bool: unsafe extern "C" fn(*mut c_void, *mut c_void, NSRect, bool, bool);
```

#### Security Findings & Invariants Verified:
- **Null Pointer Checks**: 
  - Verified defensive null check for `ns_view_ptr` at entry.
  - Verified cascading null checks for `window` (`[ns_view window]`), `screen` (`[window screen]`), and fallback to `[NSScreen mainScreen]`. If any step yields a null reference, the function terminates safely without dereferencing or panicking.
  - Verified `cls_screen` and `cls_app` null validation before invoking class selectors.
- **Selector Registration**:
  - All selectors (`window`, `screen`, `mainScreen`, `frame`, `setFrame:display:animate:`, `setStyleMask:`, `setCollectionBehavior:`, `setLevel:`, `sharedApplication`, `setPresentationOptions:`) are registered using `sel_registerName()` with static null-terminated C string literals (`c"..."`), guaranteeing valid memory and lifetime.
- **Apple Silicon ARM64 Calling Convention (AAPCS64)**:
  - On `aarch64-apple-darwin`, `NSRect` (`struct { x: f64, y: f64, width: f64, height: f64 }`) is classified as a **Homogeneous Floating-point Aggregate (HFA)** with 4 `double` members.
  - In Apple Darwin ARM64 ABI, HFAs with $\le 4$ members are passed and returned directly in vector/floating-point registers `d0`-`d3` (no `objc_msgSend_stret` exists on ARM64 macOS; standard `objc_msgSend` handles all returns).
  - Scalar arguments (`usize`, `isize`, `bool`) map accurately to 64-bit integer registers `x0`-`x3`, perfectly matching AppKit prototypes (`NSUInteger`, `NSInteger`, `BOOL`).
- **Memory Leak & Ownership Analysis**:
  - Methods invoked (`[NSView window]`, `[NSWindow screen]`, `+[NSScreen mainScreen]`, `+[NSApplication sharedApplication]`) return non-retaining or autoreleased references per Apple Cocoa memory management naming conventions (no `alloc`, `copy`, or `new`).
  - No heap allocations or unreleased references are leaked.
- **Thread Safety**:
  - AppKit UI mutations (`NSWindow`, `NSApplication`) are executed strictly on the main application thread during compositor startup in `Metal::new`.
- **Hardening Applied**:
  - Added explicit `/// # Safety` documentation specifying pointer validity and thread affinity preconditions.
  - Added `// SAFETY:` rationale comment at the invocation callsite in `Metal::new`.

---

### 2.2 Wire Protocol & SHM Bounds Checking (`vm/proto/mod.rs` & `vm/proto/niri_ipc.h`)

#### Audited Implementation: `niri_validate_shm_bounds` / `validate_shm_bounds`
Shared memory pools represent the primary zero-copy data transfer bridge from the untrusted Linux guest. If an attacker could craft arbitrary offset, height, or stride values, out-of-bounds reads or memory disclosure of host address space could occur.

```c
static inline int niri_validate_shm_bounds(uint64_t pool_size, uint32_t offset, int32_t height, int32_t stride) {
    if (height <= 0 || stride <= 0) {
        return -1;
    }
    uint64_t total_span;
    if (__builtin_mul_overflow((uint64_t)height, (uint64_t)stride, &total_span)) {
        return -1;
    }
    uint64_t required_size;
    if (__builtin_add_overflow((uint64_t)offset, total_span, &required_size)) {
        return -1;
    }
    if (required_size > pool_size) {
        return -1;
    }
    return 0;
}
```

#### Security Findings & Invariants Verified:
- **Integer Overflow Defenses**:
  - Negative and zero dimensions (`height <= 0 || stride <= 0`) are rejected immediately, preventing signed/unsigned confusion attacks.
  - Multiplication of `height * stride` uses compiler-checked arithmetic (`__builtin_mul_overflow` in C, `checked_mul` in Rust).
  - Addition of `offset + total_span` uses compiler-checked arithmetic (`__builtin_add_overflow` in C, `checked_add` in Rust).
  - Validated edge cases: `INT32_MAX * INT32_MAX`, `UINT32_MAX + span`, negative height/stride, and exact pool boundary fits.
- **Packet Magic Verification**:
  - Packet headers must match `NIRI_PROTOCOL_MAGIC = 0x4E495249` (`'NIRI'`). Unrecognized magic triggers instant connection drop without crashing the host bridge.
- **Protocol Versioning**:
  - Strict equality check for `NIRI_PROTOCOL_VERSION = 1`.
- **Payload Size Limiting (`NIRI_MAX_PAYLOAD_SIZE`)**:
  - Payloads are strictly bounded to 16 MB (`16 * 1024 * 1024`).
  - Validation occurs *before* memory buffer allocation, preventing guest-initiated heap exhaustion / OOM attacks on the macOS host.
- **Struct Representation & Alignment**:
  - `#[repr(C, packed)]` struct layout conforms to the C ABI in `niri_ipc.h`.
  - Deserialization safely validates fields by value copy before use, preventing unaligned pointer dereference UB.
  - Added explicit `// SAFETY:` rationale on `std::mem::transmute_copy` in Rust ABI bindings.

---

### 2.3 Host Bridge Hardening & File Descriptor Sanitization (`vm/host/src/main.rs`)

#### Security Findings & Remediations Applied:
1. **Remediated Use-After-Close / Premature Drop Hazard**:
   - *Vulnerability*: In `create_host_shm_fd`, opening a shared backing file previously returned `file.as_raw_fd()`. Because `File` was dropped at scope exit, the descriptor was closed, leaving the caller with a dangling or reused file descriptor.
   - *Fix*: Replaced `file.as_raw_fd()` with `file.into_raw_fd()`, transferring ownership cleanly to the caller without triggering `Drop`.
2. **Path Traversal Mitigation in virtio-fs**:
   - *Vulnerability*: Incoming `NIRI_MSG_SHM_POOL_CREATE` packets carrying a filename string could attempt directory traversal (e.g., `../../etc/passwd`).
   - *Fix*: Added strict path sanitization:
     1. Disallows paths containing `ParentDir` (`..`) components.
     2. Validates canonicalized paths using `canon_target.starts_with(canon_shared) && canon_target.is_file()`.
     3. Rejects non-regular files and symbolic links escaping the shared directory.
3. **Temporary Buffer Isolation**:
   - Anonymous SHM buffers created via `mkstemp()` are unlinked immediately via `libc::unlink()` before data writing, ensuring file entries remain invisible in the host filesystem and inaccessible to other processes.
4. **`SCM_RIGHTS` Memory Safety**:
   - `send_with_fd` and `recv_with_fd` buffers are aligned and sized using `CMSG_SPACE(sizeof(int))`.
   - All `unsafe` blocks now feature explicit `// SAFETY:` documentation.

---

### 2.4 Hypervisor Isolation & Threat Model (`agents/specs/vm_pipeline.md`)

#### Audited Specifications:
- **Trust Demarcation**:
  - The Linux MicroVM guest is explicitly designated as an **untrusted security domain**.
  - No direct host memory access or raw hardware registers are exposed to the guest.
  - Communication is strictly confined to `virtio-vsock` (ports 1024 and 1025) and shared directory `/tmp/niri-shm`.
- **macOS Entitlements Compliance**:
  - MicroVM runner execution requires the standard macOS hypervisor entitlement:
    ```xml
    <key>com.apple.security.hypervisor</key>
    <true/>
    ```
- **Guest Privilege Separation**:
  - The guest proxy daemon (`niri-vsock-guest`) executes under unprivileged UID 1000 without Linux `CAP_SYS_ADMIN`, mitigating guest-level privilege escalation.
- **Specification Documentation Updated**:
  - Enhanced Section 6 of `vm_pipeline.md` with explicit specifications for path traversal defense (Section 6.3), descriptor passing lifecycle (Section 6.4), and hypervisor entitlement constraints (Section 6.5).

---

## 3. Test Verification & Security Regression Matrix

| Test Suite / Security Assertion | Command | Result |
| :--- | :--- | :--- |
| **Rust Workspace Tests** (Niri core, layout, IPC) | `cargo test --workspace` | **226 passed, 0 failed** |
| **VM Host Bridge Tests** (magic, payload, bounds) | `cargo test --manifest-path vm/host/Cargo.toml` | **5 passed, 0 failed** |
| **C IPC Bounds Validation Suite** | `clang -Wall -Wextra -Werror test_ipc.c` | **All assertions passed** |
| **Workspace Clippy Linting** | `cargo clippy --workspace --all-targets -- -D warnings` | **0 errors, 0 warnings** |
| **VM Host Clippy Linting** | `cargo clippy --manifest-path vm/host/Cargo.toml -- -D warnings` | **0 errors, 0 warnings** |
| **Objective-C Symbol Resolution** | `backend::metal::tests::test_notch_bypass_objc_symbols` | **Passed** |
| **WGSL Shader Syntax Validation** | `backend::metal::tests::test_cursor_shader_wgsl_syntax` | **Passed** |

---

## 4. Gate 2 Security Sign-off

- [x] **Every `unsafe` block has a sound `// SAFETY:` rationale and bounds checks**  
  *Verified across `src/backend/metal.rs`, `vm/proto/mod.rs`, and `vm/host/src/main.rs`.*
- [x] **IPC / vsock deserialization handlers reject malformed payloads without panics**  
  *Magic constant mismatch, protocol version mismatch, and payloads $> 16\text{ MB}$ trigger clean disconnection.*
- [x] **Shared-memory offset/stride/length checks prevent out-of-bounds access**  
  *Strict overflow-checked arithmetic (`niri_validate_shm_bounds`) validated in both C and Rust implementations.*
- [x] **macOS entitlements and hypervisor sandboxing verified**  
  *Audited against `com.apple.security.hypervisor` requirements, virtio-fs path traversal defenses, and guest privilege separation.*

---

**Security Auditor Signature**: `Security Engineer Agent - 2026-10-22`  
**Sign-off Status**: **PASSED (Gate 2 Approved)**
