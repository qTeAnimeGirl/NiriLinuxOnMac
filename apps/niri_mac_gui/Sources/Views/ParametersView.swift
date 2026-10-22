//
//  ParametersView.swift
//  Niri macOS GUI Launcher
//

import SwiftUI
import AppKit

public struct ParametersView: View {
    @ObservedObject var config: LauncherConfig

    public init(config: LauncherConfig) {
        self.config = config
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text("System & VM Parameters")
                        .font(.system(size: 24, weight: .bold))
                    Text("Fine-tune presentation, hardware acceleration, hypervisor resources, and guest execution.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                // MARK: - Screen & Display Section
                GroupBox(label: Label("Screen & Display", systemImage: "display").font(.headline)) {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle(isOn: $config.notchBypass) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Bypass macOS Camera Notch (Immersive Borderless Fullscreen)")
                                    .fontWeight(.medium)
                                Text("Directly expands Niri's AppKit window behind the MacBook camera notch across the full physical frame.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        .onChange(of: config.notchBypass) { _, val in
                            if val { config.isWindowed = false }
                        }

                        Toggle(isOn: $config.isWindowed) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Windowed Mode with System Window Titlebar")
                                    .fontWeight(.medium)
                                Text("Runs Niri inside a standard resizable macOS window instead of borderless fullscreen.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        .onChange(of: config.isWindowed) { _, val in
                            if val { config.notchBypass = false }
                        }

                        Divider()

                        HStack {
                            Text("Resolution Preset:")
                                .frame(width: 140, alignment: .leading)
                            Picker("", selection: $config.resolutionPreset) {
                                ForEach(LauncherConfig.resolutionPresets, id: \.self) { preset in
                                    Text(preset).tag(preset)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 320)
                        }

                        if config.resolutionPreset == "Custom" {
                            HStack(spacing: 16) {
                                Text("Custom Dimensions:")
                                    .frame(width: 140, alignment: .leading)
                                HStack {
                                    TextField("Width", value: $config.customWidth, formatter: NumberFormatter())
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 80)
                                    Text("x")
                                    TextField("Height", value: $config.customHeight, formatter: NumberFormatter())
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 80)
                                    Text("pixels")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        Toggle(isOn: $config.hideOsCursor) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Cursor Capture & Hardware Overlay")
                                    .fontWeight(.medium)
                                Text("Hides the macOS system cursor and draws Niri's hardware-accelerated Metal cursor on the compositor canvas.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                    .padding(12)
                }

                // MARK: - MicroVM Hardware Resources
                GroupBox(label: Label("MicroVM Hardware Resources", systemImage: "cpu").font(.headline)) {
                    VStack(alignment: .leading, spacing: 18) {
                        // vCPUs
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Virtual CPUs (vCPUs):")
                                Spacer()
                                Text("\(config.vCPUs) Cores")
                                    .font(.system(.body, design: .monospaced))
                                    .fontWeight(.bold)
                            }
                            Slider(
                                value: Binding(
                                    get: { Double(config.vCPUs) },
                                    set: { config.vCPUs = Int($0) }
                                ),
                                in: 1...Double(max(1, ProcessInfo.processInfo.processorCount)),
                                step: 1
                            )
                        }

                        // Memory
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Guest Memory (RAM):")
                                Spacer()
                                Text(String(format: "%.1f GB (%d MB)", Double(config.memoryMB) / 1024.0, config.memoryMB))
                                    .font(.system(.body, design: .monospaced))
                                    .fontWeight(.bold)
                            }
                            Slider(
                                value: Binding(
                                    get: { Double(config.memoryMB) },
                                    set: { config.memoryMB = Int($0) }
                                ),
                                in: 1024...32768,
                                step: 512
                            )
                        }

                        Divider()

                        // Kernel Path
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Linux Kernel Image (raw uncompressed ARM64 Image / vmlinuz):")
                                .font(.caption).foregroundColor(.secondary)
                            HStack {
                                TextField("Path to kernel Image", text: $config.kernelPath)
                                    .textFieldStyle(.roundedBorder)
                                Button("Browse...") {
                                    browseFile { path in config.kernelPath = path }
                                }
                            }
                        }

                        // Initrd Path
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Initial Ramdisk (initramfs.cpio.gz):")
                                .font(.caption).foregroundColor(.secondary)
                            HStack {
                                TextField("Path to initramfs", text: $config.initrdPath)
                                    .textFieldStyle(.roundedBorder)
                                Button("Browse...") {
                                    browseFile { path in config.initrdPath = path }
                                }
                            }
                        }

                        // Optional Disk Path
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Raw Root Disk Image (Optional):")
                                .font(.caption).foregroundColor(.secondary)
                            HStack {
                                TextField("Optional disk image path (e.g. rootfs.raw)", text: $config.diskPath)
                                    .textFieldStyle(.roundedBorder)
                                Button("Browse...") {
                                    browseFile { path in config.diskPath = path }
                                }
                            }
                        }
                    }
                    .padding(12)
                }

                // MARK: - Graphics & Acceleration
                GroupBox(label: Label("Graphics & Acceleration", systemImage: "sparkles").font(.headline)) {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle(isOn: $config.enableVirtioGpu) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("virtio-gpu Paravirtualized Graphics")
                                    .fontWeight(.medium)
                                Text("Exposes paravirtualized DRM scanout display and virtio-gpu acceleration device to the guest.")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .toggleStyle(.switch)

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Metal Graphics Acceleration Pipeline")
                                    .fontWeight(.medium)
                                Text("Hardware-accelerated CAMetalLayer presenting via Apple Silicon GPU with sub-1ms buffer swaps.")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Spacer()
                            Text("Metal 3 Active")
                                .font(.caption.bold())
                                .foregroundColor(.green)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.green.opacity(0.15))
                                .cornerRadius(6)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Shared Memory Directory (virtio-fs host share):")
                                .font(.caption).foregroundColor(.secondary)
                            HStack {
                                TextField("Shared Directory", text: $config.sharedMemPath)
                                    .textFieldStyle(.roundedBorder)
                                Button("Browse...") {
                                    browseFolder { path in config.sharedMemPath = path }
                                }
                            }
                        }
                    }
                    .padding(12)
                }

                // MARK: - Network & IPC
                GroupBox(label: Label("Network & IPC", systemImage: "network").font(.headline)) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("virtio-vsock Wayland Port:")
                                .frame(width: 180, alignment: .leading)
                            TextField("Port", value: $config.vsockPort, formatter: NumberFormatter())
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                            Text("(Default: 1024)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Wayland Socket Override (Optional):")
                                .font(.caption).foregroundColor(.secondary)
                            TextField("Leave empty to auto-discover socket from Niri runtime", text: $config.waylandSocketOverride)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .padding(12)
                }

                // MARK: - Guest Launch Command
                GroupBox(label: Label("Guest Startup Command", systemImage: "terminal").font(.headline)) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Linux Application Command to Launch Inside MicroVM:")
                            .font(.caption).foregroundColor(.secondary)
                        TextField("Command (e.g. /usr/local/bin/wayland_window or foot)", text: $config.startupCommand)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                    .padding(12)
                }

                // Bottom Buttons
                HStack(spacing: 16) {
                    Button("Save Configuration") {
                        config.saveSettings()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Auto-Discover Assets") {
                        config.autoDiscoverAssets()
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("Restore Defaults") {
                        config.notchBypass = true
                        config.isWindowed = false
                        config.resolutionPreset = "Fullscreen Borderless"
                        config.vCPUs = min(4, max(1, ProcessInfo.processInfo.processorCount))
                        config.memoryMB = 2048
                        config.enableVirtioGpu = true
                        config.sharedMemPath = "/tmp/niri-shm"
                        config.vsockPort = 1024
                        config.startupCommand = "/usr/local/bin/wayland_window"
                        config.saveSettings()
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
                .padding(.top, 8)
            }
            .padding(24)
        }
    }

    private func browseFile(completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            completion(url.path)
        }
    }

    private func browseFolder(completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            completion(url.path)
        }
    }
}
