//
//  LogStreamView.swift
//  Niri macOS GUI Launcher
//

import SwiftUI
import AppKit

public struct LogStreamView: View {
    @ObservedObject var logger: LogManager
    @State private var autoScroll: Bool = true

    public init(logger: LogManager) {
        self.logger = logger
    }

    public var body: some View {
        VStack(spacing: 0) {
            // MARK: - Toolbar Controls
            HStack(spacing: 12) {
                // Source Filter
                Picker("Filter", selection: $logger.filterSource) {
                    ForEach(LogSource.allCases) { src in
                        Text(src.rawValue).tag(src)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 380)

                // Search query
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search logs...", text: $logger.searchQuery)
                        .textFieldStyle(.plain)
                    if !logger.searchQuery.isEmpty {
                        Button(action: { logger.searchQuery = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.controlBackgroundColor)))

                Spacer()

                // Auto-scroll toggle
                Toggle(isOn: $autoScroll) {
                    Text("Auto-Scroll")
                        .font(.caption)
                }
                .toggleStyle(.checkbox)

                // Copy Button
                Button(action: {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(logger.copyAll(), forType: .string)
                }) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                // Clear Button
                Button(action: {
                    logger.clear()
                }) {
                    Label("Clear", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // MARK: - Terminal Console
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(logger.filteredEntries) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                // Timestamp
                                Text(entry.formattedTimestamp)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(width: 80, alignment: .leading)

                                // Source Tag
                                Text("[\(entry.source.rawValue)]")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(entry.source.badgeColor)
                                    .frame(width: 100, alignment: .leading)

                                // Message
                                Text(entry.message)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(entry.level == .error ? .red : (entry.level == .warn ? .yellow : .primary))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(entry.id)
                        }
                    }
                    .padding(12)
                }
                .background(Color(NSColor.textBackgroundColor).opacity(0.95))
                .onChange(of: logger.entries.count) {
                    if autoScroll, let last = logger.filteredEntries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}
