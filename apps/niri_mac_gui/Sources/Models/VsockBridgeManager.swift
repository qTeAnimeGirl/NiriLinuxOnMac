//
//  VsockBridgeManager.swift
//  Niri macOS GUI Launcher
//

import Foundation
import Combine

public final class VsockBridgeManager: ObservableObject {
    public static let shared = VsockBridgeManager()

    @Published public var isRunning: Bool = false
    @Published public var pid: Int32 = 0
    @Published public var bridgeSocketPath: String = "/tmp/niri-vsock-1024.sock"

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    public init() {}

    public func findBridgeBinary() -> String? {
        let fm = FileManager.default

        if let bundleExec = Bundle.main.path(forAuxiliaryExecutable: "niri-vsock-host"), fm.fileExists(atPath: bundleExec) {
            return bundleExec
        }
        let inBundle = "\(Bundle.main.bundlePath)/Contents/MacOS/niri-vsock-host"
        if fm.fileExists(atPath: inBundle) {
            return inBundle
        }

        let cwd = fm.currentDirectoryPath
        let candidates = [
            "\(cwd)/vm/host/target/release/niri-vsock-host",
            "\(cwd)/vm/host/target/debug/niri-vsock-host",
            "\(cwd)/target/release/niri-vsock-host",
            "\(cwd)/target/debug/niri-vsock-host"
        ]

        for cand in candidates where fm.fileExists(atPath: cand) {
            return cand
        }

        return nil
    }

    public func start(waylandSocket: String, sharedDir: String, port: UInt32, completion: @escaping (Bool) -> Void) {
        guard !isRunning else {
            completion(true)
            return
        }

        guard let bin = findBridgeBinary() else {
            LogManager.shared.append(source: .bridge, message: "ERROR: niri-vsock-host binary not found!", level: .error)
            completion(false)
            return
        }

        let fm = FileManager.default
        let sockPath = "/tmp/niri-vsock-\(port).sock"
        self.bridgeSocketPath = sockPath

        if fm.fileExists(atPath: sockPath) {
            try? fm.removeItem(atPath: sockPath)
        }
        try? fm.createDirectory(atPath: sharedDir, withIntermediateDirectories: true, attributes: nil)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = [
            "--wayland-socket", waylandSocket,
            "--listen-socket", sockPath,
            "--shared-dir", sharedDir,
            "--port", "\(port)"
        ]

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                LogManager.shared.append(source: .bridge, message: str, level: .info)
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                LogManager.shared.append(source: .bridge, message: str, level: .warn)
            }
        }

        proc.terminationHandler = { [weak self] p in
            DispatchQueue.main.async {
                self?.handleTermination(p)
            }
        }

        do {
            try proc.run()
            self.process = proc
            self.pid = proc.processIdentifier
            self.isRunning = true
            self.stdoutPipe = outPipe
            self.stderrPipe = errPipe

            LogManager.shared.append(source: .bridge, message: "Started virtio-vsock Host Bridge (PID \(self.pid)) on \(sockPath)")

            // Wait for bridge socket
            var attempts = 0
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
                attempts += 1
                if fm.fileExists(atPath: sockPath) {
                    timer.invalidate()
                    completion(true)
                } else if attempts > 40 {
                    timer.invalidate()
                    completion(false)
                }
            }
        } catch {
            LogManager.shared.append(source: .bridge, message: "Failed to start vsock bridge: \(error.localizedDescription)", level: .error)
            completion(false)
        }
    }

    public func stop() {
        guard let proc = process, isRunning else { return }
        LogManager.shared.append(source: .bridge, message: "Stopping vsock host bridge...")
        proc.terminate()
        try? FileManager.default.removeItem(atPath: bridgeSocketPath)
    }

    private func handleTermination(_ proc: Process) {
        self.isRunning = false
        self.pid = 0
        self.process = nil
        self.stdoutPipe = nil
        self.stderrPipe = nil
        LogManager.shared.append(source: .bridge, message: "vsock host bridge terminated (exit code: \(proc.terminationStatus))")
    }
}
