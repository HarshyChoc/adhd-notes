import Foundation
import CoreGraphics

/// Represents a single sticky note plus its sync metadata.
struct Note: Identifiable, Codable, Equatable {
    /// Unique identifier for the note
    let id: UUID

    /// Markdown content of the note
    var content: String

    /// Window position on screen
    var position: CGPoint

    /// Window size
    var size: CGSize

    /// Whether the window is minimized
    var isMinimized: Bool

    /// Window opacity (0.0 to 1.0)
    var opacity: Double

    /// Color theme name (yellow, pink, blue, green, purple, orange)
    var colorTheme: String

    /// Cursor position (character offset) for restoring on reopen
    var cursorPosition: Int

    /// Scroll position (pixels from top) for restoring on reopen
    var scrollTop: Double

    /// Whether this note should always stay on top of other windows
    var alwaysOnTop: Bool

    /// Synced Google Tasks list id for this note
    var taskListId: String?

    /// Cached Google Tasks list title for local UI
    var taskListNameCache: String?

    /// Due date in YYYY-MM-DD form (date-only by product/API design)
    var dueDate: String?

    /// Current local sync state shown in the UI
    var syncState: NoteSyncState

    /// Canonical server version from backend
    var serverVersion: Int

    /// Canonical server update timestamp from backend
    var serverUpdatedAt: Date?

    /// Reason a tombstoned note was removed
    var deletionReason: String?

    /// Tombstone marker for local persistence
    var deletedAt: Date?

    /// Creation timestamp
    let createdAt: Date

    /// Last modification timestamp
    var modifiedAt: Date

    init(
        id: UUID = UUID(),
        content: String = "",
        position: CGPoint = CGPoint(x: 100, y: 100),
        size: CGSize = CGSize(width: 300, height: 360),
        isMinimized: Bool = false,
        opacity: Double = 0.95,
        colorTheme: String = "yellow",
        cursorPosition: Int = 0,
        scrollTop: Double = 0,
        alwaysOnTop: Bool = false,
        taskListId: String? = nil,
        taskListNameCache: String? = nil,
        dueDate: String? = nil,
        syncState: NoteSyncState = .localOnly,
        serverVersion: Int = 0,
        serverUpdatedAt: Date? = nil,
        deletionReason: String? = nil,
        deletedAt: Date? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.content = content
        self.position = position
        self.size = size
        self.isMinimized = isMinimized
        self.opacity = opacity
        self.colorTheme = colorTheme
        self.cursorPosition = cursorPosition
        self.scrollTop = scrollTop
        self.alwaysOnTop = alwaysOnTop
        self.taskListId = taskListId
        self.taskListNameCache = taskListNameCache
        self.dueDate = dueDate
        self.syncState = syncState
        self.serverVersion = serverVersion
        self.serverUpdatedAt = serverUpdatedAt
        self.deletionReason = deletionReason
        self.deletedAt = deletedAt
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    mutating func updateModificationDate() {
        modifiedAt = Date()
    }
}

extension Note {
    enum CodingKeys: String, CodingKey {
        case id
        case content
        case position
        case size
        case isMinimized
        case opacity
        case colorTheme
        case cursorPosition
        case scrollTop
        case alwaysOnTop
        case taskListId
        case taskListNameCache
        case dueDate
        case syncState
        case serverVersion
        case serverUpdatedAt
        case deletionReason
        case deletedAt
        case createdAt
        case modifiedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        content = try container.decode(String.self, forKey: .content)

        let positionDict = try container.decode([String: Double].self, forKey: .position)
        position = CGPoint(x: positionDict["x"] ?? 100, y: positionDict["y"] ?? 100)

        let sizeDict = try container.decode([String: Double].self, forKey: .size)
        size = CGSize(width: sizeDict["width"] ?? 300, height: sizeDict["height"] ?? 360)

        isMinimized = try container.decode(Bool.self, forKey: .isMinimized)
        opacity = try container.decode(Double.self, forKey: .opacity)
        colorTheme = try container.decodeIfPresent(String.self, forKey: .colorTheme) ?? "yellow"
        cursorPosition = try container.decodeIfPresent(Int.self, forKey: .cursorPosition) ?? 0
        scrollTop = try container.decodeIfPresent(Double.self, forKey: .scrollTop) ?? 0
        alwaysOnTop = try container.decodeIfPresent(Bool.self, forKey: .alwaysOnTop) ?? false
        taskListId = try container.decodeIfPresent(String.self, forKey: .taskListId)
        taskListNameCache = try container.decodeIfPresent(String.self, forKey: .taskListNameCache)
        dueDate = try container.decodeIfPresent(String.self, forKey: .dueDate)
        syncState = try container.decodeIfPresent(NoteSyncState.self, forKey: .syncState) ?? .localOnly
        serverVersion = try container.decodeIfPresent(Int.self, forKey: .serverVersion) ?? 0
        serverUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .serverUpdatedAt)
        deletionReason = try container.decodeIfPresent(String.self, forKey: .deletionReason)
        deletedAt = try container.decodeIfPresent(Date.self, forKey: .deletedAt)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(content, forKey: .content)
        try container.encode(["x": position.x, "y": position.y], forKey: .position)
        try container.encode(["width": size.width, "height": size.height], forKey: .size)
        try container.encode(isMinimized, forKey: .isMinimized)
        try container.encode(opacity, forKey: .opacity)
        try container.encode(colorTheme, forKey: .colorTheme)
        try container.encode(cursorPosition, forKey: .cursorPosition)
        try container.encode(scrollTop, forKey: .scrollTop)
        try container.encode(alwaysOnTop, forKey: .alwaysOnTop)
        try container.encode(taskListId, forKey: .taskListId)
        try container.encode(taskListNameCache, forKey: .taskListNameCache)
        try container.encode(dueDate, forKey: .dueDate)
        try container.encode(syncState, forKey: .syncState)
        try container.encode(serverVersion, forKey: .serverVersion)
        try container.encode(serverUpdatedAt, forKey: .serverUpdatedAt)
        try container.encode(deletionReason, forKey: .deletionReason)
        try container.encode(deletedAt, forKey: .deletedAt)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
    }
}
