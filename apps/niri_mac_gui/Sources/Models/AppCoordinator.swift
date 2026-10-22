//
//  AppCoordinator.swift
//  Niri macOS GUI Launcher
//

import Foundation
import Combine

public final class AppCoordinator: ObservableObject {
    public static let shared = AppCoordinator()

    @Published public var isStartingAll: Bool = false

    public let config = LauncherConfig.shared
    public let compositor = CompositorManager.shared
    public let bridge = VsockBridgeManager.shared
    public let microvm = MicroVMManager.shared
    public let installer = AssetInstaller.shared
    public let logger = LogManager.shared

    private var cancellables = Set<AnyCancellable>()

    public init() {
        // Forward changes
        compositor.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        bridge.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        microvm.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
    }

    public var isAllRunning: Bool {
        compositor.isRunning && bridge.isRunning && microvm.isRunning
    }

    public var isAnyRunning: Bool {
        compositor.isRunning || bridge.isRunning || microvm.isRunning
    }

    public func startAll() {
        guard !isStartingAll && !isAllRunning else { return }
        isStartingAll = true

        logger.append(source: .system, message: "Initiating One-Click Start...")

        // Step 1: Check assets
        installer.checkAssets()
        if !installer.assetsReady {
            logger.append(source: .system, message: "Core assets missing. Triggering auto-installation...")
            installer.installAssets { [weak self] success in
                guard let self = self else { return }
                if success {
                    self.launchPipeline()
                } else {
                    self.isStartingAll = false
                    self.logger.append(source: .system, message: "Aborting startup: assets installation failed", level: .error)
                }
            }
        } else {
            launchPipeline()
        }
    }

    private func launchPipeline() {
        // Save current settings before launch
        config.saveSettings()

        // Step 2: Launch Niri Compositor
        logger.append(source: .system, message: "Step 1/3: Launching Niri compositor...")
        compositor.start(config: config) { [weak self] success in
            guard let self = self else { return }
            guard success, !self.compositor.waylandSocketPath.isEmpty else {
                self.isStartingAll = false
                self.logger.append(source: .system, message: "Compositor startup failed or socket timeout", level: .error)
                return
            }

            // Step 3: Launch Host vsock Bridge
            self.logger.append(source: .system, message: "Step 2/3: Starting virtio-vsock Wayland host bridge...")
            let targetWayland = self.config.waylandSocketOverride.isEmpty ? self.compositor.waylandSocketPath : self.config.waylandSocketOverride
            let sharedDir = self.config.sharedMemPath
            let port = self.config.vsockPort

            self.bridge.start(waylandSocket: targetWayland, sharedDir: sharedDir, port: port) { [weak self] bridgeOk in
                guard let self = self else { return }
                guard bridgeOk else {
                    self.isStartingAll = false
                    self.logger.append(source: .system, message: "Failed to start vsock bridge daemon", level: .error)
                    return
                }

                // Step 4: Launch MicroVM targeting the bridge socket
                self.logger.append(source: .system, message: "Step 3/3: Booting Apple Virtualization MicroVM...")
                self.microvm.start(config: self.config, waylandSocket: self.bridge.bridgeSocketPath) { [weak self] vmSuccess in
                    guard let self = self else { return }
                    self.isStartingAll = false
                    if vmSuccess {
                        self.logger.append(source: .system, message: "All components operational! Niri + Bridge + MicroVM running.")
                    } else {
                        self.logger.append(source: .system, message: "MicroVM startup failed", level: .error)
                    }
                }
            }
        }
    }

    public func stopAll() {
        logger.append(source: .system, message: "Stopping all running components...")
        microvm.stop()
        bridge.stop()
        compositor.stop()
        isStartingAll = false
    }

    public func restartAll() {
        logger.append(source: .system, message: "Restarting Niri and MicroVM...")
        stopAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.startAll()
        }
    }
}
