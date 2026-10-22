# Gate 2 Security Audit & Threat Boundary Sign-off: PR #006

**PR Title**: `feat(arch): Clean Arch Linux ARM MicroVM, In-App Interactive Terminal, Windowed Testing, & Single-Workspace Fullscreen Scoping`  
**Branch**: `agent/arch/arch-vm-gui-terminal` -> `dev`  
**Auditor**: Security Engineer for Niri on macOS (`aarch64-apple-darwin`)  
**Audit Date**: 2026-10-22  

---

## 1. Audit Scope & Threat Surface Review
1. **Interactive Console & PTY Stdio Bridge (`vm/host/microvm_launcher.swift` & `MicroVMManager.swift`)**:
   - Verified that commands sent from the host GUI into the guest serial console cannot execute code on the host outside the hypervisor boundary.
   - Verified stdin pipe lifecycle: pipe is bounded, writes are handled via standard Foundation `FileHandle`, and file descriptors are closed upon process termination.
   - Verified that guest terminal output does not trigger terminal escape sequence injection or arbitrary command execution on the host.
2. **AppKit Window & Workspace Scoping (`src/backend/metal.rs`)**:
   - Inspected removal of `CanJoinAllSpaces` and `Stationary`. Window level reduced from floating `25` to standard `0` (`NSNormalWindowLevel`), preventing window overlay attacks and ensuring normal macOS window management.
3. **Runtime Directory Hardening (`src/main.rs`)**:
   - Both default and custom `XDG_RUNTIME_DIR` are enforced with POSIX permissions `0700` (`rwx------`) owned by the calling UID. Prevents other unprivileged local users from reading or spoofing Wayland and IPC UNIX domain sockets.
4. **Arch Linux ARM Asset Bootstrapping (`vm/scripts/install_arch_assets.sh`)**:
   - Downloads from verified Arch Linux ARM official mirrors.
   - Extracts rootfs in isolated staging directory (`mktemp -d`) with automatic trap cleanup.
   - Guest init script drops permissions and isolates sockets in `/run/user/1000`.

---

## 2. Gate 2 Checklist
- [x] Hypervisor isolation maintained; guest console cannot compromise host memory.
- [x] Process execution is immune to command injection.
- [x] Sockets and runtime directories strictly restricted to `0700` POSIX permissions.
- [x] Window level and collection behaviors conform to standard macOS security boundaries.
- [x] Codesigning verified on `dist/Niri.app` with least-privilege entitlements (`com.apple.security.virtualization`, `com.apple.security.hypervisor`).

**Security Sign-off**: Gate 2 Approved by Security Engineer (2026-10-22).
