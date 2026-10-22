//
//  DashboardView.swift
//  Niri macOS GUI Launcher
//

import SwiftUI

public struct DashboardView: View {
    @ObservedObject var coordinator: AppCoordinator

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // MARK: - Header & Quick Controls
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Live Control Dashboard")
                            .font(.system(size: 24, weight: .bold))
                        Text("Apple Silicon Native Wayland Compositor & Linux MicroVM")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    // Action Buttons
                    HStack(spacing: 12) {
                        if coordinator.isAllRunning {
                            Button(action: { coordinator.stopAll() }) {
                                Label("Stop All", systemImage: "stop.fill")
                                    .fontWeight(.semibold)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)

                            Button(action: { coordinator.restartAll() }) {
                                Label("Restart", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button(action: { coordinator.startAll() }) {
                                if coordinator.isStartingAll {
                                    ProgressView()
                                        .controlSize(.small)
                                        .padding(.trailing, 4)
                                    Text("Starting...")
                                } else {
                                    Label("One-Click Start", systemImage: "play.fill")
                                        .fontWeight(.semibold)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.accentColor)
                            .disabled(coordinator.isStartingAll)

                            if coordinator.isAnyRunning {
                                Button(action: { coordinator.stopAll() }) {
                                    Label("Stop", systemImage: "stop.fill")
                                }
                                .buttonStyle(.bordered)
                                .tint(.red)
                            }
                        }

                        Button(action: {
                            coordinator.installer.installAssets { _ in }
                        }) {
                            Label("Auto-Install Assets", systemImage: "arrow.down.circle")
                        }
                        .buttonStyle(.bordered)
                        .disabled(coordinator.installer.isInstalling)
                    }
                }
                .padding(.bottom, 4)

                // MARK: - Metrics Cards
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    // Compositor Card
                    StatusCard(
                        title: "Niri Compositor",
                        icon: "display",
                        isRunning: coordinator.compositor.isRunning,
                        badgeColor: coordinator.compositor.isRunning ? .green : .secondary,
                        metrics: [
                            ("State", coordinator.compositor.isRunning ? "Running" : "Stopped"),
                            ("PID", coordinator.compositor.isRunning ? "\(coordinator.compositor.pid)" : "-"),
                            ("Resolution", coordinator.compositor.isRunning ? coordinator.compositor.resolutionText : coordinator.config.resolutionPreset),
                            ("Uptime", coordinator.compositor.isRunning ? "\(coordinator.compositor.uptimeSeconds)s" : "-")
                        ]
                    )

                    // MicroVM Card
                    StatusCard(
                        title: "Linux MicroVM",
                        icon: "cpu",
                        isRunning: coordinator.microvm.isRunning,
                        badgeColor: coordinator.microvm.isRunning ? .green : .secondary,
                        metrics: [
                            ("State", coordinator.microvm.isRunning ? "Booted" : "Inactive"),
                            ("PID", coordinator.microvm.isRunning ? "\(coordinator.microvm.pid)" : "-"),
                            ("vCPUs / RAM", "\(coordinator.config.vCPUs) Cores / \(coordinator.config.memoryMB) MB"),
                            ("Boot Time", coordinator.microvm.bootDurationMs > 0 ? String(format: "%.1f ms", coordinator.microvm.bootDurationMs) : "-")
                        ]
                    )

                    // Wayland Windows Card
                    StatusCard(
                        title: "Wayland Clients",
                        icon: "macwindow.on.rectangle",
                        isRunning: !coordinator.compositor.windows.isEmpty,
                        badgeColor: coordinator.compositor.windows.isEmpty ? .secondary : .cyan,
                        metrics: [
                            ("Mapped Windows", "\(coordinator.compositor.windows.count)"),
                            ("VSOCK Bridge", coordinator.bridge.isRunning ? "Active (PID \(coordinator.bridge.pid))" : "Inactive"),
                            ("VSOCK Port", "\(coordinator.config.vsockPort)"),
                            ("Socket", coordinator.compositor.waylandSocketPath.isEmpty ? "None" : (coordinator.compositor.waylandSocketPath as NSString).lastPathComponent)
                        ]
                    )
                }

                // MARK: - Mapped Windows Table Section
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Mapped Wayland Windows")
                                .font(.headline)
                            Text("Real-time client surfaces registered via Niri IPC")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button(action: {
                            coordinator.compositor.refreshWindows()
                        }) {
                            Label("Refresh", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!coordinator.compositor.isRunning)
                    }

                    if coordinator.compositor.windows.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "window.badge.magnifyingglass")
                                .font(.system(size: 36))
                                .foregroundColor(.secondary)
                            Text(coordinator.compositor.isRunning ? "No client windows currently mapped" : "Niri compositor is not running")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Text("When Linux Wayland apps (like foot, mpv, or wayland_window) launch inside the MicroVM, their toplevel surfaces appear here in real-time.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 420)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor).opacity(0.5)))
                    } else {
                        // Window Table
                        VStack(spacing: 0) {
                            // Table Header
                            HStack {
                                Text("ID").frame(width: 50, alignment: .leading)
                                Text("App ID").frame(width: 140, alignment: .leading)
                                Text("Window Title").frame(minWidth: 200, alignment: .leading)
                                Text("PID").frame(width: 60, alignment: .leading)
                                Text("Layout").frame(width: 80, alignment: .leading)
                                Text("Focus").frame(width: 70, alignment: .leading)
                                Text("Actions").frame(width: 130, alignment: .trailing)
                            }
                            .font(.caption.bold())
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(NSColor.separatorColor).opacity(0.15))

                            Divider()

                            ForEach(coordinator.compositor.windows) { win in
                                HStack {
                                    Text("\(win.id)").frame(width: 50, alignment: .leading).font(.system(.body, design: .monospaced))
                                    Text(win.displayAppId).frame(width: 140, alignment: .leading).fontWeight(.medium)
                                    Text(win.displayTitle).frame(minWidth: 200, alignment: .leading).lineLimit(1)
                                    Text(win.displayPid).frame(width: 60, alignment: .leading).font(.system(.caption, design: .monospaced))
                                    Text(win.displayLayout).frame(width: 80, alignment: .leading)

                                    HStack {
                                        if win.is_focused {
                                            Circle().fill(Color.green).frame(width: 8, height: 8)
                                            Text("Active").font(.caption).foregroundColor(.green)
                                        } else {
                                            Circle().fill(Color.secondary).frame(width: 8, height: 8)
                                            Text("Inactive").font(.caption).foregroundColor(.secondary)
                                        }
                                    }
                                    .frame(width: 70, alignment: .leading)

                                    HStack(spacing: 8) {
                                        Button("Focus") {
                                            coordinator.compositor.focusWindow(id: win.id)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)

                                        Button("Close") {
                                            coordinator.compositor.closeWindow(id: win.id)
                                        }
                                        .buttonStyle(.bordered)
                                        .controlSize(.mini)
                                        .tint(.red)
                                    }
                                    .frame(width: 130, alignment: .trailing)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)

                                Divider()
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color(NSColor.controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                    }
                }
            }
            .padding(24)
        }
    }
}

// MARK: - Status Card Component
private struct StatusCard: View {
    let title: String
    let icon: String
    let isRunning: Bool
    let badgeColor: Color
    let metrics: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(badgeColor)
                Text(title)
                    .font(.headline)
                Spacer()
                Circle()
                    .fill(badgeColor)
                    .frame(width: 10, height: 10)
            }

            Divider()

            VStack(spacing: 8) {
                ForEach(metrics, id: \.0) { key, val in
                    HStack {
                        Text(key)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(val)
                            .font(.system(.caption, design: .monospaced))
                            .fontWeight(.semibold)
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(NSColor.controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
    }
}
