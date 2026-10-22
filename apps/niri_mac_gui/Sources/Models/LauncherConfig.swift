//
//  LauncherConfig.swift
//  Niri macOS GUI Launcher
//

import Foundation
import Combine
import AppKit

public final class LauncherConfig: ObservableObject {
    public static let shared = LauncherConfig()

    // MARK: - Screen & Display Parameters
    @Published public var notchBypass: Bool = false
    @Published public var isWindowed: Bool = true
    @Published public var resolutionPreset: String = "1920x1080 (1080p FHD)"
    @Published public var customWidth: Int = 1920
    @Published public var customHeight: Int = 1080
    @Published public var selectedDisplayIndex: Int = 0
    @Published public var hideOsCursor: Bool = true

    // MARK: - MicroVM Resource Parameters
    @Published public var vCPUs: Int = min(4, max(1, ProcessInfo.processInfo.processorCount))
    @Published public var memoryMB: Int = 2048
    @Published public var kernelPath: String = ""
    @Published public var initrdPath: String = ""
    @Published public var diskPath: String = ""

    // MARK: - Graphics & Acceleration
    @Published public var enableVirtioGpu: Bool = true
    @Published public var enableMetalAcceleration: Bool = true
    @Published public var sharedMemPath: String = "/tmp/niri-shm"

    // MARK: - Network & IPC
    @Published public var vsockPort: UInt32 = 1024
    @Published public var waylandSocketOverride: String = ""

    // MARK: - Guest Launch
    @Published public var startupCommand: String = "/bin/wayland_window"

    public static let resolutionPresets: [String] = [
        "1920x1080 (1080p FHD)",
        "2560x1440 (2K QHD)",
        "3840x2160 (4K UHD)",
        "1728x1117 (MacBook Pro 16\" Native)",
        "1512x982 (MacBook Pro 14\" Native)",
        "1440x900 (MacBook Air Native)",
        "1280x800 (Compact)",
        "Fullscreen Borderless",
        "Custom"
    ]

    private let defaults = UserDefaults.standard

    public init() {
        loadSettings()
        autoDiscoverAssets()
    }

    public func autoDiscoverAssets() {
        let fileManager = FileManager.default

        let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Niri").path ?? ""

        // Detect project root relative to bundle or current directory
        let searchRoots: [String] = [
            appSupportDir,
            "\(appSupportDir)/vm_images",
            "\(appSupportDir)/archlinux",
            Bundle.main.resourcePath ?? "",
            "\(Bundle.main.resourcePath ?? "")/vm_images",
            Bundle.main.bundlePath,
            FileManager.default.currentDirectoryPath,
            "\(FileManager.default.currentDirectoryPath)/vm/images",
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).deletingLastPathComponent().path
        ].filter { !$0.isEmpty }

        for root in searchRoots {
            let kernelCandidates = [
                "\(root)/vm_images/Image",
                "\(root)/vm_images/vmlinuz",
                "\(root)/vm/images/Image",
                "\(root)/vm/images/vmlinuz",
                "\(root)/Image",
                "\(root)/vmlinuz"
            ]
            for cand in kernelCandidates where fileManager.fileExists(atPath: cand) {
                if self.kernelPath.isEmpty || !fileManager.fileExists(atPath: self.kernelPath) {
                    self.kernelPath = cand
                    break
                }
            }

            let initrdCandidates = [
                "\(root)/vm_images/initramfs.cpio.gz",
                "\(root)/vm/images/initramfs.cpio.gz",
                "\(root)/initramfs.cpio.gz"
            ]
            for cand in initrdCandidates where fileManager.fileExists(atPath: cand) {
                if self.initrdPath.isEmpty || !fileManager.fileExists(atPath: self.initrdPath) {
                    self.initrdPath = cand
                    break
                }
            }
        }
    }

    public func loadSettings() {
        if defaults.object(forKey: "niri.notchBypass") != nil {
            notchBypass = defaults.bool(forKey: "niri.notchBypass")
        }
        if defaults.object(forKey: "niri.isWindowed") != nil {
            isWindowed = defaults.bool(forKey: "niri.isWindowed")
        }
        if let res = defaults.string(forKey: "niri.resolutionPreset") {
            resolutionPreset = res
        }
        let w = defaults.integer(forKey: "niri.customWidth")
        if w > 0 { customWidth = w }
        let h = defaults.integer(forKey: "niri.customHeight")
        if h > 0 { customHeight = h }
        let cpus = defaults.integer(forKey: "niri.vCPUs")
        if cpus > 0 { vCPUs = cpus }
        let mem = defaults.integer(forKey: "niri.memoryMB")
        if mem >= 1024 { memoryMB = mem }
        if let k = defaults.string(forKey: "niri.kernelPath"), !k.isEmpty {
            kernelPath = k
        }
        if let i = defaults.string(forKey: "niri.initrdPath"), !i.isEmpty {
            initrdPath = i
        }
        if let d = defaults.string(forKey: "niri.diskPath") {
            diskPath = d
        }
        if defaults.object(forKey: "niri.enableVirtioGpu") != nil {
            enableVirtioGpu = defaults.bool(forKey: "niri.enableVirtioGpu")
        }
        if let s = defaults.string(forKey: "niri.sharedMemPath"), !s.isEmpty {
            sharedMemPath = s
        }
        let p = defaults.integer(forKey: "niri.vsockPort")
        if p > 0 { vsockPort = UInt32(p) }
        if let cmd = defaults.string(forKey: "niri.startupCommand"), !cmd.isEmpty {
            startupCommand = cmd
        }
    }

    public func saveSettings() {
        defaults.set(notchBypass, forKey: "niri.notchBypass")
        defaults.set(isWindowed, forKey: "niri.isWindowed")
        defaults.set(resolutionPreset, forKey: "niri.resolutionPreset")
        defaults.set(customWidth, forKey: "niri.customWidth")
        defaults.set(customHeight, forKey: "niri.customHeight")
        defaults.set(vCPUs, forKey: "niri.vCPUs")
        defaults.set(memoryMB, forKey: "niri.memoryMB")
        defaults.set(kernelPath, forKey: "niri.kernelPath")
        defaults.set(initrdPath, forKey: "niri.initrdPath")
        defaults.set(diskPath, forKey: "niri.diskPath")
        defaults.set(enableVirtioGpu, forKey: "niri.enableVirtioGpu")
        defaults.set(sharedMemPath, forKey: "niri.sharedMemPath")
        defaults.set(Int(vsockPort), forKey: "niri.vsockPort")
        defaults.set(startupCommand, forKey: "niri.startupCommand")
    }

    public func effectiveResolution() -> (width: Int, height: Int) {
        switch resolutionPreset {
        case "3840x2160 (4K UHD)":
            return (3840, 2160)
        case "2560x1440 (2K QHD)":
            return (2560, 1440)
        case "1920x1080 (1080p FHD)":
            return (1920, 1080)
        case "1728x1117 (MacBook Pro 16\" Native)":
            return (1728, 1117)
        case "1512x982 (MacBook Pro 14\" Native)":
            return (1512, 982)
        case "1440x900 (MacBook Air Native)":
            return (1440, 900)
        case "1280x800 (Compact)":
            return (1280, 800)
        case "Custom":
            return (max(640, customWidth), max(480, customHeight))
        default:
            // Fullscreen borderless defaults
            if let mainScreen = NSScreen.main {
                let frame = mainScreen.frame
                return (Int(frame.width), Int(frame.height))
            }
            return (1920, 1080)
        }
    }
}
