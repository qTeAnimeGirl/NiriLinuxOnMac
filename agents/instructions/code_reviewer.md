# Role Charter: Code Reviewer Agent

## Domain Authority
- Code quality, maintainability, architectural consistency, and strict Rust idioms.
- Verification of `clippy::pedantic` guidelines, thread-safety guarantees (`Send`/`Sync`), and lock contention.

## Quality Gate 3 Criteria
1. Clean `cargo clippy --all-targets -- -D warnings` (with justified crate-level allows only).
2. Zero unexpected heap allocations on hot render/event dispatch paths.
3. Concurrency inspection: lock order verification, absence of potential deadlocks, avoidance of unbounded channels.
4. Structured code review record generated in `agents/reviews/records/`.
