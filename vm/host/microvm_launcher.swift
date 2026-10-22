#!/usr/bin/env swift
/**
 * vm/host/microvm_launcher.swift
 *
 * Native Apple Virtualization.framework MicroVM Runner for Niri on macOS (Apple Silicon).
 * Provides sub-200ms cold boot, virtio-vsock socket bridging, virtio-fs shared memory,
 * and virtio-gpu paravirtualized graphics display.
 */

import Foundation
import Virtualization
import Darwin

// MARK: - Configuration Structure
struct LauncherConfig {
    var kernelURL: URL?
    var initrdURL: URL?
    var diskURL: URL?
    var cpus: Int = min(4, ProcessInfo.processInfo.processorCount)
    var memoryMB: UInt64 = 2048
    var sharedDirPath: String = "/tmp/niri-shm"
    var vsockPort: UInt32 = 1024
    var waylandSocketPath: String = {
        if let xdg = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] {
            let p1 = "\(xdg)/wayland-1"
            if FileManager.default.fileExists(atPath: p1) { return p1 }
            let p0 = "\(xdg)/wayland-0"
            if FileManager.default.fileExists(atPath: p0) { return p0 }
            return p1
        }
        let fallback = "\(NSTemporaryDirectory())niri-wayland.sock"
        return fallback
    }()
    var cmdline: String = "console=hvc0 root=/dev/vda rw init=/init quiet"
}

// MARK: - CLI Argument Parser
func parseArguments() -> LauncherConfig {
    var config = LauncherConfig()
    let args = CommandLine.arguments

    var i = 1
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--kernel", "-k":
            if i + 1 < args.count {
                config.kernelURL = URL(fileURLWithPath: args[i + 1])
                i += 1
            }
        case "--initrd", "-i":
            if i + 1 < args.count {
                config.initrdURL = URL(fileURLWithPath: args[i + 1])
                i += 1
            }
        case "--disk", "-d":
            if i + 1 < args.count {
                config.diskURL = URL(fileURLWithPath: args[i + 1])
                i += 1
            }
        case "--cpus", "-c":
            if i + 1 < args.count, let c = Int(args[i + 1]) {
                config.cpus = c
                i += 1
            }
        case "--memory", "-m":
            if i + 1 < args.count, let m = UInt64(args[i + 1]) {
                config.memoryMB = m
                i += 1
            }
        case "--shared-dir", "-s":
            if i + 1 < args.count {
                config.sharedDirPath = args[i + 1]
                i += 1
            }
        case "--vsock-port", "-p":
            if i + 1 < args.count, let p = UInt32(args[i + 1]) {
                config.vsockPort = p
                i += 1
            }
        case "--wayland-socket", "-w":
            if i + 1 < args.count {
                config.waylandSocketPath = args[i + 1]
                i += 1
            }
        case "--cmdline":
            if i + 1 < args.count {
                config.cmdline = args[i + 1]
                i += 1
            }
        case "--help", "-h":
            printUsage()
            exit(0)
        default:
            fputs("[WARN] Unknown argument: \(arg)\n", stderr)
        }
        i += 1
    }
    return config
}

func printUsage() {
    print("""
    Niri Apple Virtualization MicroVM Launcher
    Usage: microvm_launcher [OPTIONS]

    Options:
      -k, --kernel <PATH>          Path to Linux kernel image (vmlinuz / Image)
      -i, --initrd <PATH>          Path to initial ramdisk (initramfs.cpio.gz)
      -d, --disk <PATH>            Path to raw root disk image
      -c, --cpus <COUNT>           Number of virtual CPUs (default: 4)
      -m, --memory <MB>            Memory size in megabytes (default: 2048)
      -s, --shared-dir <PATH>      Directory shared via virtio-fs (default: /tmp/niri-shm)
      -p, --vsock-port <PORT>      virtio-vsock listener port (default: 1024)
      -w, --wayland-socket <PATH>  Host Wayland socket to bridge into
      --cmdline <ARGS>             Linux kernel command-line arguments
      -h, --help                   Display this help message
    """)
}

// MARK: - Bidirectional Socket Forwarder
func bridgeSocket(clientFd: Int32, targetSocketPath: String) {
    let hostSock = socket(AF_UNIX, SOCK_STREAM, 0)
    guard hostSock >= 0 else {
        fputs("[BRIDGE] Failed to create AF_UNIX socket: \(errno)\n", stderr)
        close(clientFd)
        return
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathLen = targetSocketPath.utf8CString.count
    guard pathLen < MemoryLayout.size(ofValue: addr.sun_path) else {
        fputs("[BRIDGE] Wayland socket path too long\n", stderr)
        close(hostSock)
        close(clientFd)
        return
    }

    _ = targetSocketPath.withCString { cstr in
        strncpy(&addr.sun_path.0, cstr, MemoryLayout.size(ofValue: addr.sun_path) - 1)
    }

    let connectRes = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            connect(hostSock, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }

    if connectRes < 0 {
        fputs("[BRIDGE] Failed to connect to Wayland socket at \(targetSocketPath): \(errno)\n", stderr)
        close(hostSock)
        close(clientFd)
        return
    }

    print("[BRIDGE] Accepted vsock connection, bridged to \(targetSocketPath)")

    // Thread 1: vsock -> host UNIX socket
    DispatchQueue.global(qos: .userInteractive).async {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let bytesRead = read(clientFd, &buffer, buffer.count)
            if bytesRead <= 0 { break }
            var written = 0
            while written < bytesRead {
                let n = buffer.withUnsafeBytes { ptr in
                    write(hostSock, ptr.baseAddress!.advanced(by: written), bytesRead - written)
                }
                if n <= 0 { break }
                written += n
            }
        }
        close(hostSock)
        close(clientFd)
    }

    // Thread 2: host UNIX socket -> vsock
    DispatchQueue.global(qos: .userInteractive).async {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let bytesRead = read(hostSock, &buffer, buffer.count)
            if bytesRead <= 0 { break }
            var written = 0
            while written < bytesRead {
                let n = buffer.withUnsafeBytes { ptr in
                    write(clientFd, ptr.baseAddress!.advanced(by: written), bytesRead - written)
                }
                if n <= 0 { break }
                written += n
            }
        }
        close(hostSock)
        close(clientFd)
    }
}

// MARK: - VZVirtioSocketListenerDelegate
class VsockBridgeDelegate: NSObject, VZVirtioSocketListenerDelegate {
    let waylandSocketPath: String

    init(waylandSocketPath: String) {
        self.waylandSocketPath = waylandSocketPath
        super.init()
    }

    func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection) -> Bool {
        let fd = connection.fileDescriptor
        print("[VSOCK] New connection on vsock port \(connection.destinationPort) from guest CID \(connection.sourcePort)")
        bridgeSocket(clientFd: fd, targetSocketPath: self.waylandSocketPath)
        return true
    }
}

// MARK: - Main Execution
guard VZVirtualMachine.isSupported else {
    fputs("[FATAL] Apple Virtualization.framework is not supported on this host hardware.\n", stderr)
    exit(1)
}

let config = parseArguments()

guard let kernelURL = config.kernelURL, FileManager.default.fileExists(atPath: kernelURL.path) else {
    fputs("[FATAL] Missing or invalid Linux kernel path (--kernel <PATH>).\n", stderr)
    printUsage()
    exit(1)
}

// Ensure shared directory exists
try? FileManager.default.createDirectory(atPath: config.sharedDirPath, withIntermediateDirectories: true, attributes: nil)

let vmConfig = VZVirtualMachineConfiguration()
vmConfig.cpuCount = config.cpus
vmConfig.memorySize = config.memoryMB * 1024 * 1024

// Bootloader configuration
let bootloader = VZLinuxBootLoader(kernelURL: kernelURL)
if let initrdURL = config.initrdURL, FileManager.default.fileExists(atPath: initrdURL.path) {
    bootloader.initialRamdiskURL = initrdURL
}
bootloader.commandLine = config.cmdline
vmConfig.bootLoader = bootloader

// Console device (stdio)
let serialConfig = VZVirtioConsoleDeviceSerialPortConfiguration()
let stdioAttachment = VZFileHandleSerialPortAttachment(
    fileHandleForReading: FileHandle.standardInput,
    fileHandleForWriting: FileHandle.standardOutput
)
serialConfig.attachment = stdioAttachment
vmConfig.serialPorts = [serialConfig]

// virtio-fs shared directory
let sharedDir = VZSharedDirectory(url: URL(fileURLWithPath: config.sharedDirPath), readOnly: false)
let singleShare = VZSingleDirectoryShare(directory: sharedDir)
let fsConfig = VZVirtioFileSystemDeviceConfiguration(tag: "host_share")
fsConfig.share = singleShare
vmConfig.directorySharingDevices = [fsConfig]

// virtio-gpu paravirtualized graphics
let graphicsConfig = VZVirtioGraphicsDeviceConfiguration()
let scanoutConfig = VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1920, heightInPixels: 1080)
graphicsConfig.scanouts = [scanoutConfig]
vmConfig.graphicsDevices = [graphicsConfig]

// virtio-vsock device
let vsockConfig = VZVirtioSocketDeviceConfiguration()
vmConfig.socketDevices = [vsockConfig]

// Optional disk
if let diskURL = config.diskURL, FileManager.default.fileExists(atPath: diskURL.path) {
    do {
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
        let blockConfig = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)
        vmConfig.storageDevices = [blockConfig]
    } catch {
        fputs("[WARN] Could not attach disk image: \(error.localizedDescription)\n", stderr)
    }
}

// Validate configuration
do {
    try vmConfig.validate()
} catch {
    fputs("[FATAL] Invalid virtual machine configuration: \(error.localizedDescription)\n", stderr)
    exit(1)
}

let vm = VZVirtualMachine(configuration: vmConfig)

// Set up vsock listener
let vsockDelegate = VsockBridgeDelegate(waylandSocketPath: config.waylandSocketPath)
let listener = VZVirtioSocketListener()
listener.delegate = vsockDelegate

if let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice {
    socketDevice.setSocketListener(listener, forPort: config.vsockPort)
    print("[VSOCK] virtio-vsock listener attached to port \(config.vsockPort)")
}

print("""
============================================================
Niri MicroVM Runner (Apple Virtualization.framework)
vCPUs:       \(config.cpus)
Memory:      \(config.memoryMB) MB
Kernel:      \(kernelURL.path)
Shared Dir:  \(config.sharedDirPath)
VSOCK Port:  \(config.vsockPort)
Target Sock: \(config.waylandSocketPath)
============================================================
Starting MicroVM...
""")

let semaphore = DispatchSemaphore(value: 0)

vm.start { result in
    switch result {
    case .success:
        print("[VM] Linux MicroVM booted successfully!")
    case .failure(let error):
        fputs("[FATAL] MicroVM failed to boot: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

// Setup termination signals
signal(SIGINT) { _ in
    print("\n[VM] Stopping MicroVM...")
    exit(0)
}
signal(SIGTERM) { _ in
    print("\n[VM] Terminating...")
    exit(0)
}

// Keep main thread alive
RunLoop.main.run()
