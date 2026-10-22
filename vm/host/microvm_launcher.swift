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
    var interactive: Bool = false
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

// MARK: - Interactive Terminal & Raw Mode Support
struct TerminalConfig {
    static var originalTermios = termios()
    static var isRawModeActive = false

    static func enableRawMode() {
        guard isatty(STDIN_FILENO) != 0 else { return }
        if tcgetattr(STDIN_FILENO, &originalTermios) == 0 {
            var raw = originalTermios
            cfmakeraw(&raw)
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
            isRawModeActive = true
        }
    }

    static func restore() {
        if isRawModeActive {
            tcsetattr(STDIN_FILENO, TCSANOW, &originalTermios)
            isRawModeActive = false
        }
    }
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
        case "--interactive", "-e", "--pty":
            config.interactive = true
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
      -e, --interactive, --pty     Enable raw interactive PTY mode for serial console
      --cmdline <ARGS>             Linux kernel command-line arguments
      -h, --help                   Display this help message
    """)
}

// MARK: - POSIX FD Passing Helper
func sendFd(sock: Int32, data: UnsafeRawPointer, count: Int, fdToPass: Int32) -> Int {
    guard fdToPass >= 0 else { return -1 }
    var iov = iovec(iov_base: UnsafeMutableRawPointer(mutating: data), iov_len: count)
    var cmsgBuf = [UInt8](repeating: 0, count: 16)
    cmsgBuf.withUnsafeMutableBytes { raw in
        let cmsg = raw.bindMemory(to: cmsghdr.self).baseAddress!
        cmsg.pointee.cmsg_len = 16
        cmsg.pointee.cmsg_level = SOL_SOCKET
        cmsg.pointee.cmsg_type = SCM_RIGHTS
        let dataPtr = raw.baseAddress!.advanced(by: 12).bindMemory(to: Int32.self, capacity: 1)
        dataPtr.pointee = fdToPass
    }

    var msg = msghdr()
    msg.msg_iov = withUnsafeMutablePointer(to: &iov) { $0 }
    msg.msg_iovlen = 1
    return cmsgBuf.withUnsafeMutableBytes { raw in
        msg.msg_control = raw.baseAddress
        msg.msg_controllen = socklen_t(raw.count)
        return sendmsg(sock, &msg, 0)
    }
}

func forwardWaylandBytes(hostSock: Int32, buffer: UnsafePointer<UInt8>, count: Int) {
    var offset = 0
    while offset < count {
        let remaining = count - offset
        if remaining < 8 {
            _ = buffer.advanced(by: offset).withMemoryRebound(to: UInt8.self, capacity: remaining) { ptr in
                write(hostSock, ptr, remaining)
            }
            break
        }

        let word2 = buffer.advanced(by: offset + 4).withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
        let opcode = UInt16(word2 & 0xFFFF)
        let msgLen = Int(word2 >> 16)

        if msgLen < 8 || msgLen > remaining {
            _ = buffer.advanced(by: offset).withMemoryRebound(to: UInt8.self, capacity: remaining) { ptr in
                write(hostSock, ptr, remaining)
            }
            break
        }

        let isCreatePool = (opcode == 0 && msgLen == 16 && remaining >= 16 && {
            let poolSize = buffer.advanced(by: offset + 12).withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
            return poolSize >= 1024
        }())

        if isCreatePool {
            let rawPoolSize = buffer.advanced(by: offset + 12).withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
            // Bounds check poolSize (max 256 MB) to prevent excessive disk/memory allocation
            let boundedPoolSize = min(rawPoolSize, 256 * 1024 * 1024)
            if let template = strdup("/tmp/niri_shm_XXXXXX") {
                let hostFd = mkstemp(template)
                unlink(template)
                free(template)
                if hostFd >= 0 {
                    ftruncate(hostFd, off_t(boundedPoolSize))
                    print("[BRIDGE] Intercepted wl_shm.create_pool(size=\(boundedPoolSize)), injecting host FD \(hostFd)")
                    fflush(stdout)
                    _ = sendFd(sock: hostSock, data: buffer.advanced(by: offset), count: msgLen, fdToPass: hostFd)
                    close(hostFd)
                } else {
                    fputs("[BRIDGE] Failed to create temporary anonymous SHM file: errno \(errno)\n", stderr)
                }
            }
        } else {
            _ = buffer.advanced(by: offset).withMemoryRebound(to: UInt8.self, capacity: msgLen) { ptr in
                write(hostSock, ptr, msgLen)
            }
        }

        offset += msgLen
    }
}

// MARK: - Bidirectional Socket Forwarder
func bridgeSocket(connection: VZVirtioSocketConnection, targetSocketPath: String) {
    let clientFd = connection.fileDescriptor
    let clientFlags = fcntl(clientFd, F_GETFL)
    print("[BRIDGE] clientFd=\(clientFd), flags=\(clientFlags), isNonBlocking=\((clientFlags & O_NONBLOCK) != 0)")
    fflush(stdout)
    // Ensure blocking I/O for worker threads
    if (clientFlags & O_NONBLOCK) != 0 {
        _ = fcntl(clientFd, F_SETFL, clientFlags & ~O_NONBLOCK)
    }

    let hostSock = socket(AF_UNIX, SOCK_STREAM, 0)
    guard hostSock >= 0 else {
        fputs("[BRIDGE] Failed to create AF_UNIX socket: \(errno)\n", stderr)
        return
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathLen = targetSocketPath.utf8CString.count
    guard pathLen < MemoryLayout.size(ofValue: addr.sun_path) else {
        fputs("[BRIDGE] Wayland socket path too long\n", stderr)
        close(hostSock)
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
        return
    }

    print("[BRIDGE] Accepted vsock connection, bridged to \(targetSocketPath)")

    // Thread 1: vsock -> host UNIX socket
    DispatchQueue.global(qos: .userInteractive).async {
        _ = connection // Retain connection
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let bytesRead = read(clientFd, &buffer, buffer.count)
            if bytesRead <= 0 {
                fputs("[BRIDGE] Thread 1 read from vsock ended: \(bytesRead), errno=\(errno)\n", stderr)
                fflush(stderr)
                break
            }
            print("[BRIDGE] Read \(bytesRead) bytes from vsock, forwarding to hostSock")
            fflush(stdout)
            buffer.withUnsafeBytes { ptr in
                forwardWaylandBytes(hostSock: hostSock, buffer: ptr.bindMemory(to: UInt8.self).baseAddress!, count: bytesRead)
            }
        }
        close(hostSock)
    }

    // Thread 2: host UNIX socket -> vsock
    DispatchQueue.global(qos: .userInteractive).async {
        _ = connection // Retain connection
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
    }
}

// MARK: - VZVirtualMachineDelegate
class VMDelegate: NSObject, VZVirtualMachineDelegate {
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        print("\n[VM] Guest powered off cleanly.")
        TerminalConfig.restore()
        exit(0)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        fputs("\n[VM] Guest stopped with error: \(error.localizedDescription)\n", stderr)
        TerminalConfig.restore()
        exit(1)
    }
}

// MARK: - VZVirtioSocketListenerDelegate
class VsockBridgeDelegate: NSObject, VZVirtioSocketListenerDelegate {
    let waylandSocketPath: String
    var connections: [VZVirtioSocketConnection] = []
    let lock = NSLock()

    init(waylandSocketPath: String) {
        self.waylandSocketPath = waylandSocketPath
        super.init()
    }

    func listener(_ listener: VZVirtioSocketListener, shouldAcceptNewConnection connection: VZVirtioSocketConnection, from socketDevice: VZVirtioSocketDevice) -> Bool {
        print("[VSOCK] New connection on vsock port \(connection.destinationPort) from guest CID \(connection.sourcePort)")
        lock.lock()
        connections.append(connection)
        lock.unlock()
        bridgeSocket(connection: connection, targetSocketPath: self.waylandSocketPath)
        return true
    }
}

// MARK: - Main Execution
// Unbuffered stdio for instantaneous interactive keystrokes and output streaming
setvbuf(stdout, nil, _IONBF, 0)
setvbuf(stderr, nil, _IONBF, 0)
setvbuf(stdin, nil, _IONBF, 0)

guard VZVirtualMachine.isSupported else {
    fputs("[FATAL] Apple Virtualization.framework is not supported on this host hardware.\n", stderr)
    exit(1)
}

let config = parseArguments()

// Configure interactive raw mode if requested or if attached to a live terminal
if config.interactive || isatty(STDIN_FILENO) != 0 {
    TerminalConfig.enableRawMode()
}

atexit {
    TerminalConfig.restore()
}

guard let kernelURL = config.kernelURL, FileManager.default.fileExists(atPath: kernelURL.path) else {
    TerminalConfig.restore()
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

// virtio-net NAT network configuration for internet connectivity (pacman, firefox, etc.)
let netConfig = VZVirtioNetworkDeviceConfiguration()
netConfig.attachment = VZNATNetworkDeviceAttachment()
vmConfig.networkDevices = [netConfig]

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
var g_vmDelegate: VMDelegate? = VMDelegate()
vm.delegate = g_vmDelegate

// Set up vsock listener strongly retained to avoid ARC deallocation
var g_vsockDelegate: VsockBridgeDelegate? = VsockBridgeDelegate(waylandSocketPath: config.waylandSocketPath)
var g_vsockListener: VZVirtioSocketListener? = VZVirtioSocketListener()
g_vsockListener?.delegate = g_vsockDelegate

if let socketDevice = vm.socketDevices.first as? VZVirtioSocketDevice, let listener = g_vsockListener {
    socketDevice.setSocketListener(listener, forPort: config.vsockPort)
    print("[VSOCK] virtio-vsock listener attached to port \(config.vsockPort) (target: \(config.waylandSocketPath))")
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
    TerminalConfig.restore()
    print("\n[VM] Stopping MicroVM...")
    exit(0)
}
signal(SIGTERM) { _ in
    TerminalConfig.restore()
    print("\n[VM] Terminating...")
    exit(0)
}

// Keep main thread alive
RunLoop.main.run()
