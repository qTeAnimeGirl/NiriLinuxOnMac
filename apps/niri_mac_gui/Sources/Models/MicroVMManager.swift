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

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var bootStartTime: Date?

    public init() {}

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

        if !config.diskPath.isEmpty && fm.fileExists(atPath: config.diskPath) {
            args.append(contentsOf: ["--disk", config.diskPath])
        }

        proc.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                LogManager.shared.append(source: .microvm, message: str, level: .info)
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

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                LogManager.shared.append(source: .microvm, message: str, level: .warn)
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

    private func handleTermination(_ proc: Process) {
        self.isRunning = false
        self.pid = 0
        self.process = nil
        self.stdoutPipe = nil
        self.stderrPipe = nil

        LogManager.shared.append(source: .microvm, message: "MicroVM process terminated (exit code: \(proc.terminationStatus))")
    }
}
