# Security Boundary & Threat Model

## 1. Trust Boundaries

```
[ Untrusted Linux MicroVM / Clients ]
               │
               ▼ (virtio-vsock / shared memory)
═════════════════════════════════════════════════════════ Hypervisor Isolation Boundary
               │
               ▼ (Checked IPC Deserializer)
[ Host Wayland Bridge Socket / Packet Validator ]
               │
               ▼
[ Niri Compositor Core (Memory-safe Rust) ]
               │
               ▼
[ macOS Metal Render Pipeline & Window Server ]
```

## 2. Threat Vectors & Mitigations

### 2.1 Malicious Guest Wayland Messages
- **Threat**: Malformed wire-protocol messages, invalid interface IDs, or oversized opcode payloads intended to trigger buffer overflows or memory corruption in host Smithay parser.
- **Mitigation**:
  - Wayland protocol messages are length-checked before buffer reads.
  - Object ID maps are isolated per-client.
  - Strict fuzz testing via `cargo-fuzz` against socket deserialization paths.

### 2.2 Shared Memory / Buffer Out-of-Bounds
- **Threat**: A guest client passes a `wl_shm` buffer whose `offset + height * stride` exceeds the shared pool size, attempting an out-of-bounds read or host memory disclosure.
- **Mitigation**:
  - Rigorous arithmetic bounds verification: `stride * height + offset <= pool_size` with checked integer arithmetic (`checked_mul`, `checked_add`).
  - Read-only mappings wherever client buffers are sampled into host Metal textures.

### 2.3 Hypervisor Escape
- **Threat**: Exploitation of hypervisor memory mapping or virtual device handling.
- **Mitigation**:
  - Run microVM under minimal required macOS entitlements (`com.apple.security.hypervisor`).
  - No access to host filesystem except explicitly configured read-only virtio-fs shares.
  - MicroVM process runs unprivileged with restricted sandbox profile.
