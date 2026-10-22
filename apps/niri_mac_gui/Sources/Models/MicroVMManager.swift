//
//  MicroVMManager.swift
//  Niri macOS GUI Launcher
//

import Foundation
import Combine

public final class MicroVMManager: ObservableObject {
    public static let shared = MicroVMManager()

    @Published public var isRunning: Bool = false
    @Published public var pid: Int32 = 0
    @Published public var vCPUs: Int = 0
    @Published public var memoryMB: Int = 0
    @Published public var bootDurationMs: Double = 0
    @Published public var vsockPort: UInt32 = 1024
    @Published public var terminalLines: [String] = []

    public var onRawData: ((Data) -> Void)?
    private var recentRawBuffer = Data()
    private let rawBufferQueue = DispatchQueue(label: "org.niri.microvm.rawbuffer")
    private let maxRawBufferSize = 256 * 1024 // 256 KB replay window

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var bootStartTime: Date?

    public init() {}

    public func sendRawBytes(_ data: Data) {
        guard isRunning, let pipe = stdinPipe else { return }
        pipe.fileHandleForWriting.write(data)
    }

    public func sendCommand(_ cmd: String) {
        guard isRunning, let pipe = stdinPipe else { return }
        var line = cmd
        if line.hasSuffix("\r\n") {
            // Already formatted
        } else if line.hasSuffix("\n") {
            line = String(line.dropLast()) + "\r\n"
        } else {
            line += "\r\n"
        }
        if let data = line.data(using: .utf8) {
            pipe.fileHandleForWriting.write(data)
        }
    }

    public func getRecentRawData() -> Data {
        return rawBufferQueue.sync {
            return recentRawBuffer
        }
    }

    public func clearTerminal() {
        rawBufferQueue.sync {
            self.recentRawBuffer.removeAll()
        }
        DispatchQueue.main.async {
            self.terminalLines.removeAll()
        }
    }

    private func appendRawData(_ data: Data) {
        rawBufferQueue.sync {
            recentRawBuffer.append(data)
            if recentRawBuffer.count > maxRawBufferSize {
                let excess = recentRawBuffer.count - maxRawBufferSize
                recentRawBuffer.removeSubrange(0..<excess)
            }
        }
    }

    public func findLauncherBinary() -> String? {
        let fm = FileManager.default

        if let bundleExec = Bundle.main.path(forAuxiliaryExecutable: "microvm_launcher"), fm.fileExists(atPath: bundleExec) {
            return bundleExec
        }
        let inBundle = "\(Bundle.main.bundlePath)/Contents/MacOS/microvm_launcher"
        if fm.fileExists(atPath: inBundle) {
            return inBundle
        }

        let cwd = fm.currentDirectoryPath
        let candidates = [
            "\(cwd)/target/microvm_launcher",
            "\(cwd)/target/release/microvm_launcher",
            "\(cwd)/microvm_launcher"
        ]

        for cand in candidates where fm.fileExists(atPath: cand) {
            return cand
        }

        return nil
    }

    public func start(config: LauncherConfig, waylandSocket: String, completion: @escaping (Bool) -> Void) {
        guard !isRunning else {
            completion(true)
            return
        }

        guard let launcherBin = findLauncherBinary() else {
            LogManager.shared.append(source: .microvm, message: "ERROR: microvm_launcher binary not found! Please build it first with vm/scripts/launch_vz.sh", level: .error)
            completion(false)
            return
        }

        let fm = FileManager.default
        let kernel = config.kernelPath
        let initrd = config.initrdPath

        guard !kernel.isEmpty && fm.fileExists(atPath: kernel) else {
            LogManager.shared.append(source: .microvm, message: "ERROR: Kernel image not found at \(kernel)", level: .error)
            completion(false)
            return
        }

        guard !initrd.isEmpty && fm.fileExists(atPath: initrd) else {
            LogManager.shared.append(source: .microvm, message: "ERROR: Initramfs image not found at \(initrd)", level: .error)
            completion(false)
            return
        }

        // Ensure persistent virtual disk is configured
        var diskToAttach = config.diskPath
        if diskToAttach.isEmpty || !fm.fileExists(atPath: diskToAttach) {
            diskToAttach = config.ensureDefaultDiskExists()
        }

        // Ensure shared directory exists
        try? fm.createDirectory(atPath: config.sharedMemPath, withIntermediateDirectories: true, attributes: nil)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: launcherBin)

        var args = [
            "--kernel", kernel,
            "--initrd", initrd,
            "--cpus", "\(config.vCPUs)",
            "--memory", "\(config.memoryMB)",
            "--shared-dir", config.sharedMemPath,
            "--vsock-port", "\(config.vsockPort)",
            "--wayland-socket", waylandSocket
        ]

        if !diskToAttach.isEmpty && fm.fileExists(atPath: diskToAttach) {
            args.append(contentsOf: ["--disk", diskToAttach])
            LogManager.shared.append(source: .microvm, message: "Attaching persistent virtual disk storage: \(diskToAttach)")
        }

        proc.arguments = args

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        self.stdinPipe = inPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            self?.appendRawData(data)
            self?.onRawData?(data)

            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                LogManager.shared.append(source: .microvm, message: str, level: .info)
                DispatchQueue.main.async {
                    self?.appendTerminalOutput(str)
                }
                if str.contains("booted successfully") || str.contains("Linux MicroVM booted") {
                    if let start = self?.bootStartTime {
                        let ms = Date().timeIntervalSince(start) * 1000.0
                        DispatchQueue.main.async {
                            self?.bootDurationMs = ms
                        }
                    }
                }
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            self?.appendRawData(data)
            self?.onRawData?(data)

            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                LogManager.shared.append(source: .microvm, message: str, level: .warn)
                DispatchQueue.main.async {
                    self?.appendTerminalOutput(str)
                }
            }
        }

        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                self?.handleTermination(p)
            }
        }

        self.bootStartTime = Date()
        self.vCPUs = config.vCPUs
        self.memoryMB = config.memoryMB
        self.vsockPort = config.vsockPort

        do {
            try proc.run()
            self.process = proc
            self.pid = proc.processIdentifier
            self.isRunning = true
            self.stdoutPipe = outPipe
            self.stderrPipe = errPipe

            LogManager.shared.append(source: .microvm, message: "Started Apple Virtualization MicroVM (PID \(self.pid), \(config.vCPUs) vCPUs, \(config.memoryMB) MB RAM)")
            completion(true)
        } catch {
            LogManager.shared.append(source: .microvm, message: "Failed to start MicroVM: \(error.localizedDescription)", level: .error)
            completion(false)
        }
    }

    public func stop() {
        guard let proc = process, isRunning else { return }
        LogManager.shared.append(source: .microvm, message: "Stopping MicroVM...")

        proc.terminate()

        DispatchQueue.global(qos: .userInitiated).async {
            let deadline = Date().addingTimeInterval(2.0)
            while proc.isRunning && Date() < deadline {
                usleep(50000)
            }
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }
    }

    private func stripAnsiEscapes(_ text: String) -> String {
        return text.replacingOccurrences(of: "\\x1B\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression)
    }

    private func appendTerminalOutput(_ text: String) {
        let clean = stripAnsiEscapes(text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = clean.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .newlines)
            if !trimmed.isEmpty {
                self.terminalLines.append(trimmed)
            }
        }
        if self.terminalLines.count > 1000 {
            self.terminalLines.removeFirst(self.terminalLines.count - 1000)
        }
    }

    private func handleTermination(_ proc: Process) {
        self.isRunning = false
        self.pid = 0
        self.process = nil
        self.stdinPipe = nil
        self.stdoutPipe = nil
        self.stderrPipe = nil

        LogManager.shared.append(source: .microvm, message: "MicroVM process terminated (exit code: \(proc.terminationStatus))")
        self.terminalLines.append("[MicroVM process terminated (exit code: \(proc.terminationStatus))]")
    }
}
