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
    private var eventStreamSession: URLSession?
    private var eventStreamDataTask: URLSessionDataTask?
    private var eventStreamDelegate: SSEStreamDelegate?
    private var eventStreamGeneration = UUID()
    private var pendingFlushTask: Task<Void, Never>?
    private var sessionToken: String?
    private var localEditFence = LocalEditFence()

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
        stopEventStream()
        pendingFlushTask?.cancel()
        localEditFence.removeAll()
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

    func noteEditorWillChange(_ noteId: UUID) {
        localEditFence.begin(noteId: noteId)
    }

    func noteEditorPersistenceFailed(_ noteId: UUID) {
        // Deliberately retain the fence. Replacing the editor with server content after a
        // local persistence failure would turn a visible error into silent data loss.
        syncErrorMessage = persistenceManager.errorMessage
            ?? "The latest editor change could not be saved locally."
    }

    func noteContentChanged(_ note: Note) {
        guard isAuthenticated else {
            localEditFence.markDurable(noteId: note.id)
            return
        }
        if queueUpsertMutation(for: note) {
            // The durable outbox now protects this content from bootstrap/SSE updates.
            localEditFence.markDurable(noteId: note.id)
        }
    }

    func noteDeleted(_ note: Note) {
        localEditFence.remove(noteId: note.id)
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

    @discardableResult
    private func queueUpsertMutation(for note: Note) -> Bool {
        guard let taskListId = note.taskListId ?? defaultTaskList()?.id else { return false }
        let taskListName = note.taskListNameCache ?? defaultTaskList()?.title
        let refreshed = noteManager.updateNoteTaskList(
            note.id,
            taskListId: taskListId,
            taskListNameCache: taskListName
        ) ?? note

        return queueMutation(
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

    @discardableResult
    private func queueMutation<T: Encodable>(
        type: SyncMutationType,
        note: Note,
        coalesceKey: String,
        payload: T
    ) -> Bool {
        guard
            let data = try? encoder.encode(payload),
            let payloadJSON = String(data: data, encoding: .utf8)
        else {
            syncErrorMessage = "The pending note snapshot could not be encoded."
            return false
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
            return false
        }
        noteManager.updateNoteSyncState(note.id, syncState: .pending)
        scheduleOutboxFlush()
        return true
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
                    let hasUnpersistedEditorChange = localEditFence.contains(noteId: requested.noteId)
                    if hasNewerLocalChange || hasUnpersistedEditorChange {
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
                        }
                        noteManager.acknowledgeServerVersion(
                            noteIdString: requested.noteId,
                            serverVersion: note.serverVersion,
                            serverUpdatedAt: note.serverUpdatedAt,
                            stillPending: true
                        )
                    } else {
                        applyServerNoteAndNotifyIfContentChanged(note)
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
            where !shouldDeferRemoteChange(noteId: tombstone.noteId) {
                noteManager.applyServerDeletion(tombstone)
            }
        } else {
            for noteIdString in bootstrap.deletedNoteIds ?? []
            where !shouldDeferRemoteChange(noteId: noteIdString) {
                noteManager.applyServerDeletion(
                    noteIdString: noteIdString,
                    reason: "bootstrap_reconciliation"
                )
            }
        }

        for note in bootstrap.notes
        where !shouldDeferRemoteChange(noteId: note.id) {
            applyServerNoteAndNotifyIfContentChanged(note)
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
        stopEventStream()
        guard isAuthenticated else { return }
        guard var request = makeRequest(
            path: "/v1/events/stream?since=\(syncSessionState.lastEventSequence)",
            method: "GET",
            authorized: true
        ) else {
            return
        }
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        let generation = UUID()
        eventStreamGeneration = generation
        let delegate = SSEStreamDelegate(
            onEvent: { [weak self] eventName, dataString in
                Task { @MainActor [weak self] in
                    guard let self, self.eventStreamGeneration == generation else { return }
                    self.handleEventData(dataString, eventName: eventName)
                }
            },
            onComplete: { [weak self] statusCode, error in
                Task { @MainActor [weak self] in
                    self?.handleEventStreamCompletion(
                        generation: generation,
                        statusCode: statusCode,
                        error: error
                    )
                }
            }
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let dataTask = session.dataTask(with: request)
        eventStreamDelegate = delegate
        eventStreamSession = session
        eventStreamDataTask = dataTask
        dataTask.resume()
    }

    private func stopEventStream() {
        eventStreamGeneration = UUID()
        eventStreamTask?.cancel()
        eventStreamTask = nil
        eventStreamDataTask?.cancel()
        eventStreamDataTask = nil
        eventStreamSession?.invalidateAndCancel()
        eventStreamSession = nil
        eventStreamDelegate = nil
    }

    private func handleEventStreamCompletion(
        generation: UUID,
        statusCode: Int?,
        error: Error?
    ) {
        guard eventStreamGeneration == generation else { return }
        eventStreamDataTask = nil
        eventStreamSession?.finishTasksAndInvalidate()
        eventStreamSession = nil
        eventStreamDelegate = nil

        if statusCode == 401 {
            invalidateExpiredSession()
            return
        }
        guard isAuthenticated else { return }

        let reason = error?.localizedDescription ?? "The server closed the connection."
        syncErrorMessage = "Live stream disconnected: \(reason)"
        eventStreamTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self, self.eventStreamGeneration == generation else { return }
            self.startEventStream()
        }
    }

    private func handleEventData(_ dataString: String, eventName: String?) {
        guard let data = dataString.data(using: .utf8) else { return }
        guard let envelope = try? decoder.decode(ServerEventEnvelope.self, from: data) else { return }
        guard envelope.sequence > syncSessionState.lastEventSequence else { return }

        syncSessionState.lastEventSequence = max(syncSessionState.lastEventSequence, envelope.sequence)
        persistSyncState()

        switch (eventName ?? envelope.type, envelope.payload) {
        case ("note.upsert", .noteUpsert(let payload)):
            guard !shouldDeferRemoteChange(noteId: payload.note.id) else { return }
            applyServerNoteAndNotifyIfContentChanged(payload.note)
        case ("note.delete", .noteDelete(let payload)):
            guard !shouldDeferRemoteChange(noteId: payload.noteId) else { return }
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
            if authorized, httpResponse.statusCode == 401 {
                invalidateExpiredSession()
                throw NSError(domain: "SyncManager", code: 401, userInfo: [
                    NSLocalizedDescriptionKey: "Session expired. Sign in again."
                ])
            }
            let message = String(data: data, encoding: .utf8) ?? "Unknown backend error."
            throw NSError(domain: "SyncManager", code: httpResponse.statusCode, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }
        return try decoder.decode(Response.self, from: data)
    }

    private func invalidateExpiredSession() {
        stopEventStream()
        pendingFlushTask?.cancel()
        sessionKeychain.deleteValue()
        sessionToken = nil
        isAuthenticated = false
        syncErrorMessage = "Session expired. Sign in again."
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

    private func shouldDeferRemoteChange(noteId: String) -> Bool {
        localEditFence.shouldDeferRemoteChange(
            noteId: noteId,
            hasQueuedMutation: persistenceManager.hasQueuedMutation(noteId: noteId)
        )
    }

    private func applyServerNoteAndNotifyIfContentChanged(_ serverNote: ServerNoteDTO) {
        let noteId = UUID(uuidString: serverNote.id)
        let previousContent = noteId.flatMap { noteManager.getNote($0)?.content }
        guard let applied = noteManager.applyServerNote(serverNote) else { return }
        if previousContent != applied.content {
            onRemoteNoteApplied?(applied)
        }
    }
}

private final class SSEStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let onEvent: @Sendable (String?, String) -> Void
    private let onComplete: @Sendable (Int?, Error?) -> Void
    private var statusCode: Int?
    private var buffer = Data()

    init(
        onEvent: @escaping @Sendable (String?, String) -> Void,
        onComplete: @escaping @Sendable (Int?, Error?) -> Void
    ) {
        self.onEvent = onEvent
        self.onComplete = onComplete
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        statusCode = (response as? HTTPURLResponse)?.statusCode
        if let statusCode, (200..<300).contains(statusCode) {
            completionHandler(.allow)
        } else {
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        let separator = Data([0x0A, 0x0A])
        while let range = buffer.range(of: separator) {
            let frameData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            guard let frame = String(data: frameData, encoding: .utf8) else { continue }

            var eventName: String?
            var dataLines: [String] = []
            for rawLine in frame.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = rawLine.last == "\r" ? rawLine.dropLast() : rawLine[...]
                if line.hasPrefix("event: ") {
                    eventName = String(line.dropFirst(7))
                } else if line.hasPrefix("data: ") {
                    dataLines.append(String(line.dropFirst(6)))
                }
            }
            if !dataLines.isEmpty {
                onEvent(eventName, dataLines.joined(separator: "\n"))
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        onComplete(statusCode, error)
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
