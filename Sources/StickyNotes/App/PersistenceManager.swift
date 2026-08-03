import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// SQLite-backed local persistence for notes, sync state, task list cache, and outbox.
final class PersistenceManager: ObservableObject {
    private let db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let legacyNotesKey = "sticky_notes"
    @Published private(set) var errorMessage: String?
    private(set) var isReady = false

    init(databaseURL: URL? = nil, migrateUserDefaults: Bool = true) {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601

        let dbURL = databaseURL ?? Self.databaseURL()
        do {
            try FileManager.default.createDirectory(
                at: dbURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            self.db = nil
            errorMessage = "Unable to create the notes data directory: \(error.localizedDescription)"
            return
        }

        var handle: OpaquePointer?
        if sqlite3_open(dbURL.path, &handle) != SQLITE_OK {
            errorMessage = "Unable to open the notes database at \(dbURL.path)."
            self.db = nil
            return
        }
        self.db = handle

        guard runMigrations() else { return }
        isReady = true
        if migrateUserDefaults {
            migrateLegacyNotesIfNeeded()
        }
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

    @discardableResult
    func saveNote(_ note: Note) -> Bool {
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

        guard let statement = prepare(sql) else { return false }
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
        return step(statement)
    }

    @discardableResult
    func saveNotes(_ notes: [Note]) -> Bool {
        guard execute(sql: "BEGIN IMMEDIATE TRANSACTION;") else { return false }
        for note in notes {
            guard saveNote(note) else {
                _ = execute(sql: "ROLLBACK;")
                return false
            }
        }
        return execute(sql: "COMMIT;")
    }

    @discardableResult
    func tombstoneNote(
        _ noteId: UUID,
        reason: String,
        syncState: NoteSyncState = .pending,
        serverVersion: Int? = nil,
        serverUpdatedAt: Date? = nil,
        deletedAt: Date? = nil
    ) -> Bool {
        let sql = """
        UPDATE notes
        SET deleted_at = ?, deletion_reason = ?, modified_at = ?, sync_state = ?,
            server_version = COALESCE(?, server_version),
            server_updated_at = COALESCE(?, server_updated_at)
        WHERE id = ?;
        """
        guard let statement = prepare(sql) else { return false }
        defer { sqlite3_finalize(statement) }
        let now = deletedAt ?? Date()
        bind(statement, index: 1, value: Self.iso8601(now))
        bind(statement, index: 2, value: reason)
        bind(statement, index: 3, value: Self.iso8601(now))
        bind(statement, index: 4, value: syncState.rawValue)
        if let serverVersion {
            sqlite3_bind_int(statement, 5, Int32(serverVersion))
        } else {
            sqlite3_bind_null(statement, 5)
        }
        bind(statement, index: 6, value: Self.iso8601(serverUpdatedAt))
        bind(statement, index: 7, value: noteId.uuidString)
        return step(statement)
    }

    @discardableResult
    func saveTaskLists(_ taskLists: [TaskListInfo]) -> Bool {
        guard execute(sql: "BEGIN IMMEDIATE TRANSACTION;") else { return false }
        guard execute(sql: "DELETE FROM task_lists;") else {
            _ = execute(sql: "ROLLBACK;")
            return false
        }
        let sql = """
        INSERT INTO task_lists (id, title, is_selected, is_default, updated_at)
        VALUES (?, ?, ?, ?, ?);
        """
        for list in taskLists {
            guard let statement = prepare(sql) else {
                _ = execute(sql: "ROLLBACK;")
                return false
            }
            bind(statement, index: 1, value: list.id)
            bind(statement, index: 2, value: list.title)
            sqlite3_bind_int(statement, 3, list.isSelected ? 1 : 0)
            sqlite3_bind_int(statement, 4, list.isDefault ? 1 : 0)
            bind(statement, index: 5, value: Self.iso8601(Date()))
            guard step(statement) else {
                sqlite3_finalize(statement)
                _ = execute(sql: "ROLLBACK;")
                return false
            }
            sqlite3_finalize(statement)
        }
        return execute(sql: "COMMIT;")
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

    @discardableResult
    func saveSyncSessionState(_ state: SyncSessionState) -> Bool {
        saveAppState(key: "sync_session", encodable: state)
    }

    func loadSyncSessionState() -> SyncSessionState {
        loadAppState(key: "sync_session", as: SyncSessionState.self) ?? .defaultValue
    }

    @discardableResult
    func saveQueuedMutation(_ mutation: QueuedMutation) -> Bool {
        let sql = """
        INSERT INTO outbox_mutations (
            id, coalesce_key, note_id, mutation_type, base_server_version, payload_json, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(coalesce_key) DO UPDATE SET
            id = excluded.id,
            note_id = excluded.note_id,
            mutation_type = excluded.mutation_type,
            base_server_version = excluded.base_server_version,
            payload_json = excluded.payload_json,
            updated_at = excluded.updated_at;
        """
        guard let statement = prepare(sql) else { return false }
        defer { sqlite3_finalize(statement) }

        bind(statement, index: 1, value: mutation.id)
        bind(statement, index: 2, value: mutation.coalesceKey)
        bind(statement, index: 3, value: mutation.noteId)
        bind(statement, index: 4, value: mutation.type.rawValue)
        sqlite3_bind_int(statement, 5, Int32(mutation.baseServerVersion))
        bind(statement, index: 6, value: mutation.payloadJSON)
        bind(statement, index: 7, value: Self.iso8601(mutation.createdAt))
        bind(statement, index: 8, value: Self.iso8601(mutation.updatedAt))
        return step(statement)
    }

    func loadQueuedMutations() -> [QueuedMutation] {
        let sql = """
        SELECT id, coalesce_key, note_id, mutation_type, base_server_version, payload_json, created_at, updated_at
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
                let payloadJSON = string(statement, index: 5),
                let createdAt = Self.date(from: string(statement, index: 6)),
                let updatedAt = Self.date(from: string(statement, index: 7))
            else {
                continue
            }
            results.append(
                QueuedMutation(
                    id: id,
                    coalesceKey: coalesceKey,
                    noteId: noteId,
                    type: type,
                    baseServerVersion: Int(sqlite3_column_int(statement, 4)),
                    payloadJSON: payloadJSON,
                    createdAt: createdAt,
                    updatedAt: updatedAt
                )
            )
        }
        return results
    }

    @discardableResult
    func deleteQueuedMutations(ids: [String]) -> Bool {
        guard !ids.isEmpty else { return true }
        guard execute(sql: "BEGIN IMMEDIATE TRANSACTION;") else { return false }
        let sql = "DELETE FROM outbox_mutations WHERE id = ?;"
        for id in ids {
            guard let statement = prepare(sql) else {
                _ = execute(sql: "ROLLBACK;")
                return false
            }
            bind(statement, index: 1, value: id)
            guard step(statement) else {
                sqlite3_finalize(statement)
                _ = execute(sql: "ROLLBACK;")
                return false
            }
            sqlite3_finalize(statement)
        }
        return execute(sql: "COMMIT;")
    }

    @discardableResult
    func deleteQueuedMutations(noteId: String) -> Bool {
        let sql = "DELETE FROM outbox_mutations WHERE note_id = ?;"
        guard let statement = prepare(sql) else { return false }
        defer { sqlite3_finalize(statement) }
        bind(statement, index: 1, value: noteId)
        return step(statement)
    }

    func hasQueuedMutation(noteId: String, excludingIDs: Set<String> = []) -> Bool {
        let sql = "SELECT id FROM outbox_mutations WHERE note_id = ? ORDER BY updated_at DESC;"
        guard let statement = prepare(sql) else { return false }
        defer { sqlite3_finalize(statement) }
        bind(statement, index: 1, value: noteId)
        while sqlite3_step(statement) == SQLITE_ROW {
            if let id = string(statement, index: 0), !excludingIDs.contains(id) {
                return true
            }
        }
        return false
    }

    @discardableResult
    func rebaseQueuedMutations(noteId: String, baseServerVersion: Int) -> Bool {
        let sql = "UPDATE outbox_mutations SET base_server_version = ?, updated_at = ? WHERE note_id = ?;"
        guard let statement = prepare(sql) else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(baseServerVersion))
        bind(statement, index: 2, value: Self.iso8601(Date()))
        bind(statement, index: 3, value: noteId)
        return step(statement)
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

    @discardableResult
    private func saveAppState<T: Encodable>(key: String, encodable: T) -> Bool {
        let data: Data
        do {
            data = try encoder.encode(encodable)
        } catch {
            recordError("Local app state could not be encoded: \(error.localizedDescription)")
            return false
        }
        guard let json = String(data: data, encoding: .utf8) else {
            recordError("Local app state could not be converted to UTF-8.")
            return false
        }
        let sql = """
        INSERT INTO app_state (key, value_json) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json;
        """
        guard let statement = prepare(sql) else { return false }
        defer { sqlite3_finalize(statement) }
        bind(statement, index: 1, value: key)
        bind(statement, index: 2, value: json)
        return step(statement)
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

    @discardableResult
    private func runMigrations() -> Bool {
        guard execute(sql: "BEGIN IMMEDIATE TRANSACTION;") else { return false }
        guard execute(sql: """
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
        """) else { return rollbackMigration() }

        guard execute(sql: """
        CREATE TABLE IF NOT EXISTS task_lists (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            is_selected INTEGER NOT NULL,
            is_default INTEGER NOT NULL,
            updated_at TEXT NOT NULL
        );
        """) else { return rollbackMigration() }

        guard execute(sql: """
        CREATE TABLE IF NOT EXISTS outbox_mutations (
            id TEXT PRIMARY KEY,
            coalesce_key TEXT NOT NULL UNIQUE,
            note_id TEXT NOT NULL,
            mutation_type TEXT NOT NULL,
            base_server_version INTEGER NOT NULL DEFAULT 0,
            payload_json TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        """) else { return rollbackMigration() }

        if !columnExists(table: "outbox_mutations", column: "base_server_version") {
            guard execute(sql: "ALTER TABLE outbox_mutations ADD COLUMN base_server_version INTEGER NOT NULL DEFAULT 0;") else {
                return rollbackMigration()
            }
        }

        if sqliteUserVersion() < 2 {
            guard migrateOutboxToFullNoteMutations() else {
                return rollbackMigration()
            }
        }

        guard execute(sql: """
        CREATE TABLE IF NOT EXISTS app_state (
            key TEXT PRIMARY KEY,
            value_json TEXT NOT NULL
        );
        """) else { return rollbackMigration() }

        guard execute(sql: "PRAGMA user_version = 2;") else { return rollbackMigration() }
        return execute(sql: "COMMIT;")
    }

    private func rollbackMigration() -> Bool {
        _ = execute(sql: "ROLLBACK;")
        return false
    }

    private func columnExists(table: String, column: String) -> Bool {
        guard let statement = prepare("PRAGMA table_info(\(table));") else { return false }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if string(statement, index: 1) == column { return true }
        }
        return false
    }

    private func sqliteUserVersion() -> Int {
        guard let statement = prepare("PRAGMA user_version;") else { return 0 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(statement, 0))
    }

    /// Version 2 replaces field-specific mutations with one complete snapshot per note.
    /// The migration rebuilds from the canonical local note row so a queued body update
    /// cannot accidentally omit a newer list, due date, or Markdown title.
    private func migrateOutboxToFullNoteMutations() -> Bool {
        let sql = """
        SELECT
            lower(o.note_id),
            MIN(o.created_at),
            MAX(o.updated_at),
            MAX(CASE WHEN o.mutation_type = 'delete_note' THEN 1 ELSE 0 END),
            n.content,
            n.task_list_id,
            n.task_list_name,
            n.due_date,
            n.server_version,
            n.deleted_at
        FROM outbox_mutations o
        LEFT JOIN notes n ON lower(n.id) = lower(o.note_id)
        GROUP BY lower(o.note_id);
        """
        guard let statement = prepare(sql) else { return false }

        struct MigratedMutation {
            let noteId: String
            let createdAt: String
            let updatedAt: String
            let type: SyncMutationType
            let baseServerVersion: Int
            let payloadJSON: String
        }

        var migrated: [MigratedMutation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let noteId = string(statement, index: 0),
                let createdAt = string(statement, index: 1),
                let updatedAt = string(statement, index: 2)
            else {
                sqlite3_finalize(statement)
                recordError("An existing pending change could not be read during migration.")
                return false
            }

            let shouldDelete = sqlite3_column_int(statement, 3) == 1 || string(statement, index: 9) != nil
            let payload: [String: Any]
            let type: SyncMutationType
            if shouldDelete {
                type = .deleteNote
                payload = [:]
            } else {
                guard let content = string(statement, index: 4) else {
                    sqlite3_finalize(statement)
                    recordError("A pending note snapshot is missing from the local database.")
                    return false
                }
                type = .upsertNote
                payload = [
                    "content": content,
                    "taskListId": string(statement, index: 5) ?? NSNull(),
                    "taskListNameCache": string(statement, index: 6) ?? NSNull(),
                    "dueDate": string(statement, index: 7) ?? NSNull()
                ]
            }

            guard
                let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
                let payloadJSON = String(data: data, encoding: .utf8)
            else {
                sqlite3_finalize(statement)
                recordError("A pending note snapshot could not be encoded during migration.")
                return false
            }

            migrated.append(
                MigratedMutation(
                    noteId: noteId,
                    createdAt: createdAt,
                    updatedAt: updatedAt,
                    type: type,
                    baseServerVersion: Int(sqlite3_column_int(statement, 8)),
                    payloadJSON: payloadJSON
                )
            )
        }
        sqlite3_finalize(statement)

        guard execute(sql: "DELETE FROM outbox_mutations;") else { return false }
        let insertSQL = """
        INSERT INTO outbox_mutations (
            id, coalesce_key, note_id, mutation_type, base_server_version, payload_json, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        for mutation in migrated {
            guard let insert = prepare(insertSQL) else { return false }
            bind(insert, index: 1, value: UUID().uuidString.lowercased())
            bind(insert, index: 2, value: "note:\(mutation.noteId)")
            bind(insert, index: 3, value: mutation.noteId)
            bind(insert, index: 4, value: mutation.type.rawValue)
            sqlite3_bind_int(insert, 5, Int32(mutation.baseServerVersion))
            bind(insert, index: 6, value: mutation.payloadJSON)
            bind(insert, index: 7, value: mutation.createdAt)
            bind(insert, index: 8, value: mutation.updatedAt)
            guard step(insert) else {
                sqlite3_finalize(insert)
                return false
            }
            sqlite3_finalize(insert)
        }
        return true
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
            let notesToMigrate = notes.filter { !noteExists($0.id) }
            guard saveNotes(notesToMigrate) else {
                recordError("Legacy notes were decoded but could not be saved to SQLite.")
                return
            }
            print("[PersistenceManager] Migrated \(notes.count) notes from UserDefaults to SQLite")
        } catch {
            recordError("Legacy notes could not be decoded: \(error.localizedDescription)")
            return
        }

        _ = saveAppState(key: "legacy_userdefaults_migrated", encodable: true)
    }

    private func noteExists(_ id: UUID) -> Bool {
        let sql = "SELECT 1 FROM notes WHERE id = ? LIMIT 1;"
        guard let statement = prepare(sql) else { return false }
        defer { sqlite3_finalize(statement) }
        bind(statement, index: 1, value: id.uuidString)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        guard let db else {
            recordError("The notes database is unavailable.")
            return nil
        }
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) != SQLITE_OK {
            if let error = sqlite3_errmsg(db) {
                recordError("SQLite prepare failed: \(String(cString: error))")
            }
            return nil
        }
        return statement
    }

    @discardableResult
    private func execute(sql: String) -> Bool {
        guard let db else {
            recordError("The notes database is unavailable.")
            return false
        }
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK, let error = sqlite3_errmsg(db) {
            recordError("SQLite exec failed: \(String(cString: error))")
            return false
        }
        return true
    }

    @discardableResult
    private func step(_ statement: OpaquePointer?) -> Bool {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            if let db, let error = sqlite3_errmsg(db) {
                recordError("SQLite write failed: \(String(cString: error))")
            }
            return false
        }
        return true
    }

    private func recordError(_ message: String) {
        errorMessage = message
        print("[PersistenceManager] \(message)")
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
