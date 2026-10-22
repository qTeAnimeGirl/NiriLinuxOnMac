//
//  VMManagerView.swift
//  Niri macOS GUI Launcher
//

import SwiftUI
import AppKit

public struct VMManagerView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var config: LauncherConfig
    @ObservedObject var microvm: MicroVMManager

    @State private var newDiskName: String = "archlinux_storage_40G.img"
    @State private var selectedSizeGB: Int = 40
    @State private var showWipeConfirmation: Bool = false
    @State private var diskToWipe: String = ""
    @State private var showDeleteConfirmation: Bool = false
    @State private var diskToDelete: String = ""
    @State private var statusAlertMessage: String = ""
    @State private var showStatusAlert: Bool = false

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.config = coordinator.config
        self.microvm = coordinator.microvm
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MicroVM & Storage Manager")
                            .font(.system(size: 24, weight: .bold))
                        Text("Manage Arch Linux persistent virtual disks, hardware allocation, and guest storage.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    // Quick VM Controls
                    HStack(spacing: 10) {
                        if microvm.isRunning {
                            Button(action: {
                                microvm.stop()
                            }) {
                                Label("Stop MicroVM", systemImage: "stop.fill")
                                    .foregroundColor(.red)
                            }
                        } else {
                            Button(action: {
                                startMicroVM()
                            }) {
                                Label("Start MicroVM", systemImage: "play.fill")
                                    .foregroundColor(.green)
                            }
                        }

                        Button(action: {
                            config.refreshDisksList()
                        }) {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Refresh disk list")
                    }
                }

                Divider()

                // VM Runtime Status Card
                GroupBox(label: Label("MicroVM Hardware Allocation", systemImage: "cpu").font(.headline)) {
                    VStack(spacing: 12) {
                        HStack {
                            Circle()
                                .fill(microvm.isRunning ? Color.green : Color.secondary)
                                .frame(width: 10, height: 10)
                            Text(microvm.isRunning ? "MicroVM Running (PID \(microvm.pid))" : "MicroVM Offline")
                                .font(.headline)
                            Spacer()
                            if microvm.isRunning && microvm.bootDurationMs > 0 {
                                Text(String(format: "Cold boot: %.1f ms", microvm.bootDurationMs))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Divider()

                        HStack(spacing: 24) {
                            StatBox(title: "vCPUs", value: "\(config.vCPUs)", icon: "cpu")
                            StatBox(title: "RAM Allocation", value: "\(config.memoryMB) MB", icon: "memorychip")
                            StatBox(title: "Active Disk Size", value: activeDiskSizeString, icon: "internaldrive")
                            StatBox(title: "IPC Vsock Port", value: "\(config.vsockPort)", icon: "network")
                        }
                    }
                    .padding(10)
                }

                // Create New Virtual Disk Section
                GroupBox(label: Label("Create Persistent Virtual Disk", systemImage: "plus.circle.fill").font(.headline)) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Create a high-performance APFS sparse virtual disk. APFS sparse files allocate 0 KB initially and dynamically expand on-demand as packages like Firefox are installed.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Disk Image Filename")
                                    .font(.caption.bold())
                                TextField("e.g. archlinux_storage.img", text: $newDiskName)
                                    .textFieldStyle(.roundedBorder)
                            }
                            .frame(minWidth: 240)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Storage Capacity")
                                    .font(.caption.bold())
                                HStack(spacing: 8) {
                                    presetButton(10, label: "10 GB")
                                    presetButton(20, label: "20 GB")
                                    presetButton(40, label: "40 GB (Recommended)")
                                    presetButton(64, label: "64 GB")
                                    presetButton(128, label: "128 GB")
                                }
                            }
                        }

                        HStack {
                            Slider(value: Binding(
                                get: { Double(selectedSizeGB) },
                                set: { selectedSizeGB = Int($0) }
                            ), in: 5...256, step: 5)
                            Text("\(selectedSizeGB) GB")
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 70, alignment: .trailing)
                        }

                        HStack {
                            Spacer()
                            Button(action: {
                                createDisk()
                            }) {
                                Label("Create & Mount Virtual Disk", systemImage: "plus.circle")
                                    .font(.headline)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(10)
                }

                // Available Disks List
                GroupBox(label: Label("Available Virtual Disks", systemImage: "internaldrive.fill").font(.headline)) {
                    VStack(alignment: .leading, spacing: 12) {
                        if config.availableDisks.isEmpty {
                            VStack(spacing: 8) {
                                Text("No virtual disks detected.")
                                    .foregroundColor(.secondary)
                                Button("Create Default 20GB Disk") {
                                    config.ensureDefaultDiskExists()
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 80)
                        } else {
                            ForEach(config.availableDisks) { disk in
                                DiskRowView(
                                    disk: disk,
                                    isVMRunning: microvm.isRunning,
                                    onSelect: {
                                        config.selectDisk(at: disk.path)
                                    },
                                    onWipe: {
                                        diskToWipe = disk.path
                                        showWipeConfirmation = true
                                    },
                                    onDelete: {
                                        diskToDelete = disk.path
                                        showDeleteConfirmation = true
                                    }
                                )
                                Divider()
                            }
                        }
                    }
                    .padding(10)
                }

                // Persistence Architecture Guide
                GroupBox(label: Label("Arch Linux Guest Persistence Architecture", systemImage: "info.circle").font(.headline)) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("• **Block Device:** The virtual disk attaches as `/dev/vda` (virtio-blk).")
                            .font(.caption)
                        Text("• **Automated Formatting:** If `/dev/vda` is fresh, `init.sh` automatically formats it as ext4.")
                            .font(.caption)
                        Text("• **OverlayFS Persistence:** `/dev/vda` mounts at `/mnt/storage`. OverlayFS layers over `/usr`, `/var`, `/etc`, `/root`, and binds `/home`.")
                            .font(.caption)
                        Text("• **Package Installation:** `pacman -S <pkg>` saves all downloaded packages and extracted files directly to the virtual disk, surviving reboots.")
                            .font(.caption)
                    }
                    .padding(10)
                }
            }
            .padding(24)
        }
        .confirmationDialog(
            "Wipe Storage (Factory Reset)?",
            isPresented: $showWipeConfirmation,
            titleVisibility: .visible
        ) {
            Button("Wipe All Data & Re-format", role: .destructive) {
                wipeDisk(path: diskToWipe)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will wipe all installed packages and configuration on the selected disk. On next boot, Arch Linux will reformat it as a clean empty drive.")
        }
        .confirmationDialog(
            "Delete Virtual Disk?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Permanently Delete Disk Image", role: .destructive) {
                deleteDisk(path: diskToDelete)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete the virtual disk image file from your Mac. This action cannot be undone.")
        }
        .alert(isPresented: $showStatusAlert) {
            Alert(title: Text("Storage Manager"), message: Text(statusAlertMessage), dismissButton: .default(Text("OK")))
        }
    }

    private var activeDiskSizeString: String {
        if let active = config.availableDisks.first(where: { $0.isCurrentlySelected }) {
            return active.logicalSizeGBString
        }
        return "\(config.diskSizeGB) GB"
    }

    private func presetButton(_ size: Int, label: String) -> some View {
        Button(action: {
            selectedSizeGB = size
            newDiskName = "archlinux_storage_\(size)G.img"
        }) {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(selectedSizeGB == size ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    private func createDisk() {
        do {
            let path = try config.createVirtualDisk(name: newDiskName, sizeGB: selectedSizeGB)
            statusAlertMessage = "Created virtual disk with \(selectedSizeGB) GB capacity at:\n\(path)"
            showStatusAlert = true
        } catch {
            statusAlertMessage = "Failed to create disk: \(error.localizedDescription)"
            showStatusAlert = true
        }
    }

    private func wipeDisk(path: String) {
        do {
            try config.wipeVirtualDisk(at: path)
            statusAlertMessage = "Storage wiped successfully. Next MicroVM boot will format a pristine ext4 filesystem."
            showStatusAlert = true
        } catch {
            statusAlertMessage = "Failed to wipe disk: \(error.localizedDescription)"
            showStatusAlert = true
        }
    }

    private func deleteDisk(path: String) {
        if microvm.isRunning && config.diskPath == path {
            statusAlertMessage = "Cannot delete the active disk while the MicroVM is running. Please stop the MicroVM first."
            showStatusAlert = true
            return
        }
        do {
            try config.deleteVirtualDisk(at: path)
            statusAlertMessage = "Virtual disk deleted."
            showStatusAlert = true
        } catch {
            statusAlertMessage = "Failed to delete disk: \(error.localizedDescription)"
            showStatusAlert = true
        }
    }

    private func startMicroVM() {
        let waylandSock = coordinator.compositor.waylandSocketPath
        microvm.start(config: config, waylandSocket: waylandSock) { success in
            if !success {
                statusAlertMessage = "MicroVM failed to boot. Check logs for details."
                showStatusAlert = true
            }
        }
    }
}

private struct DiskRowView: View {
    let disk: VirtualDiskInfo
    let isVMRunning: Bool
    let onSelect: () -> Void
    let onWipe: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "internaldrive")
                .font(.title2)
                .foregroundColor(disk.isCurrentlySelected ? .accentColor : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(disk.name)
                        .font(.headline)
                    if disk.isCurrentlySelected {
                        Text("ACTIVE")
                            .font(.caption2.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green)
                            .cornerRadius(4)
                    }
                }

                Text(disk.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                HStack(spacing: 12) {
                    Text("Capacity: \(disk.logicalSizeGBString)")
                        .font(.caption2)
                    Text("Used on Mac: \(disk.physicalSizeMBString)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("(\(disk.savingsRatioString))")
                        .font(.caption2)
                        .foregroundColor(.green)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                if !disk.isCurrentlySelected {
                    Button("Select") {
                        onSelect()
                    }
                    .font(.caption)
                    .disabled(isVMRunning)
                }

                Button(action: onWipe) {
                    Label("Wipe", systemImage: "arrow.counterclockwise")
                        .font(.caption)
                }
                .disabled(isVMRunning && disk.isCurrentlySelected)
                .help("Reset storage to clean unformatted state")

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .disabled(isVMRunning && disk.isCurrentlySelected)
                .help("Delete virtual disk image")
            }
        }
        .padding(.vertical, 4)
    }
}

private struct StatBox: View {
    let title: String
    let value: String
    let icon: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(value)
                    .font(.headline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
