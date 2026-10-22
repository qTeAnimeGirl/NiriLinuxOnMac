//
//  LauncherConfig.swift
//  Niri macOS GUI Launcher
//

import Foundation
import Combine
import AppKit
import Darwin

public struct VirtualDiskInfo: Identifiable, Equatable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let logicalSizeBytes: UInt64
    public let physicalSizeBytes: UInt64
    public let isCurrentlySelected: Bool
    public let modifiedDate: Date

    public var logicalSizeGBString: String {
        let gb = Double(logicalSizeBytes) / (1024 * 1024 * 1024)
        return String(format: "%.1f GB", gb)
    }

    public var physicalSizeMBString: String {
        let mb = Double(physicalSizeBytes) / (1024 * 1024)
        if mb >= 1024 {
            return String(format: "%.2f GB", mb / 1024)
        }
        return String(format: "%.1f MB", mb)
    }

    public var savingsRatioString: String {
        guard logicalSizeBytes > 0 else { return "0%" }
        let saved = Double(logicalSizeBytes - min(logicalSizeBytes, physicalSizeBytes)) / Double(logicalSizeBytes) * 100.0
        return String(format: "%.0f%% saved", saved)
    }
}

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
    @Published public var diskSizeGB: Int = 20
    @Published public var availableDisks: [VirtualDiskInfo] = []

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
        refreshDisksList()
    }

    // MARK: - Virtual Disk Management

    public func getVMStorageDirectory() -> URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let vmsDir = appSupport.appendingPathComponent("Niri").appendingPathComponent("vms")
        try? fileManager.createDirectory(at: vmsDir, withIntermediateDirectories: true, attributes: nil)
        return vmsDir
    }

    public func refreshDisksList() {
        let fm = FileManager.default
        var result: [VirtualDiskInfo] = []
        var inspectedPaths = Set<String>()

        let candidateDirs: [URL] = [
            getVMStorageDirectory(),
            URL(fileURLWithPath: "\(fm.currentDirectoryPath)/vm/images"),
            URL(fileURLWithPath: "\(Bundle.main.bundlePath)/Contents/Resources/vm_images")
        ]

        for dir in candidateDirs {
            guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) else {
                continue
            }
            for case let fileURL as URL in enumerator {
                let ext = fileURL.pathExtension.lowercased()
                if ext == "img" || ext == "raw" || ext == "qcow2" {
                    let path = fileURL.path
                    if inspectedPaths.contains(path) { continue }
                    inspectedPaths.insert(path)

                    var st = stat()
                    if stat(path, &st) == 0 {
                        let logical = UInt64(max(0, st.st_size))
                        let physical = UInt64(max(0, st.st_blocks * 512))
                        let modDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                        let isSelected = (self.diskPath == path)

                        result.append(VirtualDiskInfo(
                            name: fileURL.lastPathComponent,
                            path: path,
                            logicalSizeBytes: logical,
                            physicalSizeBytes: physical,
                            isCurrentlySelected: isSelected,
                            modifiedDate: modDate
                        ))
                    }
                }
            }
        }

        result.sort { $0.modifiedDate > $1.modifiedDate }
        self.availableDisks = result

        // If current diskPath is empty but disks exist, auto-select the most recent
        if self.diskPath.isEmpty, let first = result.first {
            self.diskPath = first.path
            saveSettings()
        }
    }

    @discardableResult
    public func createVirtualDisk(name: String, sizeGB: Int) throws -> String {
        let fm = FileManager.default
        let vmsDir = getVMStorageDirectory()
        try fm.createDirectory(at: vmsDir, withIntermediateDirectories: true, attributes: nil)

        var cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanName.isEmpty {
            cleanName = "archlinux_disk.img"
        }
        if !cleanName.hasSuffix(".img") && !cleanName.hasSuffix(".raw") {
            cleanName += ".img"
        }

        let targetURL = vmsDir.appendingPathComponent(cleanName)
        let path = targetURL.path

        if fm.fileExists(atPath: path) {
            try? fm.removeItem(atPath: path)
        }

        let targetBytes = off_t(max(1, sizeGB)) * 1024 * 1024 * 1024
        let fd = open(path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            let err = errno
            throw NSError(domain: "NiriLauncher", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to create disk file: errno \(err)"])
        }

        if ftruncate(fd, targetBytes) != 0 {
            let err = errno
            close(fd)
            throw NSError(domain: "NiriLauncher", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to allocate sparse virtual disk: errno \(err)"])
        }
        close(fd)

        self.diskPath = path
        self.diskSizeGB = sizeGB
        saveSettings()
        refreshDisksList()

        return path
    }

    public func deleteVirtualDisk(at path: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return }

        try fm.removeItem(atPath: path)

        if self.diskPath == path {
            self.diskPath = ""
            saveSettings()
        }
        refreshDisksList()
    }

    public func wipeVirtualDisk(at path: String) throws {
        let fd = open(path, O_RDWR)
        guard fd >= 0 else {
            let err = errno
            throw NSError(domain: "NiriLauncher", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to open disk for wiping: errno \(err)"])
        }

        let wipeBlock = [UInt8](repeating: 0, count: 1024 * 1024) // 1 MB
        for _ in 0..<16 { // Wipe first 16 MB containing partition table & superblocks
            _ = write(fd, wipeBlock, wipeBlock.count)
        }
        fsync(fd)
        close(fd)
        refreshDisksList()
    }

    public func selectDisk(at path: String) {
        self.diskPath = path
        saveSettings()
        refreshDisksList()
    }

    @discardableResult
    public func ensureDefaultDiskExists() -> String {
        let fm = FileManager.default
        if !self.diskPath.isEmpty && fm.fileExists(atPath: self.diskPath) {
            return self.diskPath
        }

        refreshDisksList()
        if let first = self.availableDisks.first {
            self.diskPath = first.path
            saveSettings()
            return first.path
        }

        // Create default 20 GB sparse disk
        do {
            let newPath = try createVirtualDisk(name: "archlinux_disk.img", sizeGB: 20)
            return newPath
        } catch {
            return ""
        }
    }

    // MARK: - Asset Discovery

    public func autoDiscoverAssets() {
        let fileManager = FileManager.default

        let appSupportDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Niri").path ?? ""

        // Detect project root relative to bundle or current directory
        let searchRoots: [String] = [
            appSupportDir,
            "\(appSupportDir)/vm_images",
            "\(appSupportDir)/archlinux",
            "\(appSupportDir)/vms",
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

            let diskCandidates = [
                "\(root)/archlinux_disk.img",
                "\(root)/vms/archlinux_disk.img",
                "\(root)/vm/images/archlinux_disk.img"
            ]
            for cand in diskCandidates where fileManager.fileExists(atPath: cand) {
                if self.diskPath.isEmpty || !fileManager.fileExists(atPath: self.diskPath) {
                    self.diskPath = cand
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
        if let d = defaults.string(forKey: "niri.diskPath"), !d.isEmpty {
            diskPath = d
        }
        let dsize = defaults.integer(forKey: "niri.diskSizeGB")
        if dsize > 0 { diskSizeGB = dsize }

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
        defaults.set(diskSizeGB, forKey: "niri.diskSizeGB")
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
            if let mainScreen = NSScreen.main {
                let frame = mainScreen.frame
                return (Int(frame.width), Int(frame.height))
            }
            return (1920, 1080)
        }
    }
}
