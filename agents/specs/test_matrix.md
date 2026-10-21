# Integration and Unit Test Matrix

## 1. Test Categories & Edge Cases

| ID | Suite | Target | Test Description | Success Criteria |
|---|---|---|---|---|
| TM-01 | Unit | Platform Decoupling | Verify compilation on `aarch64-apple-darwin` without Linux system headers | `cargo check --target aarch64-apple-darwin` exits 0 |
| TM-02 | Unit | Headless Compositor | Initialize Smithay headless backend and create virtual output | Headless output initialized with specified virtual resolution |
| TM-03 | Unit | Event Translation | Translate synthetic macOS keyboard and pointer events to Smithay events | Correct keycode, modifier, and coordinate mapping |
| TM-04 | Integration | Mock Client Presentation | Synthetic Wayland client binds `wl_compositor`, creates surface, commits shm buffer | Surface attached to Niri column; render pass accounts for client rect |
| TM-05 | Integration | Window Resize Stress | Rapidly oscillate container window dimensions (e.g., 800x600 -> 3840x2160) | Zero panics, memory stable, Metal swapchain updates dynamically |
| TM-06 | Security | vsock IPC Fuzzing | Stream random and malformed Wayland wire-protocol bytes to vsock socket | Connection cleanly terminated or protocol error emitted without host panic |
| TM-07 | Security | Buffer Bounds Check | Transmit `wl_shm` pool and buffer with out-of-range offset/stride/dimensions | Rejected with protocol error before any memory dereference |
| TM-08 | Performance | Frame Latency Profile | Measure frame submission interval at 60 Hz and 120 Hz targets | P99 frame presentation jitter < 2.0ms |
| TM-09 | E2E | MicroVM Wayland Boot | Boot microVM, start guest Wayland client, present to host window | Guest client receives configure events and delivers rendered frames |
