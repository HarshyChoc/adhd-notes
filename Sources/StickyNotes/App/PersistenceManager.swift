import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite-backed local persistence for notes, sync state, task list cache, and outbox.
final class PersistenceManager: ObservableObject {
    private let db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let legacyNotesKey = "sticky_notes"

    init() {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        let dbURL = Self.databaseURL()
        try? FileManager.default.createDirectory(
            at: dbURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        if sqlite3_open(dbURL.path, &handle) != SQLITE_OK {
            print("[PersistenceManager] Failed to open SQLite database at \(dbURL.path)")
            self.db = nil
            return
        }
        self.db = handle

        runMigrations()
        migrateLegacyNotesIfNeeded()
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    func loadNotes(includeDeleted: Bool = false) -> [Note] {
        let sql = includeDeleted
            ? "SELECT * FROM notes ORDER BY modified_at ASC;"
            : "SELECT * FROM notes WHERE deleted_at IS NULL ORDER BY modified_at ASC;"
        return queryNotes(sql: sql)
    }

    func saveNote(_ note: Note) {
        let sql = """
        INSERT INTO notes (
            id, content, position_x, position_y, size_w, size_h, is_minimized, opacity,
            color_theme, cursor_position, scroll_top, always_on_top, task_list_id,
            task_list_name, due_date, sync_state, server_version, server_updated_at,
            deletion_reason, deleted_at, created_at, modified_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            content = excluded.content,
            position_x = excluded.position_x,
            position_y = excluded.position_y,
            size_w = excluded.size_w,
            size_h = excluded.size_h,
            is_minimized = excluded.is_minimized,
            opacity = excluded.opacity,
            color_theme = excluded.color_theme,
            cursor_position = excluded.cursor_position,
            scroll_top = excluded.scroll_top,
            always_on_top = excluded.always_on_top,
            task_list_id = excluded.task_list_id,
            task_list_name = excluded.task_list_name,
            due_date = excluded.due_date,
            sync_state = excluded.sync_state,
            server_version = excluded.server_version,
            server_updated_at = excluded.server_updated_at,
            deletion_reason = excluded.deletion_reason,
            deleted_at = excluded.deleted_at,
            created_at = excluded.created_at,
            modified_at = excluded.modified_at;
        """

        guard let statement = prepare(sql) else { return }
        defer { sqlite3_finalize(statement) }

        bind(statement, index: 1, value: note.id.uuidString)
        bind(statement, index: 2, value: note.content)
        sqlite3_bind_double(statement, 3, note.position.x)
        sqlite3_bind_double(statement, 4, note.position.y)
        sqlite3_bind_double(statement, 5, note.size.width)
        sqlite3_bind_double(statement, 6, note.size.height)
        sqlite3_bind_int(statement, 7, note.isMinimized ? 1 : 0)
        sqlite3_bind_double(statement, 8, note.opacity)
        bind(statement, index: 9, value: note.colorTheme)
        sqlite3_bind_int(statement, 10, Int32(note.cursorPosition))
        sqlite3_bind_double(statement, 11, note.scrollTop)
        sqlite3_bind_int(statement, 12, note.alwaysOnTop ? 1 : 0)
        bind(statement, index: 13, value: note.taskListId)
        bind(statement, index: 14, value: note.taskListNameCache)
        bind(statement, index: 15, value: note.dueDate)
        bind(statement, index: 16, value: note.syncState.rawValue)
        sqlite3_bind_int(statement, 17, Int32(note.serverVersion))
        bind(statement, index: 18, value: Self.iso8601(note.serverUpdatedAt))
        bind(statement, index: 19, value: note.deletionReason)
        bind(statement, index: 20, value: Self.iso8601(note.deletedAt))
        bind(statement, index: 21, value: Self.iso8601(note.createdAt))
        bind(statement, index: 22, value: Self.iso8601(note.modifiedAt))
        step(statement)
    }

    func saveNotes(_ notes: [Note]) {
        execute(sql: "BEGIN IMMEDIATE TRANSACTION;")
        for note in notes {
            saveNote(note)
        }
        execute(sql: "COMMIT;")
    }

    func tombstoneNote(_ noteId: UUID, reason: String, syncState: NoteSyncState = .pending) {
        let sql = """
        UPDATE notes
        SET deleted_at = ?, deletion_reason = ?, modified_at = ?, sync_state = ?
        WHERE id = ?;
        """
        guard let statement = prepare(sql) else { return }
        defer { sqlite3_finalize(statement) }
        let now = Date()
        bind(statement, index: 1, value: Self.iso8601(now))
        bind(statement, index: 2, value: reason)
        bind(statement, index: 3, value: Self.iso8601(now))
        bind(statement, index: 4, value: syncState.rawValue)
        bind(statement, index: 5, value: noteId.uuidString)
        step(statement)
    }

    func saveTaskLists(_ taskLists: [TaskListInfo]) {
        execute(sql: "DELETE FROM task_lists;")
        execute(sql: "BEGIN IMMEDIATE TRANSACTION;")
        let sql = """
        INSERT INTO task_lists (id, title, is_selected, is_default, updated_at)
        VALUES (?, ?, ?, ?, ?);
        """
        for list in taskLists {
            guard let statement = prepare(sql) else { continue }
            bind(statement, index: 1, value: list.id)
            bind(statement, index: 2, value: list.title)
            sqlite3_bind_int(statement, 3, list.isSelected ? 1 : 0)
            sqlite3_bind_int(statement, 4, list.isDefault ? 1 : 0)
            bind(statement, index: 5, value: Self.iso8601(Date()))
            step(statement)
            sqlite3_finalize(statement)
        }
        execute(sql: "COMMIT;")
    }

    func loadTaskLists() -> [TaskListInfo] {
        let sql = "SELECT id, title, is_selected, is_default FROM task_lists ORDER BY title ASC;"
        guard let statement = prepare(sql) else { return [] }
        defer { sqlite3_finalize(statement) }

        var results: [TaskListInfo] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = string(statement, index: 0) ?? ""
            let title = string(statement, index: 1) ?? ""
            let isSelected = sqlite3_column_int(statement, 2) == 1
            let isDefault = sqlite3_column_int(statement, 3) == 1
            results.append(TaskListInfo(id: id, title: title, isSelected: isSelected, isDefault: isDefault))
        }
        return results
    }

    func saveSyncSessionState(_ state: SyncSessionState) {
        saveAppState(key: "sync_session", encodable: state)
    }

    func loadSyncSessionState() -> SyncSessionState {
        loadAppState(key: "sync_session", as: SyncSessionState.self) ?? .defaultValue
    }

    func saveQueuedMutation(_ mutation: QueuedMutation) {
        let sql = """
        INSERT INTO outbox_mutations (
            id, coalesce_key, note_id, mutation_type, payload_json, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(coalesce_key) DO UPDATE SET
            id = excluded.id,
            note_id = excluded.note_id,
            mutation_type = excluded.mutation_type,
            payload_json = excluded.payload_json,
            updated_at = excluded.updated_at;
        """
        guard let statement = prepare(sql) else { return }
        defer { sqlite3_finalize(statement) }

        bind(statement, index: 1, value: mutation.id)
        bind(statement, index: 2, value: mutation.coalesceKey)
        bind(statement, index: 3, value: mutation.noteId)
        bind(statement, index: 4, value: mutation.type.rawValue)
        bind(statement, index: 5, value: mutation.payloadJSON)
        bind(statement, index: 6, value: Self.iso8601(mutation.createdAt))
        bind(statement, index: 7, value: Self.iso8601(mutation.updatedAt))
        step(statement)
    }

    func loadQueuedMutations() -> [QueuedMutation] {
        let sql = """
        SELECT id, coalesce_key, note_id, mutation_type, payload_json, created_at, updated_at
        FROM outbox_mutations ORDER BY created_at ASC;
        """
        guard let statement = prepare(sql) else { return [] }
        defer { sqlite3_finalize(statement) }

        var results: [QueuedMutation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let id = string(statement, index: 0),
                let coalesceKey = string(statement, index: 1),
                let noteId = string(statement, index: 2),
                let typeRaw = string(statement, index: 3),
                let type = SyncMutationType(rawValue: typeRaw),
                let payloadJSON = string(statement, index: 4),
                let createdAt = Self.date(from: string(statement, index: 5)),
                let updatedAt = Self.date(from: string(statement, index: 6))
            else {
                continue
            }
            results.append(
                QueuedMutation(
                    id: id,
                    coalesceKey: coalesceKey,
                    noteId: noteId,
                    type: type,
                    payloadJSON: payloadJSON,
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
            )
        }
        return results
    }

    func deleteQueuedMutations(ids: [String]) {
        guard !ids.isEmpty else { return }
        execute(sql: "BEGIN IMMEDIATE TRANSACTION;")
        let sql = "DELETE FROM outbox_mutations WHERE id = ?;"
        for id in ids {
            guard let statement = prepare(sql) else { continue }
            bind(statement, index: 1, value: id)
            step(statement)
            sqlite3_finalize(statement)
        }
        execute(sql: "COMMIT;")
    }

    func clearTaskLists() {
        execute(sql: "DELETE FROM task_lists;")
    }

    func clearAccountLinkedSyncDataPreservingLocalNotes() {
        execute(sql: "DELETE FROM app_state WHERE key = 'sync_session';")
        clearTaskLists()
        execute(sql: "DELETE FROM outbox_mutations;")
        execute(sql: """
        DELETE FROM notes
        WHERE deleted_at IS NOT NULL
           OR server_version > 0
           OR task_list_id IS NOT NULL
           OR sync_state != 'localOnly';
        """)
    }

    func clearSyncSessionState() {
        clearAccountLinkedSyncDataPreservingLocalNotes()
    }

    private func queryNotes(sql: String) -> [Note] {
        guard let statement = prepare(sql) else { return [] }
        defer { sqlite3_finalize(statement) }

        var notes: [Note] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let note = note(from: statement) else { continue }
            notes.append(note)
        }
        return notes
    }

    private func note(from statement: OpaquePointer?) -> Note? {
        guard let idString = string(statement, index: 0), let id = UUID(uuidString: idString) else {
            return nil
        }

        return Note(
            id: id,
            content: string(statement, index: 1) ?? "",
            position: CGPoint(
                x: sqlite3_column_double(statement, 2),
                y: sqlite3_column_double(statement, 3)
            ),
            size: CGSize(
                width: sqlite3_column_double(statement, 4),
                height: sqlite3_column_double(statement, 5)
            ),
            isMinimized: sqlite3_column_int(statement, 6) == 1,
            opacity: sqlite3_column_double(statement, 7),
            colorTheme: string(statement, index: 8) ?? "yellow",
            cursorPosition: Int(sqlite3_column_int(statement, 9)),
            scrollTop: sqlite3_column_double(statement, 10),
            alwaysOnTop: sqlite3_column_int(statement, 11) == 1,
            taskListId: string(statement, index: 12),
            taskListNameCache: string(statement, index: 13),
            dueDate: string(statement, index: 14),
            syncState: NoteSyncState(rawValue: string(statement, index: 15) ?? "") ?? .localOnly,
            serverVersion: Int(sqlite3_column_int(statement, 16)),
            serverUpdatedAt: Self.date(from: string(statement, index: 17)),
            deletionReason: string(statement, index: 18),
            deletedAt: Self.date(from: string(statement, index: 19)),
            createdAt: Self.date(from: string(statement, index: 20)) ?? Date(),
            modifiedAt: Self.date(from: string(statement, index: 21)) ?? Date()
        )
    }

    private func saveAppState<T: Encodable>(key: String, encodable: T) {
        guard
            let data = try? encoder.encode(encodable),
            let json = String(data: data, encoding: .utf8)
        else { return }
        let sql = """
        INSERT INTO app_state (key, value_json) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json;
        """
        guard let statement = prepare(sql) else { return }
        defer { sqlite3_finalize(statement) }
        bind(statement, index: 1, value: key)
        bind(statement, index: 2, value: json)
        step(statement)
    }

    private func loadAppState<T: Decodable>(key: String, as type: T.Type) -> T? {
        let sql = "SELECT value_json FROM app_state WHERE key = ? LIMIT 1;"
        guard let statement = prepare(sql) else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(statement, index: 1, value: key)
        guard sqlite3_step(statement) == SQLITE_ROW, let json = string(statement, index: 0) else {
            return nil
        }
        guard let data = json.data(using: .utf8) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func runMigrations() {
        execute(sql: """
        CREATE TABLE IF NOT EXISTS notes (
            id TEXT PRIMARY KEY,
            content TEXT NOT NULL,
            position_x REAL NOT NULL,
            position_y REAL NOT NULL,
            size_w REAL NOT NULL,
            size_h REAL NOT NULL,
            is_minimized INTEGER NOT NULL,
            opacity REAL NOT NULL,
            color_theme TEXT NOT NULL,
            cursor_position INTEGER NOT NULL,
            scroll_top REAL NOT NULL,
            always_on_top INTEGER NOT NULL,
            task_list_id TEXT,
            task_list_name TEXT,
            due_date TEXT,
            sync_state TEXT NOT NULL,
            server_version INTEGER NOT NULL,
            server_updated_at TEXT,
            deletion_reason TEXT,
            deleted_at TEXT,
            created_at TEXT NOT NULL,
            modified_at TEXT NOT NULL
        );
        """)

        execute(sql: """
        CREATE TABLE IF NOT EXISTS task_lists (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            is_selected INTEGER NOT NULL,
            is_default INTEGER NOT NULL,
            updated_at TEXT NOT NULL
        );
        """)

        execute(sql: """
        CREATE TABLE IF NOT EXISTS outbox_mutations (
            id TEXT PRIMARY KEY,
            coalesce_key TEXT NOT NULL UNIQUE,
            note_id TEXT NOT NULL,
            mutation_type TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        """)

        execute(sql: """
        CREATE TABLE IF NOT EXISTS app_state (
            key TEXT PRIMARY KEY,
            value_json TEXT NOT NULL
        );
        """)
    }

    private func migrateLegacyNotesIfNeeded() {
        guard loadAppState(key: "legacy_userdefaults_migrated", as: Bool.self) != true else {
            return
        }

        let defaults = UserDefaults.standard
        guard let data = defaults.data(forKey: legacyNotesKey) else {
            saveAppState(key: "legacy_userdefaults_migrated", encodable: true)
            return
        }

        do {
            let notes = try decoder.decode([Note].self, from: data)
            for note in notes where !noteExists(note.id) {
                saveNote(note)
            }
            print("[PersistenceManager] Migrated \(notes.count) notes from UserDefaults to SQLite")
        } catch {
            print("[PersistenceManager] Failed to migrate legacy UserDefaults notes: \(error)")
        }

        saveAppState(key: "legacy_userdefaults_migrated", encodable: true)
    }

    private func noteExists(_ id: UUID) -> Bool {
        let sql = "SELECT 1 FROM notes WHERE id = ? LIMIT 1;"
        guard let statement = prepare(sql) else { return false }
        defer { sqlite3_finalize(statement) }
        bind(statement, index: 1, value: id.uuidString)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        guard let db else { return nil }
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            if let error = sqlite3_errmsg(db) {
                print("[PersistenceManager] SQLite prepare failed: \(String(cString: error))")
            }
            return nil
        }
        return statement
    }

    private func execute(sql: String) {
        guard let db else { return }
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK, let error = sqlite3_errmsg(db) {
            print("[PersistenceManager] SQLite exec failed: \(String(cString: error))")
        }
    }

    private func step(_ statement: OpaquePointer?) {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            if let db, let error = sqlite3_errmsg(db) {
                print("[PersistenceManager] SQLite step failed: \(String(cString: error))")
            }
            return
        }
    }

    private func bind(_ statement: OpaquePointer?, index: Int32, value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func string(_ statement: OpaquePointer?, index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    private static func iso8601(_ date: Date?) -> String? {
        guard let date else { return nil }
        return formatter.string(from: date)
    }

    private static func date(from string: String?) -> Date? {
        guard let string else { return nil }
        return formatter.date(from: string)
    }

    private static func databaseURL() -> URL {
        let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return supportDirectory
            .appendingPathComponent("MDStickyNotes", isDirectory: true)
            .appendingPathComponent("stickynotes.sqlite")
    }

    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
