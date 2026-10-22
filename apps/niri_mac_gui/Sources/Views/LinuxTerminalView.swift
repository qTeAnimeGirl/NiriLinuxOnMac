//
//  LinuxTerminalView.swift
//  Niri macOS GUI Launcher
//

import SwiftUI
import AppKit

public struct LinuxTerminalView: View {
    @ObservedObject var microvm: MicroVMManager
    @State private var commandInput: String = ""
    @State private var autoScroll: Bool = true
    @State private var commandHistory: [String] = []
    @State private var historyIndex: Int = -1

    public init(microvm: MicroVMManager) {
        self.microvm = microvm
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                HStack(spacing: 8) {
                    Circle()
                        .fill(microvm.isRunning ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                    Text("Arch Linux ARM Console")
                        .font(.headline)
                    if microvm.isRunning {
                        Text("PID \(microvm.pid)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15))
                            .cornerRadius(4)
                    }
                }

                Spacer()

                HStack(spacing: 12) {
                    Toggle("Auto-scroll", isOn: $autoScroll)
                        .toggleStyle(.checkbox)
                        .font(.caption)

                    Button(action: {
                        microvm.clearTerminal()
                    }) {
                        Label("Clear", systemImage: "trash")
                            .font(.caption)
                    }

                    Button(action: {
                        openHostTerminal()
                    }) {
                        Label("Open in Terminal.app", systemImage: "terminal")
                            .font(.caption)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Terminal Console Body
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if microvm.terminalLines.isEmpty {
                            Text(microvm.isRunning
                                 ? "[Arch Linux ARM MicroVM Console Ready. Type a command below or click a shortcut.]"
                                 : "[MicroVM is not running. Click 'Start All' on the Dashboard to boot Arch Linux.]")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(.secondary)
                                .padding(12)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 1) {
                                ForEach(Array(microvm.terminalLines.enumerated()), id: \.offset) { index, line in
                                    Text(line)
                                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                                        .foregroundColor(colorForLine(line))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(index)
                                }
                            }
                            .padding(12)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color.black.opacity(0.92))
                .onChange(of: microvm.terminalLines.count) { _, _ in
                    if autoScroll, let lastIndex = microvm.terminalLines.indices.last {
                        proxy.scrollTo(lastIndex, anchor: .bottom)
                    }
                }
            }

            Divider()

            // Quick Shortcut Bar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Text("Quick Commands:")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    quickButton("uname -a")
                    quickButton("cat /etc/os-release")
                    quickButton("ps aux")
                    quickButton("ip a")
                    quickButton("wayland_window &")
                    quickButton("ls -la /run/user/1000")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Interactive Input Bar
            HStack(spacing: 8) {
                Text("archlinux:~$")
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundColor(.accentColor)

                TextField("Type command (e.g. ls, uname -a, ps aux)...", text: $commandInput)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit {
                        executeCommand()
                    }

                Button(action: {
                    executeCommand()
                }) {
                    Text("Send")
                        .font(.caption.bold())
                }
                .disabled(!microvm.isRunning || commandInput.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))
        }
    }

    private func quickButton(_ cmd: String) -> some View {
        Button(action: {
            sendCommand(cmd)
        }) {
            Text(cmd)
                .font(.system(size: 11, design: .monospaced))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .disabled(!microvm.isRunning)
    }

    private func executeCommand() {
        let trimmed = commandInput.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }

        sendCommand(trimmed)
        commandHistory.append(trimmed)
        commandInput = ""
        historyIndex = -1
    }

    private func sendCommand(_ cmd: String) {
        microvm.sendCommand(cmd)
    }

    private func colorForLine(_ line: String) -> Color {
        if line.contains("FATAL") || line.contains("ERROR") || line.contains("failed") || line.contains("Panic") {
            return Color.red.opacity(0.9)
        } else if line.contains("WARN") || line.contains("warning") {
            return Color.yellow.opacity(0.9)
        } else if line.contains("Arch Linux ARM") || line.contains("Linux version") {
            return Color.cyan.opacity(0.9)
        } else if line.contains("SUCCESS") || line.contains("booted successfully") {
            return Color.green.opacity(0.9)
        } else {
            return Color.white.opacity(0.85)
        }
    }

    private func openHostTerminal() {
        let script = """
        tell application "Terminal"
            activate
            do script "echo '=== Connected to Niri Arch Linux MicroVM Host Pipeline ===' && ps aux | grep microvm"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }
}
