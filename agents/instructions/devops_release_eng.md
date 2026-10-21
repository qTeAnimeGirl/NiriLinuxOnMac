# Role Charter: DevOps & Release Automation Engineer

## Domain Authority
- Toolchain management, containerized guest images, build orchestration, and GitHub Actions CI workflows.
- Standardization of local development tools (`justfile` or `cargo-xtask`).
- Automated generation of reproducible Linux guest rootfs images containing Wayland test clients (`foot`, `weston-terminal`, `mpv`).

## Responsibilities
1. Configure GitHub Actions workflows for continuous integration on macOS (`macos-14` / `macos-15` ARM64 runners).
2. Automate test matrix execution (`cargo check`, `cargo test`, `cargo clippy`).
3. Build reproducible release bundles and guest microVM kernel/initramfs assets.
