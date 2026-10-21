# Niri for macOS with Hardware-Accelerated Linux MicroVM Pipeline

A native macOS port of the [Niri](https://github.com/niri-wm/niri) scrollable-tiling Wayland compositor running inside an AppKit/Metal container, coupled with an ultra-low-latency Linux MicroVM Wayland bridge (via Apple Virtualization.framework / libkrun / QEMU) delivering hardware-accelerated Linux GUI applications seamlessly to the macOS desktop.

## Architecture Overview

```
 ┌─────────────────────────────────────────────────────────────┐
 │                       macOS Host                            │
 │  ┌───────────────────────────────────────────────────────┐  │
 │  │      AppKit Window Container / CAMetalLayer           │  │
 │  │                                                       │  │
 │  │  ┌─────────────────────────────────────────────────┐  │  │
 │  │  │      Niri Scrollable-Tiling Compositor          │  │  │
 │  │  │             (Smithay + Winit/Metal)             │  │  │
 │  │  └────────────────────────┬────────────────────────┘  │  │
 │  │                           │                           │  │
 │  │             UNIX Wayland Socket Server                │  │
 │  │                           │                           │  │
 │  └───────────────────────────┼───────────────────────────┘  │
 │                              │                              │
 │             virtio-vsock / Shared Memory Bridge             │
 └──────────────────────────────┼──────────────────────────────┘
                                │
 ┌──────────────────────────────▼──────────────────────────────┐
 │                     Linux MicroVM                           │
 │     Apple Virtualization.framework / libkrun / QEMU         │
 │  ┌───────────────────────────────────────────────────────┐  │
 │  │ Wayland Proxy Client (/run/user/1000/wayland-0)       │  │
 │  │ virtio-gpu (virgl / Venus / MoltenVK / Mesa)          │  │
 │  │ Wayland Applications: foot, mpv, alacritty, browsers  │  │
 │  └───────────────────────────────────────────────────────┘  │
 └─────────────────────────────────────────────────────────────┘
```

## Features

- **Native AppKit / Metal Shell**: Runs as a first-class macOS window without X11 or XQuartz.
- **Scrollable Tiling WM**: Full Niri infinite horizontal ribbon workspace paradigm on macOS.
- **Hardware-Accelerated MicroVM**: Lightweight Linux guest kernel booted in milliseconds.
- **Seamless Window Bridging**: Linux Wayland client windows render directly as subsurfaces and columns inside the host Niri compositor.
- **Zero-Trust Multi-Agent Engineering**: Managed autonomously by a multi-agent engineering swarm following strict Triple-Gate review protocols.

## Agent Operations Workspace

See [`agents/`](agents/) for live sprint dashboards, architecture RFCs, role instructions, and review records:
- **Operations Dashboard**: [`agents/README.md`](agents/README.md)
- **Sprint Manifest & Sync**: [`agents/orchestrator.md`](agents/orchestrator.md)
- **Inter-Agent Protocols**: [`agents/protocol.md`](agents/protocol.md)
- **Architecture Specifications**: [`agents/specs/`](agents/specs/)

## License

GPL-3.0-or-later (aligned with upstream Niri).
