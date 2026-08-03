import Foundation
import AppKit

@MainActor
final class SyncManager: ObservableObject {
    @Published private(set) var taskLists: [TaskListInfo]
    @Published private(set) var syncSessionState: SyncSessionState
    @Published private(set) var isAuthenticated: Bool
    @Published private(set) var syncErrorMessage: String?

    var onRemoteNoteApplied: ((Note) -> Void)?
    var onRemoteNoteDeleted: ((UUID) -> Void)?

    private let persistenceManager: PersistenceManager
    private let noteManager: NoteManager
    private let sessionKeychain = KeychainHelper(
        service: "com.mdstickynotes.backend-session",
        account: "MD Sticky Notes backend session"
    )
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var eventStreamTask: Task<Void, Never>?
    private var pendingFlushTask: Task<Void, Never>?
    private var sessionToken: String?

    init(persistenceManager: PersistenceManager, noteManager: NoteManager) {
        self.persistenceManager = persistenceManager
        self.noteManager = noteManager
        self.taskLists = persistenceManager.loadTaskLists()
        self.syncSessionState = persistenceManager.loadSyncSessionState()
        self.sessionToken = sessionKeychain.loadString()
        self.isAuthenticated = sessionToken != nil

        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    func start() {
        guard isAuthenticated else { return }
        Task {
            await bootstrapAndConnect()
        }
    }

    func backendBaseURL() -> String {
        syncSessionState.effectiveBackendBaseURL
    }

    func customBackendBaseURL() -> String {
        syncSessionState.customBackendBaseURL ?? ""
    }

    func usingCustomBackendBaseURL() -> Bool {
        syncSessionState.useCustomBackendBaseURL
    }

    func setUseCustomBackendBaseURL(_ enabled: Bool) {
        syncSessionState.useCustomBackendBaseURL = enabled
        if enabled, (syncSessionState.customBackendBaseURL?.isEmpty ?? true) {
            syncSessionState.customBackendBaseURL = "http://127.0.0.1:8787"
        }
        persistSyncState()
    }

    func updateCustomBackendBaseURL(_ urlString: String) {
        let normalized = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        syncSessionState.customBackendBaseURL = normalized
        syncSessionState.useCustomBackendBaseURL = true
        persistSyncState()
    }

    func resetBackendBaseURLOverride() {
        syncSessionState.customBackendBaseURL = nil
        syncSessionState.useCustomBackendBaseURL = false
        persistSyncState()
    }

    func beginSignIn() {
        guard
            let escaped = "mdstickynotes://auth/callback".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
            let url = URL(string: "\(syncSessionState.effectiveBackendBaseURL)/auth/google/start?desktop_redirect_uri=\(escaped)")
        else {
            syncErrorMessage = "Invalid backend URL."
            return
        }
        NSWorkspace.shared.open(url)
    }

    func handleIncomingAuthURL(_ url: URL) {
        guard url.scheme == "mdstickynotes" else { return }
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let authCode = components.queryItems?.first(where: { $0.name == "auth_code" })?.value
        else {
            return
        }

        Task {
            await exchangeAuthCode(authCode)
        }
    }

    func signOut() {
        eventStreamTask?.cancel()
        pendingFlushTask?.cancel()
        let preservedCustomBackendBaseURL = syncSessionState.customBackendBaseURL
        let preservedUseCustomBackendBaseURL = syncSessionState.useCustomBackendBaseURL
        sessionKeychain.deleteValue()
        sessionToken = nil
        isAuthenticated = false
        syncErrorMessage = nil
        taskLists = []
        persistenceManager.clearAccountLinkedSyncDataPreservingLocalNotes()
        noteManager.loadNotes()
        syncSessionState = SyncSessionState(
            customBackendBaseURL: preservedCustomBackendBaseURL,
            useCustomBackendBaseURL: preservedUseCustomBackendBaseURL,
            lastEventSequence: 0,
            lastSyncStartedAt: nil,
            lastSyncCompletedAt: nil,
            lastSyncResult: nil,
            isManualSyncInFlight: false
        )
        persistSyncState()
    }

    func syncNow() {
        Task {
            await performManualSync()
        }
    }

    func refreshTaskLists() {
        Task {
            try? await refreshTaskListsFromServer()
        }
    }

    func setTaskListSelection(taskListId: String, isSelected: Bool) {
        var updated = taskLists
        guard let index = updated.firstIndex(where: { $0.id == taskListId }) else { return }
        updated[index].isSelected = isSelected
        if !isSelected && updated[index].isDefault {
            updated[index].isDefault = false
            if let firstSelectedIndex = updated.firstIndex(where: { $0.isSelected }) {
                updated[firstSelectedIndex].isDefault = true
            }
        }
        Task {
            await saveTaskListPreferences(updated)
        }
    }

    func setDefaultTaskList(taskListId: String) {
        var updated = taskLists
        for index in updated.indices {
            updated[index].isDefault = updated[index].id == taskListId
            if updated[index].id == taskListId {
                updated[index].isSelected = true
            }
        }
        Task {
            await saveTaskListPreferences(updated)
        }
    }

    func noteCreated(_ note: Note) {
        guard isAuthenticated else { return }
        let taskList = note.taskListId ?? defaultTaskList()?.id
        let taskListName = note.taskListNameCache ?? defaultTaskList()?.title
        if note.taskListId == nil, let taskList, let taskListName {
            _ = noteManager.updateNoteTaskList(note.id, taskListId: taskList, taskListNameCache: taskListName)
        }
        guard let refreshed = noteManager.getNote(note.id) else { return }
        queueUpsertMutation(for: refreshed)
    }

    func noteContentChanged(_ note: Note) {
        guard isAuthenticated else { return }
        queueUpsertMutation(for: note)
    }

    func noteDeleted(_ note: Note) {
        guard isAuthenticated else { return }
        if note.serverVersion == 0 {
            if !persistenceManager.deleteQueuedMutations(noteId: note.id.uuidString.lowercased()) {
                syncErrorMessage = persistenceManager.errorMessage
            }
            return
        }
        queueMutation(
            type: .deleteNote,
            note: note,
            coalesceKey: "note:\(note.id.uuidString.lowercased())",
            payload: DeleteNoteMutationPayload()
        )
    }

    func noteTaskListChanged(_ note: Note) {
        guard isAuthenticated else { return }
        queueUpsertMutation(for: note)
    }

    func noteDueDateChanged(_ note: Note) {
        guard isAuthenticated else { return }
        queueUpsertMutation(for: note)
    }

    private func queueUpsertMutation(for note: Note) {
        guard let taskListId = note.taskListId ?? defaultTaskList()?.id else { return }
        let taskListName = note.taskListNameCache ?? defaultTaskList()?.title
        let refreshed = noteManager.updateNoteTaskList(
            note.id,
            taskListId: taskListId,
            taskListNameCache: taskListName
        ) ?? note

        queueMutation(
            type: .upsertNote,
            note: refreshed,
            coalesceKey: "note:\(refreshed.id.uuidString.lowercased())",
            payload: UpsertNoteMutationPayload(
                content: refreshed.content,
                taskListId: taskListId,
                taskListNameCache: refreshed.taskListNameCache,
                dueDate: refreshed.dueDate
            )
        )
    }

    private func queueMutation<T: Encodable>(
        type: SyncMutationType,
        note: Note,
        coalesceKey: String,
        payload: T
    ) {
        guard
            let data = try? encoder.encode(payload),
            let payloadJSON = String(data: data, encoding: .utf8)
        else {
            return
        }

        let mutation = QueuedMutation(
            id: UUID().uuidString.lowercased(),
            coalesceKey: coalesceKey,
            noteId: note.id.uuidString.lowercased(),
            type: type,
            baseServerVersion: note.serverVersion,
            payloadJSON: payloadJSON,
            createdAt: Date(),
            updatedAt: Date()
        )
        guard persistenceManager.saveQueuedMutation(mutation) else {
            syncErrorMessage = persistenceManager.errorMessage ?? "The pending change could not be saved locally."
            noteManager.updateNoteSyncState(note.id, syncState: .error, errorMessage: syncErrorMessage)
            return
        }
        noteManager.updateNoteSyncState(note.id, syncState: .pending)
        scheduleOutboxFlush()
    }

    private func scheduleOutboxFlush() {
        pendingFlushTask?.cancel()
        pendingFlushTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            await flushOutbox()
        }
    }

    private func flushOutbox() async {
        guard isAuthenticated else { return }
        let mutations = persistenceManager.loadQueuedMutations()
        guard !mutations.isEmpty else { return }

        do {
            syncSessionState.lastSyncStartedAt = Date()
            persistSyncState()

            let payload = MutationsRequest(
                mutations: try mutations.map { mutation in
                    let json = try mutationPayloadObject(from: mutation.payloadJSON)
                    return OutgoingMutation(
                        id: mutation.id,
                        type: mutation.type.rawValue,
                        noteId: mutation.noteId,
                        baseServerVersion: mutation.baseServerVersion,
                        payload: json
                    )
                }
            )

            let response: MutationsResponse = try await sendJSONRequest(
                path: "/v1/mutations",
                method: "POST",
                body: payload,
                authorized: true
            )
            let requestedByID = Dictionary(uniqueKeysWithValues: mutations.map { ($0.id, $0) })
            var acknowledgedIDs: [String] = []

            for result in response.results {
                guard let requested = requestedByID[result.id] else { continue }
                if result.status == .conflict, result.note == nil, result.tombstone == nil {
                    throw NSError(
                        domain: "SyncManager",
                        code: 4,
                        userInfo: [NSLocalizedDescriptionKey: "The server reported a conflict without canonical note data; the local change remains queued."]
                    )
                }
                if requested.type == .upsertNote, result.note == nil, result.tombstone == nil {
                    throw NSError(
                        domain: "SyncManager",
                        code: 5,
                        userInfo: [NSLocalizedDescriptionKey: "The server did not acknowledge the note snapshot; the local change remains queued."]
                    )
                }

                if let note = result.note {
                    let hasNewerLocalChange = persistenceManager.hasQueuedMutation(
                        noteId: requested.noteId,
                        excludingIDs: [result.id]
                    )
                    if hasNewerLocalChange {
                        guard persistenceManager.rebaseQueuedMutations(
                            noteId: requested.noteId,
                            baseServerVersion: note.serverVersion
                        ) else {
                            throw NSError(
                                domain: "SyncManager",
                                code: 2,
                                userInfo: [NSLocalizedDescriptionKey: "A newer pending edit could not be rebased locally."]
                            )
                        }
                        noteManager.acknowledgeServerVersion(
                            noteIdString: requested.noteId,
                            serverVersion: note.serverVersion,
                            serverUpdatedAt: note.serverUpdatedAt,
                            stillPending: true
                        )
                    } else if let applied = noteManager.applyServerNote(note) {
                        onRemoteNoteApplied?(applied)
                    }
                }

                if let tombstone = result.tombstone {
                    noteManager.applyServerDeletion(tombstone)
                    if let uuid = UUID(uuidString: tombstone.noteId) {
                        onRemoteNoteDeleted?(uuid)
                    }
                }
                acknowledgedIDs.append(result.id)
            }

            guard persistenceManager.deleteQueuedMutations(ids: acknowledgedIDs) else {
                throw NSError(
                    domain: "SyncManager",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "The server accepted changes, but their local outbox acknowledgements could not be saved."]
                )
            }
            syncSessionState.lastEventSequence = max(syncSessionState.lastEventSequence, response.latestSequence)
            syncSessionState.lastSyncCompletedAt = Date()
            syncSessionState.lastSyncResult = "Queued changes uploaded."
            syncErrorMessage = nil
            persistSyncState()
        } catch {
            syncErrorMessage = error.localizedDescription
            syncSessionState.lastSyncResult = "Upload failed: \(error.localizedDescription)"
            persistSyncState()
        }
    }

    private func performManualSync() async {
        guard isAuthenticated else { return }
        syncSessionState.isManualSyncInFlight = true
        syncSessionState.lastSyncStartedAt = Date()
        persistSyncState()

        await flushOutbox()

        do {
            let response: SyncNowResponse = try await sendJSONRequest(
                path: "/v1/sync/now",
                method: "POST",
                body: EmptyBody(),
                authorized: true
            )
            syncSessionState.lastEventSequence = max(syncSessionState.lastEventSequence, response.latestSequence)
            syncSessionState.lastSyncCompletedAt = response.syncedAt
            if response.status == "already_running" {
                syncSessionState.lastSyncResult = "Sync already running. Refreshed latest state."
            } else {
                syncSessionState.lastSyncResult = "Manual sync completed."
            }
            syncSessionState.isManualSyncInFlight = false
            persistSyncState()
            try await fetchBootstrap()
        } catch {
            syncSessionState.isManualSyncInFlight = false
            syncSessionState.lastSyncResult = "Manual sync failed: \(error.localizedDescription)"
            syncErrorMessage = error.localizedDescription
            persistSyncState()
        }
    }

    private func exchangeAuthCode(_ authCode: String) async {
        do {
            let response: SessionExchangeResponse = try await sendJSONRequest(
                path: "/auth/app/exchange",
                method: "POST",
                body: AuthCodeExchangeBody(authCode: authCode),
                authorized: false
            )
            sessionKeychain.saveString(response.sessionToken)
            sessionToken = response.sessionToken
            isAuthenticated = true
            applyBootstrap(response.bootstrap)
            syncErrorMessage = nil
            await bootstrapAndConnect()
        } catch {
            syncErrorMessage = "Sign in failed: \(error.localizedDescription)"
        }
    }

    private func bootstrapAndConnect() async {
        do {
            try await fetchBootstrap()
            try await refreshTaskListsFromServer()
            importUnsyncedNotesIfNeeded()
            await flushOutbox()
            startEventStream()
        } catch {
            syncErrorMessage = error.localizedDescription
        }
    }

    private func fetchBootstrap() async throws {
            let response: BootstrapResponse = try await sendJSONRequest(
                path: "/v1/bootstrap",
                method: "GET",
            body: Optional<EmptyBody>.none,
            authorized: true
        )
        applyBootstrap(response)
    }

    private func applyBootstrap(_ bootstrap: BootstrapResponse) {
        taskLists = bootstrap.taskLists
        if !persistenceManager.saveTaskLists(bootstrap.taskLists) {
            syncErrorMessage = persistenceManager.errorMessage
        }
        syncSessionState.lastEventSequence = bootstrap.latestSequence
        persistSyncState()

        if let tombstones = bootstrap.tombstones {
            for tombstone in tombstones
            where !persistenceManager.hasQueuedMutation(noteId: tombstone.noteId) {
                noteManager.applyServerDeletion(tombstone)
            }
        } else {
            for noteIdString in bootstrap.deletedNoteIds ?? []
            where !persistenceManager.hasQueuedMutation(noteId: noteIdString) {
                noteManager.applyServerDeletion(
                    noteIdString: noteIdString,
                    reason: "bootstrap_reconciliation"
                )
            }
        }

        for note in bootstrap.notes
        where !persistenceManager.hasQueuedMutation(noteId: note.id) {
            if let applied = noteManager.applyServerNote(note) {
                onRemoteNoteApplied?(applied)
            }
        }
    }

    private func refreshTaskListsFromServer() async throws {
        let response: TaskListsResponse = try await sendJSONRequest(
            path: "/v1/task-lists",
            method: "GET",
            body: Optional<EmptyBody>.none,
            authorized: true
        )
        taskLists = response.taskLists
        persistenceManager.saveTaskLists(response.taskLists)
    }

    private func saveTaskListPreferences(_ taskLists: [TaskListInfo]) async {
        guard isAuthenticated else { return }
        let selected = taskLists.filter(\.isSelected).map(\.id)
        let defaultId = taskLists.first(where: \.isDefault)?.id

        do {
            let response: TaskListsResponse = try await sendJSONRequest(
                path: "/v1/preferences/sync",
                method: "PATCH",
                body: SavePreferencesBody(
                    selectedTaskListIds: selected,
                    defaultTaskListId: defaultId
                ),
                authorized: true
            )
            self.taskLists = response.taskLists
            persistenceManager.saveTaskLists(response.taskLists)
            importUnsyncedNotesIfNeeded()
            await performManualSync()
        } catch {
            syncErrorMessage = error.localizedDescription
        }
    }

    private func importUnsyncedNotesIfNeeded() {
        guard let defaultTaskList = defaultTaskList() else { return }
        let notesToImport = noteManager.assignDefaultTaskListToUnsyncedNotes(defaultTaskList)
        for note in notesToImport {
            queueUpsertMutation(for: note)
        }
    }

    private func defaultTaskList() -> TaskListInfo? {
        taskLists.first(where: { $0.isDefault && $0.isSelected }) ?? taskLists.first(where: \.isSelected)
    }

    private func startEventStream() {
        eventStreamTask?.cancel()
        guard let request = makeRequest(
            path: "/v1/events/stream?since=\(syncSessionState.lastEventSequence)",
            method: "GET",
            authorized: true
        ) else {
            return
        }

        eventStreamTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard
                    let httpResponse = response as? HTTPURLResponse,
                    (200..<300).contains(httpResponse.statusCode)
                else {
                    throw URLError(.badServerResponse)
                }

                var bufferedEventName: String?
                var bufferedData = ""

                for try await line in bytes.lines {
                    if Task.isCancelled { return }
                    if line.hasPrefix("event: ") {
                        bufferedEventName = String(line.dropFirst(7))
                    } else if line.hasPrefix("data: ") {
                        bufferedData += String(line.dropFirst(6))
                    } else if line.isEmpty {
                        if !bufferedData.isEmpty {
                            await self.handleEventData(bufferedData, eventName: bufferedEventName)
                        }
                        bufferedEventName = nil
                        bufferedData = ""
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.syncErrorMessage = "Live stream disconnected: \(error.localizedDescription)"
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self.startEventStream()
            }
        }
    }

    private func handleEventData(_ dataString: String, eventName: String?) async {
        guard let data = dataString.data(using: .utf8) else { return }
        guard let envelope = try? decoder.decode(ServerEventEnvelope.self, from: data) else { return }
        guard envelope.sequence > syncSessionState.lastEventSequence else { return }

        syncSessionState.lastEventSequence = max(syncSessionState.lastEventSequence, envelope.sequence)
        persistSyncState()

        switch (eventName ?? envelope.type, envelope.payload) {
        case ("note.upsert", .noteUpsert(let payload)):
            guard !persistenceManager.hasQueuedMutation(noteId: payload.note.id) else { return }
            if let note = noteManager.applyServerNote(payload.note) {
                onRemoteNoteApplied?(note)
            }
        case ("note.delete", .noteDelete(let payload)):
            guard !persistenceManager.hasQueuedMutation(noteId: payload.noteId) else { return }
            noteManager.applyServerDeletion(payload)
            if let uuid = UUID(uuidString: payload.noteId) {
                onRemoteNoteDeleted?(uuid)
            }
        case ("preferences.updated", _):
            Task {
                try? await refreshTaskListsFromServer()
            }
        default:
            break
        }
    }

    private func makeRequest(
        path: String,
        method: String,
        authorized: Bool
    ) -> URLRequest? {
        guard let url = URL(string: syncSessionState.effectiveBackendBaseURL + path) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authorized, let sessionToken {
            request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func sendJSONRequest<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body? = nil,
        authorized: Bool
    ) async throws -> Response {
        guard var request = makeRequest(path: path, method: method, authorized: authorized) else {
            throw URLError(.badURL)
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown backend error."
            throw NSError(domain: "SyncManager", code: httpResponse.statusCode, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }
        return try decoder.decode(Response.self, from: data)
    }

    private func mutationPayloadObject(from payloadJSON: String) throws -> [String: String?] {
        let data = Data(payloadJSON.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any?] else {
            return [:]
        }

        var result: [String: String?] = [:]
        for (key, value) in dictionary {
            result[key] = value as? String
        }
        return result
    }

    private func persistSyncState() {
        persistenceManager.saveSyncSessionState(syncSessionState)
    }
}

private struct UpsertNoteMutationPayload: Codable {
    let content: String
    let taskListId: String?
    let taskListNameCache: String?
    let dueDate: String?
}

private struct DeleteNoteMutationPayload: Codable {}

private struct AuthCodeExchangeBody: Codable {
    let authCode: String
}

private struct SavePreferencesBody: Codable {
    let selectedTaskListIds: [String]
    let defaultTaskListId: String?
}

private struct EmptyBody: Codable {}

private struct MutationsRequest: Codable {
    let mutations: [OutgoingMutation]
}

private struct OutgoingMutation: Codable {
    let id: String
    let type: String
    let noteId: String
    let baseServerVersion: Int
    let payload: [String: String?]
}
