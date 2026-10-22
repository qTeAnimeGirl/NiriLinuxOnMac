//
//  AssetInstaller.swift
//  Niri macOS GUI Launcher
//

import Foundation
import Combine

public final class AssetInstaller: ObservableObject {
    public static let shared = AssetInstaller()

    @Published public var isInstalling: Bool = false
    @Published public var statusMessage: String = "Ready"
    @Published public var assetsReady: Bool = false

    private var installProcess: Process?

    public init() {
        checkAssets()
    }

    public func findScriptPath() -> String? {
        let fm = FileManager.default
        let cwd = fm.currentDirectoryPath
        let candidates = [
            "\(cwd)/vm/scripts/install_assets.sh",
            "\(Bundle.main.bundlePath)/Contents/Resources/scripts/install_assets.sh",
            "\(Bundle.main.resourcePath ?? "")/scripts/install_assets.sh"
        ]
        for c in candidates where fm.fileExists(atPath: c) {
            return c
        }
        return nil
    }

    public func checkAssets() {
        let fm = FileManager.default
        let config = LauncherConfig.shared

        let hasKernel = !config.kernelPath.isEmpty && fm.fileExists(atPath: config.kernelPath)
        let hasInitrd = !config.initrdPath.isEmpty && fm.fileExists(atPath: config.initrdPath)
        let hasNiri = CompositorManager.shared.findNiriBinary() != nil
        let hasLauncher = MicroVMManager.shared.findLauncherBinary() != nil

        let ready = hasKernel && hasInitrd && hasNiri && hasLauncher
        DispatchQueue.main.async {
            self.assetsReady = ready
            if ready {
                self.statusMessage = "All core assets verified and ready"
            } else {
                var missing: [String] = []
                if !hasKernel { missing.append("Kernel") }
                if !hasInitrd { missing.append("Initramfs") }
                if !hasNiri { missing.append("niri") }
                if !hasLauncher { missing.append("microvm_launcher") }
                self.statusMessage = "Missing: \(missing.joined(separator: ", "))"
            }
        }
    }

    public func installAssets(completion: @escaping (Bool) -> Void) {
        guard !isInstalling else { return }
        guard let script = findScriptPath() else {
            LogManager.shared.append(source: .install, message: "ERROR: install_assets.sh not found!", level: .error)
            completion(false)
            return
        }

        self.isInstalling = true
        self.statusMessage = "Downloading and configuring Linux assets..."
        LogManager.shared.append(source: .install, message: "Starting automated asset installation via \(script)...")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [script]

            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if let str = String(data: data, encoding: .utf8), !str.isEmpty {
                    LogManager.shared.append(source: .install, message: str, level: .info)
                }
            }

            do {
                try proc.run()
                proc.waitUntilExit()

                DispatchQueue.main.async {
                    self?.isInstalling = false
                    LauncherConfig.shared.autoDiscoverAssets()
                    self?.checkAssets()

                    if proc.terminationStatus == 0 {
                        LogManager.shared.append(source: .install, message: "Asset installation finished successfully!")
                        completion(true)
                    } else {
                        LogManager.shared.append(source: .install, message: "Asset installation exited with code \(proc.terminationStatus)", level: .error)
                        completion(false)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.isInstalling = false
                    LogManager.shared.append(source: .install, message: "Failed to execute installer: \(error.localizedDescription)", level: .error)
                    completion(false)
                }
            }
        }
    }
}
