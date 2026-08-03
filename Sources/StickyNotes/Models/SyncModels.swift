import Foundation

enum NoteSyncState: String, Codable, CaseIterable {
    case localOnly
    case pending
    case synced
    case error
}

enum SyncMutationType: String, Codable {
    case upsertNote = "upsert_note"
    case deleteNote = "delete_note"
}

struct TaskListInfo: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var isSelected: Bool
    var isDefault: Bool
}

struct SyncSessionState: Codable, Equatable {
    static let productionBackendBaseURL = "https://backend-production-15d8.up.railway.app"

    var customBackendBaseURL: String?
    var useCustomBackendBaseURL: Bool
    var lastEventSequence: Int
    var lastSyncStartedAt: Date?
    var lastSyncCompletedAt: Date?
    var lastSyncResult: String?
    var isManualSyncInFlight: Bool

    var effectiveBackendBaseURL: String {
        if useCustomBackendBaseURL,
           let customBackendBaseURL,
           !customBackendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return customBackendBaseURL
        }
        return Self.productionBackendBaseURL
    }

    static var defaultValue: SyncSessionState {
        SyncSessionState(
            customBackendBaseURL: nil,
            useCustomBackendBaseURL: false,
            lastEventSequence: 0,
            lastSyncStartedAt: nil,
            lastSyncCompletedAt: nil,
            lastSyncResult: nil,
            isManualSyncInFlight: false
        )
    }

    private enum CodingKeys: String, CodingKey {
        case backendBaseURL
        case customBackendBaseURL
        case useCustomBackendBaseURL
        case lastEventSequence
        case lastSyncStartedAt
        case lastSyncCompletedAt
        case lastSyncResult
        case isManualSyncInFlight
    }

    init(
        customBackendBaseURL: String?,
        useCustomBackendBaseURL: Bool,
        lastEventSequence: Int,
        lastSyncStartedAt: Date?,
        lastSyncCompletedAt: Date?,
        lastSyncResult: String?,
        isManualSyncInFlight: Bool
    ) {
        self.customBackendBaseURL = customBackendBaseURL
        self.useCustomBackendBaseURL = useCustomBackendBaseURL
        self.lastEventSequence = lastEventSequence
        self.lastSyncStartedAt = lastSyncStartedAt
        self.lastSyncCompletedAt = lastSyncCompletedAt
        self.lastSyncResult = lastSyncResult
        self.isManualSyncInFlight = isManualSyncInFlight
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyBackendBaseURL = try container.decodeIfPresent(String.self, forKey: .backendBaseURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let decodedCustomBackendBaseURL = try container.decodeIfPresent(String.self, forKey: .customBackendBaseURL)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let migratedCustomBackendBaseURL: String?
        if let decodedCustomBackendBaseURL, !decodedCustomBackendBaseURL.isEmpty {
            migratedCustomBackendBaseURL = decodedCustomBackendBaseURL
        } else if let legacyBackendBaseURL,
                  !legacyBackendBaseURL.isEmpty,
                  legacyBackendBaseURL != Self.productionBackendBaseURL {
            migratedCustomBackendBaseURL = legacyBackendBaseURL
        } else {
            migratedCustomBackendBaseURL = nil
        }

        let useCustomBackendBaseURL = try container.decodeIfPresent(Bool.self, forKey: .useCustomBackendBaseURL)
            ?? (migratedCustomBackendBaseURL != nil)

        self.init(
            customBackendBaseURL: migratedCustomBackendBaseURL,
            useCustomBackendBaseURL: useCustomBackendBaseURL,
            lastEventSequence: try container.decodeIfPresent(Int.self, forKey: .lastEventSequence) ?? 0,
            lastSyncStartedAt: try container.decodeIfPresent(Date.self, forKey: .lastSyncStartedAt),
            lastSyncCompletedAt: try container.decodeIfPresent(Date.self, forKey: .lastSyncCompletedAt),
            lastSyncResult: try container.decodeIfPresent(String.self, forKey: .lastSyncResult),
            isManualSyncInFlight: try container.decodeIfPresent(Bool.self, forKey: .isManualSyncInFlight) ?? false
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(customBackendBaseURL, forKey: .customBackendBaseURL)
        try container.encode(useCustomBackendBaseURL, forKey: .useCustomBackendBaseURL)
        try container.encode(lastEventSequence, forKey: .lastEventSequence)
        try container.encodeIfPresent(lastSyncStartedAt, forKey: .lastSyncStartedAt)
        try container.encodeIfPresent(lastSyncCompletedAt, forKey: .lastSyncCompletedAt)
        try container.encodeIfPresent(lastSyncResult, forKey: .lastSyncResult)
        try container.encode(isManualSyncInFlight, forKey: .isManualSyncInFlight)
    }
}

struct QueuedMutation: Identifiable, Codable, Equatable {
    let id: String
    let coalesceKey: String
    let noteId: String
    let type: SyncMutationType
    var baseServerVersion: Int
    let payloadJSON: String
    let createdAt: Date
    var updatedAt: Date
}

struct ServerNoteDTO: Codable, Equatable {
    let id: String
    let title: String
    let bodyMarkdown: String
    let bodyPlaintext: String
    let taskListId: String?
    let taskListNameCache: String?
    let googleTaskId: String?
    let dueDate: String?
    let serverVersion: Int
    let serverUpdatedAt: Date
    let deletedAt: Date?
    let deletionReason: String?
    let pendingProjection: Bool
    let lastProjectionError: String?
}

struct BootstrapResponse: Codable {
    let notes: [ServerNoteDTO]
    let taskLists: [TaskListInfo]
    let deletedNoteIds: [String]?
    let tombstones: [ServerDeletePayload]?
    let latestSequence: Int
}

struct SessionExchangeResponse: Codable {
    let sessionToken: String
    let expiresAt: Date
    let bootstrap: BootstrapResponse
}

struct TaskListsResponse: Codable {
    let taskLists: [TaskListInfo]
}

struct MutationsResponse: Codable {
    let latestSequence: Int
    let results: [MutationResultDTO]
}

enum MutationResultStatus: String, Codable {
    case applied
    case duplicate
    case conflict
}

struct MutationResultDTO: Codable {
    let id: String
    let status: MutationResultStatus
    let note: ServerNoteDTO?
    let tombstone: ServerDeletePayload?
}

struct SyncNowResponse: Codable {
    let latestSequence: Int
    let syncedAt: Date
    let status: String?
}

struct ServerEventEnvelope: Codable {
    let sequence: Int
    let type: String
    let payload: EventPayload
}

enum EventPayload: Codable, Equatable {
    case noteUpsert(ServerNotePayload)
    case noteDelete(ServerDeletePayload)
    case preferences(PreferencesPayload)
    case raw([String: String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let payload = try? container.decode(ServerNotePayload.self) {
            self = .noteUpsert(payload)
            return
        }
        if let payload = try? container.decode(ServerDeletePayload.self) {
            self = .noteDelete(payload)
            return
        }
        if let payload = try? container.decode(PreferencesPayload.self) {
            self = .preferences(payload)
            return
        }
        self = .raw((try? container.decode([String: String].self)) ?? [:])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .noteUpsert(let payload):
            try container.encode(payload)
        case .noteDelete(let payload):
            try container.encode(payload)
        case .preferences(let payload):
            try container.encode(payload)
        case .raw(let payload):
            try container.encode(payload)
        }
    }
}

struct ServerNotePayload: Codable, Equatable {
    let note: ServerNoteDTO
}

struct ServerDeletePayload: Codable, Equatable {
    let noteId: String
    let deletionReason: String
    let serverVersion: Int
    let serverUpdatedAt: Date
}

struct PreferencesPayload: Codable, Equatable {
    let selectedTaskListIds: [String]
    let defaultTaskListId: String?
}
