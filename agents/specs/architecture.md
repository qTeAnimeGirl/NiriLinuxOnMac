# Architecture Specification: Niri for macOS with MicroVM Pipeline

## 1. System Overview

The objective is to execute the Niri scrollable-tiling compositor natively on macOS (`aarch64-apple-darwin`), displaying its workspace inside a native AppKit window rendered via Apple Metal, while hosting an ultra-fast Linux MicroVM that transparently runs Linux Wayland client applications.

```mermaid
graph TD
    subgraph macOS Host
        subgraph AppKit Window / Shell
            NSWindow[AppKit NSWindow] --> CAMetalLayer[CAMetalLayer Viewport]
            NSEventQueue[macOS NSEvent Queue] --> EventBridge[Event Bridge / Winit Adapter]
        end

        subgraph Niri Compositor
            Calloop[Calloop Event Loop / CFRunLoop]
            SmithayCompositor[Smithay Wayland Core]
            LayoutEngine[Niri Scrollable Tiling Columns]
            WgpuMetalRenderer[wgpu / Metal Renderer]
        end

        subgraph Host IPC Server
            WaylandSocket[UNIX Wayland Socket Server]
            VsockBridge[virtio-vsock Host Bridge Server]
        end

        EventBridge --> Calloop
        Calloop --> SmithayCompositor
        SmithayCompositor --> LayoutEngine
        LayoutEngine --> WgpuMetalRenderer
        WgpuMetalRenderer --> CAMetalLayer
        WaylandSocket --> SmithayCompositor
        VsockBridge --> SmithayCompositor
    end

    subgraph Hypervisor Boundary
        Hypervisor[Apple Virtualization.framework / QEMU / libkrun]
    end

    subgraph Linux MicroVM Guest
        GuestKernel[Lightweight Linux Kernel]
        WaylandGuestSocket[/run/user/1000/wayland-0 Proxy]
        VirtioVsockGuest[virtio-vsock Guest Driver]
        VirtioGpu[virtio-gpu / Mesa]
        WaylandClients[Linux Wayland Clients: foot, mpv, etc.]

        WaylandClients --> WaylandGuestSocket
        WaylandGuestSocket --> VirtioVsockGuest
        VirtioVsockGuest --> VsockBridge
        VirtioGpu --> Hypervisor
    end
```

## 2. Component Breakdown

### 2.1 Host AppKit / Metal Runtime
- **Window Shell**: A native macOS window managed via AppKit or Winit, hosting a `CAMetalLayer`.
- **Render Engine**: Leverages `wgpu` with the Metal backend (`wgpu::Backends::METAL`), presenting frame textures directly into the swapchain.
- **Event Loop Integration**: Smithay uses `calloop`. On macOS, `calloop` integrates with the macOS run loop or executes on the main thread via timer/socket polling hooks.

### 2.2 Wayland Compositor Core
- Decoupled from Linux DRM/GBM/udev.
- Manages Wayland client surfaces, inputs, cursor states, and the horizontal column layout mechanism characteristic of Niri.
- Implements `wl_compositor`, `xdg_shell`, `wl_shm`, `linux_dmabuf` (adapted for host shared textures or shm fallback).

### 2.3 MicroVM & virtio-vsock Wayland Bridge
- Spawns a minimal Linux VM via `Virtualization.framework` (or QEMU/libkrun).
- Forwarding: The guest's `/run/user/1000/wayland-0` socket forwards raw Wayland wire-protocol bytes through `virtio-vsock` (port 1024) to the host Niri compositor.
- Shared Buffers: Frame buffers created by guest clients are passed either via `wl_shm` chunks over vsock or via shared-memory memory-mapped regions, presented directly into Niri subsurfaces.
