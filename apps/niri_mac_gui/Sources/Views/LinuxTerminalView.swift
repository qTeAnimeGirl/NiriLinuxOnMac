//
//  LinuxTerminalView.swift
//  Niri macOS GUI Launcher
//

import SwiftUI
import AppKit
import SwiftTerm

// MARK: - AppKit SwiftTerm NSViewRepresentable Bridge
public struct SwiftTerminalRepresentable: NSViewRepresentable {
    public typealias NSViewType = SwiftTerm.TerminalView

    @ObservedObject var microvm: MicroVMManager
    var fontSize: CGFloat

    public final class Coordinator: NSObject, TerminalViewDelegate {
        weak var microvm: MicroVMManager?

        init(microvm: MicroVMManager) {
            self.microvm = microvm
        }

        public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}

        public func setTerminalTitle(source: TerminalView, title: String) {}

        public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        public func send(source: TerminalView, data: ArraySlice<UInt8>) {
            microvm?.sendRawBytes(Data(data))
        }

        public func scrolled(source: TerminalView, position: Double) {}

        public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(microvm: microvm)
    }

    public func makeNSView(context: Context) -> SwiftTerm.TerminalView {
        let terminal = SwiftTerm.TerminalView(frame: .zero)
        terminal.terminalDelegate = context.coordinator
        terminal.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        terminal.nativeBackgroundColor = NSColor(red: 0.08, green: 0.09, blue: 0.12, alpha: 1.0)
        terminal.nativeForegroundColor = NSColor(red: 0.92, green: 0.94, blue: 0.97, alpha: 1.0)

        // Feed recent replay buffer if present
        let existing = microvm.getRecentRawData()
        if !existing.isEmpty {
            terminal.feed(byteArray: ArraySlice<UInt8>(existing))
        }

        // Hook up live stream from MicroVM
        microvm.onRawData = { [weak terminal] data in
            DispatchQueue.main.async {
                terminal?.feed(byteArray: ArraySlice<UInt8>(data))
            }
        }

        return terminal
    }

    public func updateNSView(_ nsView: SwiftTerm.TerminalView, context: Context) {
        if nsView.font.pointSize != fontSize {
            nsView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
    }
}

// MARK: - Full Proper Linux Terminal View
public struct LinuxTerminalView: View {
    @ObservedObject var microvm: MicroVMManager
    @State private var commandInput: String = ""
    @State private var fontSize: CGFloat = 13.0
    @State private var showShortcuts: Bool = true

    public init(microvm: MicroVMManager) {
        self.microvm = microvm
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack {
                HStack(spacing: 8) {
                    Circle()
                        .fill(microvm.isRunning ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                    Text("Arch Linux ARM Hardware Console")
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
                    // Font zoom controls
                    HStack(spacing: 4) {
                        Button(action: {
                            if fontSize > 9 { fontSize -= 1 }
                        }) {
                            Image(systemName: "textformat.size.smaller")
                        }
                        .help("Decrease Font Size")

                        Text("\(Int(fontSize)) pt")
                            .font(.caption)
                            .frame(width: 34)

                        Button(action: {
                            if fontSize < 24 { fontSize += 1 }
                        }) {
                            Image(systemName: "textformat.size.larger")
                        }
                        .help("Increase Font Size")
                    }

                    Divider()
                        .frame(height: 16)

                    // Control signals
                    HStack(spacing: 4) {
                        Button("Ctrl+C") {
                            sendControlCode(3) // ETX
                        }
                        .font(.caption)
                        .disabled(!microvm.isRunning)
                        .help("Interrupt running command")

                        Button("Ctrl+D") {
                            sendControlCode(4) // EOT
                        }
                        .font(.caption)
                        .disabled(!microvm.isRunning)
                        .help("End-of-file")

                        Button("Ctrl+L") {
                            sendControlCode(12) // Form Feed / Clear
                        }
                        .font(.caption)
                        .disabled(!microvm.isRunning)
                        .help("Clear screen")
                    }

                    Divider()
                        .frame(height: 16)

                    Button(action: {
                        microvm.clearTerminal()
                    }) {
                        Label("Clear", systemImage: "trash")
                            .font(.caption)
                    }

                    Button(action: {
                        openHostTerminal()
                    }) {
                        Label("Terminal.app", systemImage: "terminal")
                            .font(.caption)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Terminal Screen Body (Full SwiftTerm VT100 / Xterm Emulator)
            SwiftTerminalRepresentable(microvm: microvm, fontSize: fontSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Quick Command Toolbar
            VStack(spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("Shortcuts:")
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        quickButton("pacman -Sy")
                        quickButton("install-firefox")
                        quickButton("pacman -S --overwrite '*' firefox")
                        quickButton("df -h /mnt/storage")
                        quickButton("wayland-run wayland_window &")
                        quickButton("uname -a")
                        quickButton("ip addr show eth0")
                        quickButton("curl -I https://archlinuxarm.org")
                        quickButton("ps aux")
                        quickButton("poweroff -f")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
                .background(Color(NSColor.controlBackgroundColor))

                Divider()

                // Interactive Quick Input Bar
                HStack(spacing: 8) {
                    Text("archlinux:~$")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(.accentColor)

                    TextField("Type command or paste (e.g. pacman -Syu, nano, top)...", text: $commandInput)
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
                .padding(.vertical, 8)
            }
            .background(Color(NSColor.windowBackgroundColor))
        }
    }

    private func quickButton(_ cmd: String) -> some View {
        Button(action: {
            microvm.sendCommand(cmd)
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
        microvm.sendCommand(trimmed)
        commandInput = ""
    }

    private func sendControlCode(_ byte: UInt8) {
        microvm.sendRawBytes(Data([byte]))
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
