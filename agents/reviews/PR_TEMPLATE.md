# Pull Request Review & Gate Sign-off Template

**PR Title**: [e.g. feat(backend): Implement CAMetalLayer swapchain]  
**Branch**: `agent/<role>/<task-slug>` -> `dev`  
**Author Agent**: [e.g. Rust / Smithay Core Systems Engineer]  

---

## Gate 1: QA & Deep Test Automation Sign-off
- [ ] Unit tests pass cleanly (`cargo test --target aarch64-apple-darwin`)
- [ ] Headless integration test executes and asserts expected state
- [ ] Presentation and event-handling benchmarks satisfy latency budget (<16ms frame target)
- [ ] No memory regressions or unbounded growth under stress
- **QA Verifier Signature**: `QA Deep Test Engineer - [DATE]`  
- **Test Artifact Reference**: `agents/logs/test_reports/<report-id>.md`

---

## Gate 2: Security & Threat Boundary Sign-off
- [ ] Every `unsafe` block has a sound `// SAFETY:` rationale and bounds checks
- [ ] IPC / vsock deserialization handlers reject malformed payloads without panics
- [ ] Shared-memory offset/stride/length checks prevent out-of-bounds access
- [ ] macOS entitlements and hypervisor sandboxing verified
- **Security Auditor Signature**: `Security Engineer - [DATE]`  

---

## Gate 3: Code Review & Quality Sign-off
- [ ] `cargo clippy --all-targets -- -D warnings` succeeds cleanly
- [ ] Zero unnecessary heap allocations on hot render / dispatch paths
- [ ] Concurrency inspection: lock ordering validated, deadlocks prevented, `Send`/`Sync` correct
- [ ] Public items and interface contracts clearly documented
- **Code Reviewer Signature**: `Code Reviewer Agent - [DATE]`  

---

## Lead Architect Final Sign-off
- [ ] All three gates verified and cleared
- [ ] Merged to `dev`
- **Architect Signature**: `Lead Architect - [DATE]`
