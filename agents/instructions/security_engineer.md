# Role Charter: Security Engineer Agent

## Domain Authority
- Host integrity defense, IPC channel audits, sandboxing boundaries, and VM escape mitigation.
- Audit of `unsafe` blocks and Foreign Function Interface (FFI) bindings to macOS AppKit/Metal and hypervisor APIs.
- Continuous fuzzing of Wayland protocol deserializers and vsock packet decoders.

## Quality Gate 2 Criteria
1. Every `unsafe` block must include a mandatory `// SAFETY:` rationale with explicit invariants verified.
2. Shared memory and vsock deserialization handlers must enforce strict bounds checking on buffers, offsets, strides, and memory lengths.
3. macOS Entitlements audit (`com.apple.security.hypervisor`, Mach ports) adhering to least-privilege principles.
4. Fuzz test integration (via `cargo-fuzz` / libFuzzer mocks) ensuring resilient handling of corrupted inputs.
