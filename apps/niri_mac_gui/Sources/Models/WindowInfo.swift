//
//  WindowInfo.swift
//  Niri macOS GUI Launcher
//

import Foundation

public struct WindowInfo: Identifiable, Codable, Equatable {
    public let id: UInt64
    public let title: String?
    public let app_id: String?
    public let pid: Int32?
    public let workspace_id: UInt64?
    public let is_focused: Bool
    public let is_floating: Bool

    public var displayTitle: String {
        title ?? "(Untitled)"
    }

    public var displayAppId: String {
        app_id ?? "(Unknown App)"
    }

    public var displayLayout: String {
        is_floating ? "Floating" : "Tiling"
    }

    public var displayPid: String {
        if let p = pid { return "\(p)" }
        return "-"
    }
}
