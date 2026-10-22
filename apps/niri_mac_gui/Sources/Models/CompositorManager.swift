//
//  CompositorManager.swift
//  Niri macOS GUI Launcher
//

import Foundation
import Combine
import AppKit

public final class CompositorManager: ObservableObject {
    public static let shared = CompositorManager()

    @Published public var isRunning: Bool = false
    @Published public var pid: Int32 = 0
    @Published public var waylandSocketPath: String = ""
    @Published public var ipcSocketPath: String = ""
    @Published public var windows: [WindowInfo] = []
    @Published public var resolutionText: String = "1920 x 1080"
    @Published public var uptimeSeconds: Int = 0

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var windowPollTimer: Timer?
    private var uptimeTimer: Timer?
    private var startTime: Date?

    public init() {}

    public func findNiriBinary() -> String? {
        let fm = FileManager.default

        // Priority 1: Inside bundled App
        if let bundleExec = Bundle.main.path(forAuxiliaryExecutable: "niri"), fm.fileExists(atPath: bundleExec) {
            return bundleExec
        }
        let inBundle = "\(Bundle.main.bundlePath)/Contents/MacOS/niri"
        if fm.fileExists(atPath: inBundle) {
            return inBundle
        }

        // Priority 2: Working directory target/release or target/debug
        let cwd = fm.currentDirectoryPath
        let candidates = [
            "\(cwd)/target/release/niri",
            "\(cwd)/target/debug/niri",
            "\(cwd)/niri",
            "/opt/homebrew/bin/niri",
            "/usr/local/bin/niri"
        ]

        for cand in candidates where fm.fileExists(atPath: cand) {
            return cand
        }

        return nil
    }

    public func start(config: LauncherConfig, completion: @escaping (Bool) -> Void) {
        guard !isRunning else {
            completion(true)
            return
        }

        guard let niriBin = findNiriBinary() else {
            LogManager.shared.append(source: .niri, message: "ERROR: niri binary not found! Please build it first with cargo build --release", level: .error)
            completion(false)
            return
        }

        let fm = FileManager.default
        let uid = getuid()
        let runtimeDir = "\(NSTemporaryDirectory())niri-runtime-\(uid)"
        try? fm.createDirectory(atPath: runtimeDir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])

        let res = config.effectiveResolution()
        self.resolutionText = "\(res.width) x \(res.height)"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: niriBin)

        var env = ProcessInfo.processInfo.environment
        env["XDG_RUNTIME_DIR"] = runtimeDir
        env["NIRI_NOTCH_BYPASS"] = config.notchBypass ? "1" : "0"
        env["NIRI_WINDOWED"] = config.isWindowed ? "1" : "0"
        env["NIRI_WIDTH"] = "\(res.width)"
        env["NIRI_HEIGHT"] = "\(res.height)"
        env["NIRI_HIDE_CURSOR"] = config.hideOsCursor ? "1" : "0"
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                LogManager.shared.append(source: .niri, message: str, level: .info)
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                LogManager.shared.append(source: .niri, message: str, level: .warn)
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
            self.startTime = Date()
            self.stdoutPipe = outPipe
            self.stderrPipe = errPipe

            LogManager.shared.append(source: .niri, message: "Launched Niri compositor (PID \(self.pid))")

            // Wait for sockets
            self.waitForSockets(runtimeDir: runtimeDir, config: config, completion: completion)

            // Start Uptime Timer
            self.uptimeTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self = self, let start = self.startTime else { return }
                self.uptimeSeconds = Int(Date().timeIntervalSince(start))
            }
        } catch {
            LogManager.shared.append(source: .niri, message: "Failed to launch Niri: \(error.localizedDescription)", level: .error)
            completion(false)
        }
    }

    private func waitForSockets(runtimeDir: String, config: LauncherConfig, completion: @escaping (Bool) -> Void) {
        let fm = FileManager.default
        var attempts = 0
        let maxAttempts = 50

        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                completion(false)
                return
            }

            attempts += 1
            if let files = try? fm.contentsOfDirectory(atPath: runtimeDir) {
                for file in files {
                    if file.hasPrefix("wayland-") && !file.hasSuffix(".lock") && self.waylandSocketPath.isEmpty {
                        self.waylandSocketPath = "\(runtimeDir)/\(file)"
                        LogManager.shared.append(source: .niri, message: "Wayland display socket available: \(self.waylandSocketPath)")
                    }
                    if file.hasPrefix("niri.") && file.hasSuffix(".sock") && self.ipcSocketPath.isEmpty {
                        self.ipcSocketPath = "\(runtimeDir)/\(file)"
                        LogManager.shared.append(source: .niri, message: "Niri IPC socket available: \(self.ipcSocketPath)")
                    }
                }
            }

            if !self.waylandSocketPath.isEmpty && !self.ipcSocketPath.isEmpty {
                timer.invalidate()
                self.startWindowPolling(niriBin: self.findNiriBinary() ?? "niri")
                completion(true)
            } else if attempts >= maxAttempts {
                timer.invalidate()
                if !self.waylandSocketPath.isEmpty {
                    self.startWindowPolling(niriBin: self.findNiriBinary() ?? "niri")
                    completion(true)
                } else {
                    completion(false)
                }
            }
        }
    }

    private func startWindowPolling(niriBin: String) {
        self.windowPollTimer?.invalidate()
        self.windowPollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refreshWindows(niriBin: niriBin)
        }
        self.refreshWindows(niriBin: niriBin)
    }

    public func refreshWindows(niriBin: String? = nil) {
        guard isRunning, !ipcSocketPath.isEmpty else { return }
        let bin = niriBin ?? findNiriBinary() ?? "niri"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: bin)
            proc.arguments = ["msg", "--json", "windows"]

            var env = ProcessInfo.processInfo.environment
            env["NIRI_SOCKET"] = self.ipcSocketPath
            proc.environment = env

            let pipe = Pipe()
            proc.standardOutput = pipe

            do {
                try proc.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()

                if proc.terminationStatus == 0, !data.isEmpty {
                    let decoder = JSONDecoder()
                    if let parsed = try? decoder.decode([WindowInfo].self, from: data) {
                        DispatchQueue.main.async {
                            self.windows = parsed
                        }
                    }
                }
            } catch {
                // Ignore transient query errors
            }
        }
    }

    public func focusWindow(id: UInt64) {
        guard let bin = findNiriBinary(), !ipcSocketPath.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: bin)
            proc.arguments = ["msg", "action", "focus-window", "--id", "\(id)"]
            var env = ProcessInfo.processInfo.environment
            env["NIRI_SOCKET"] = self.ipcSocketPath
            proc.environment = env
            try? proc.run()
            proc.waitUntilExit()
        }
    }

    public func closeWindow(id: UInt64) {
        guard let bin = findNiriBinary(), !ipcSocketPath.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: bin)
            proc.arguments = ["msg", "action", "close-window", "--id", "\(id)"]
            var env = ProcessInfo.processInfo.environment
            env["NIRI_SOCKET"] = self?.ipcSocketPath ?? ""
            proc.environment = env
            try? proc.run()
            proc.waitUntilExit()
            self?.refreshWindows()
        }
    }

    public func stop() {
        guard let proc = process, isRunning else { return }
        LogManager.shared.append(source: .niri, message: "Stopping Niri compositor...")

        windowPollTimer?.invalidate()
        windowPollTimer = nil
        uptimeTimer?.invalidate()
        uptimeTimer = nil

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
        self.waylandSocketPath = ""
        self.ipcSocketPath = ""
        self.windows.removeAll()
        self.uptimeSeconds = 0
        self.windowPollTimer?.invalidate()
        self.windowPollTimer = nil
        self.uptimeTimer?.invalidate()
        self.uptimeTimer = nil
        self.process = nil
        self.stdoutPipe = nil
        self.stderrPipe = nil

        LogManager.shared.append(source: .niri, message: "Niri compositor terminated (exit code: \(proc.terminationStatus))")
    }
}
