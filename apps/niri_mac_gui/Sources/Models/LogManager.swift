//
//  LogManager.swift
//  Niri macOS GUI Launcher
//

import Foundation
import Combine
import SwiftUI

public enum LogSource: String, CaseIterable, Identifiable {
    case all = "All"
    case niri = "Niri"
    case microvm = "MicroVM"
    case bridge = "VSOCK Bridge"
    case install = "Installer"
    case system = "System"

    public var id: String { rawValue }

    public var badgeColor: Color {
        switch self {
        case .niri: return .cyan
        case .microvm: return .green
        case .bridge: return .yellow
        case .install: return .purple
        case .system: return .orange
        case .all: return .primary
        }
    }
}

public enum LogLevel: String {
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
    case debug = "DEBUG"

    public var color: Color {
        switch self {
        case .info: return .primary
        case .warn: return .yellow
        case .error: return .red
        case .debug: return .secondary
        }
    }
}

public struct LogEntry: Identifiable, Equatable {
    public let id = UUID()
    public let timestamp: Date
    public let source: LogSource
    public let level: LogLevel
    public let message: String

    public var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }
}

public final class LogManager: ObservableObject {
    public static let shared = LogManager()

    @Published public var entries: [LogEntry] = []
    @Published public var filterSource: LogSource = .all
    @Published public var searchQuery: String = ""

    private let maxEntries = 5000
    private let queue = DispatchQueue(label: "org.niri.log-manager", qos: .utility)

    public init() {
        append(source: .system, message: "Niri macOS Unified Launcher initialized")
    }

    public func append(source: LogSource, message: String, level: LogLevel = .info) {
        let clean = message.trimmingCharacters(in: .newlines)
        guard !clean.isEmpty else { return }

        // Split multiple lines if necessary
        let lines = clean.components(separatedBy: .newlines)
        let now = Date()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for line in lines {
                let entry = LogEntry(
                    timestamp: now,
                    source: source,
                    level: level,
                    message: line
                )
                self.entries.append(entry)
            }
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
    }

    public var filteredEntries: [LogEntry] {
        entries.filter { entry in
            let matchesSource = (filterSource == .all) || (entry.source == filterSource)
            if !matchesSource { return false }
            if searchQuery.isEmpty { return true }
            return entry.message.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    public func clear() {
        DispatchQueue.main.async {
            self.entries.removeAll()
        }
    }

    public func copyAll() -> String {
        entries.map { "[\($0.formattedTimestamp)] [\($0.source.rawValue)] [\($0.level.rawValue)] \($0.message)" }
            .joined(separator: "\n")
    }
}
