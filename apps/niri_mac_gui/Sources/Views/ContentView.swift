//
//  ContentView.swift
//  Niri macOS GUI Launcher
//

import SwiftUI

public enum NavigationTab: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case parameters = "Parameters"
    case terminal = "Linux Terminal"
    case logs = "Live Logs"
    case about = "Diagnostics & About"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.bottom.50percent"
        case .parameters: return "slider.horizontal.3"
        case .terminal: return "apple.terminal"
        case .logs: return "terminal"
        case .about: return "info.circle"
        }
    }
}

public struct ContentView: View {
    @ObservedObject var coordinator = AppCoordinator.shared
    @State private var selectedTab: NavigationTab = .dashboard

    public init() {}

    public var body: some View {
        NavigationSplitView {
            // MARK: - Sidebar
            VStack(alignment: .leading, spacing: 0) {
                // App Branding Header
                HStack(spacing: 10) {
                    Image(systemName: "circle.grid.3x3.fill")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Niri on macOS")
                            .font(.headline)
                            .fontWeight(.bold)
                        Text("Apple Silicon Port")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)

                Divider()

                // Navigation List
                List(NavigationTab.allCases, selection: $selectedTab) { tab in
                    NavigationLink(value: tab) {
                        Label(tab.rawValue, systemImage: tab.icon)
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .listStyle(.sidebar)

                Spacer()

                Divider()

                // Sidebar Bottom Status Badge
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Circle()
                            .fill(coordinator.isAllRunning ? Color.green : (coordinator.isAnyRunning ? Color.yellow : Color.secondary))
                            .frame(width: 8, height: 8)
                        Text(coordinator.isAllRunning ? "Operational" : (coordinator.isAnyRunning ? "Partial Run" : "Stopped"))
                            .font(.caption.bold())
                    }
                    if coordinator.isAllRunning {
                        Text("\(coordinator.compositor.windows.count) window(s) mapped")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else {
                        Text(coordinator.installer.statusMessage)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(14)
            }
            .frame(minWidth: 200, idealWidth: 220, maxWidth: 260)
        } detail: {
            // MARK: - Main Content Area
            Group {
                switch selectedTab {
                case .dashboard:
                    DashboardView(coordinator: coordinator)
                case .parameters:
                    ParametersView(config: coordinator.config)
                case .terminal:
                    LinuxTerminalView(microvm: coordinator.microvm)
                case .logs:
                    LogStreamView(logger: coordinator.logger)
                case .about:
                    AboutView()
                }
            }
            .frame(minWidth: 700, minHeight: 520)
        }
    }
}

// MARK: - Diagnostics & About View
public struct AboutView: View {
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("System Diagnostics & Architecture")
                        .font(.system(size: 24, weight: .bold))
                    Text("Niri Scrollable-Tiling Wayland Compositor running natively on Apple Silicon.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Divider()

                GroupBox(label: Label("Host Environment", systemImage: "macmini").font(.headline)) {
                    VStack(alignment: .leading, spacing: 10) {
                        InfoRow(key: "Host Architecture", value: "aarch64-apple-darwin (Apple Silicon)")
                        InfoRow(key: "OS Version", value: ProcessInfo.processInfo.operatingSystemVersionString)
                        InfoRow(key: "Physical CPU Cores", value: "\(ProcessInfo.processInfo.activeProcessorCount)")
                        InfoRow(key: "Physical Memory", value: String(format: "%.1f GB", Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)))
                        InfoRow(key: "Graphics Backend", value: "Apple Metal 3 (wgpu-core)")
                        InfoRow(key: "Window Subsystem", value: "AppKit NSWindow + CAMetalLayer borderless presentation")
                    }
                    .padding(10)
                }

                GroupBox(label: Label("MicroVM & Virtualization Pipeline", systemImage: "cube.transparent").font(.headline)) {
                    VStack(alignment: .leading, spacing: 10) {
                        InfoRow(key: "Hypervisor Engine", value: "Apple Virtualization.framework (VZVirtualMachine)")
                        InfoRow(key: "Cold Boot Target", value: "<150ms sub-second bootloader")
                        InfoRow(key: "Inter-Process IPC", value: "virtio-vsock SCM_RIGHTS file descriptor forwarding (port 1024)")
                        InfoRow(key: "Zero-Copy Memory", value: "virtio-fs shared memory tag host_share -> /dev/shm")
                        InfoRow(key: "Paravirtualized GPU", value: "virtio-gpu scanout / Venus Vulkan acceleration")
                    }
                    .padding(10)
                }

                GroupBox(label: Label("Included Binaries & Bundles", systemImage: "folder").font(.headline)) {
                    VStack(alignment: .leading, spacing: 10) {
                        InfoRow(key: "Niri Compositor", value: CompositorManager.shared.findNiriBinary() ?? "Not found")
                        InfoRow(key: "MicroVM Runner", value: MicroVMManager.shared.findLauncherBinary() ?? "Not found")
                        InfoRow(key: "Asset Installer", value: AssetInstaller.shared.findScriptPath() ?? "Not found")
                    }
                    .padding(10)
                }
            }
            .padding(24)
        }
    }
}

private struct InfoRow: View {
    let key: String
    let value: String

    var body: some View {
        HStack {
            Text(key)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 180, alignment: .leading)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.medium)
            Spacer()
        }
    }
}
