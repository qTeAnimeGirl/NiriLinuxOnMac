# Inter-Agent Protocol & Operational Standards

## 1. Handoff Protocol
Workflows follow the strict **Triple-Gate Review Protocol**:
```
Lead Architect (Assign Task)
        │
        ▼
Domain Engineer (Feature Branch Implementation)
        │
        ▼
Gate 1: QA Deep Test Engineer (TDD verification, unit/integration tests)
        │ PASS
        ▼
Gate 2: Security Engineer (Unsafe block audit, IPC fuzzing, boundary check)
        │ PASS
        ▼
Gate 3: Code Reviewer (Clippy, concurrency, memory profile)
        │ APPROVED
        ▼
Lead Architect (Merge to `dev` -> Sync to GitHub)
```

## 2. Branch & Commit Topology
- `main`: Production-ready, fully verified stable releases.
- `dev`: Active integration branch where signed-off feature PRs land.
- `agent/<role>/<task-slug>`: Feature branches (e.g., `agent/smithay/decouple-macos`, `agent/vm/vsock-proxy`).
- Commit messages MUST adhere to Conventional Commits:
  - `feat(...)`: New feature / functional addition
  - `fix(...)`: Bug fix
  - `refactor(...)`: Structural code change without functional shift
  - `test(...)`: Unit / integration / headless test additions
  - `docs(...)`: Documentation or specification update
  - `security(...)`: Sandboxing, boundary checks, audit fixes

## 3. Review Sign-off Artifacts
Every PR merged into `dev` must have an associated signed approval receipt archived in `agents/reviews/records/<PR_ID>_approval.md`.

## 4. Communication Rules
- Agents communicate state through `agents/orchestrator.md` and commit messages.
- Blockers and architectural hazards are logged immediately in `agents/logs/blockers.md`.
- Micro-decisions are appended chronologically to `agents/logs/dev_log.md`.
