import XCTest
import SQLite3
@testable import StickyNotes

final class PersistenceAndSyncOrderingTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testSQLiteOpenFailureIsVisibleAndWritesFail() throws {
        let directory = try makeTemporaryDirectory()
        let manager = PersistenceManager(databaseURL: directory, migrateUserDefaults: false)
        XCTAssertFalse(manager.isReady)
        XCTAssertNotNil(manager.errorMessage)
        XCTAssertFalse(manager.saveNote(Note(content: "must not disappear")))
    }

    func testExistingOutboxMigratesToOneFullNoteSnapshot() throws {
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("legacy.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        try execute(db, """
        CREATE TABLE notes (
            id TEXT PRIMARY KEY, content TEXT NOT NULL, position_x REAL NOT NULL, position_y REAL NOT NULL,
            size_w REAL NOT NULL, size_h REAL NOT NULL, is_minimized INTEGER NOT NULL, opacity REAL NOT NULL,
            color_theme TEXT NOT NULL, cursor_position INTEGER NOT NULL, scroll_top REAL NOT NULL,
            always_on_top INTEGER NOT NULL, task_list_id TEXT, task_list_name TEXT, due_date TEXT,
            sync_state TEXT NOT NULL, server_version INTEGER NOT NULL, server_updated_at TEXT,
            deletion_reason TEXT, deleted_at TEXT, created_at TEXT NOT NULL, modified_at TEXT NOT NULL
        );
        CREATE TABLE outbox_mutations (
            id TEXT PRIMARY KEY, coalesce_key TEXT NOT NULL UNIQUE, note_id TEXT NOT NULL,
            mutation_type TEXT NOT NULL, payload_json TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
        );
        """)
        let noteID = UUID().uuidString
        let timestamp = "2026-08-02T12:00:00.000Z"
        let noteContent = "# Current title\n\nCurrent body"
        try execute(db, """
        INSERT INTO notes VALUES (
            '\(noteID)', '\(noteContent)', 1, 2, 300, 360, 0, 0.95, 'yellow', 0, 0, 0,
            'list-1', 'Inbox', '2026-08-03', 'pending', 5, NULL, NULL, NULL, '\(timestamp)', '\(timestamp)'
        );
        INSERT INTO outbox_mutations VALUES (
            'legacy-1', 'body:\(noteID)', '\(noteID.lowercased())', 'update_note_body',
            '{"content":"stale partial body"}', '\(timestamp)', '\(timestamp)'
        );
        """)
        sqlite3_close(db)
        db = nil

        let manager = PersistenceManager(databaseURL: databaseURL, migrateUserDefaults: false)
        XCTAssertTrue(manager.isReady, manager.errorMessage ?? "migration failed")
        let mutations = manager.loadQueuedMutations()
        XCTAssertEqual(mutations.count, 1)
        XCTAssertEqual(mutations.first?.type, .upsertNote)
        XCTAssertEqual(mutations.first?.baseServerVersion, 5)
        let payload = try XCTUnwrap(mutations.first?.payloadJSON.data(using: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(object["content"] as? String, "# Current title\n\nCurrent body")
        XCTAssertEqual(object["taskListId"] as? String, "list-1")
    }

    func testOutboxAcknowledgementDeletionRollsBackOnPersistenceFailure() throws {
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("outbox.sqlite")
        let manager = PersistenceManager(databaseURL: databaseURL, migrateUserDefaults: false)
        XCTAssertTrue(manager.isReady)
        XCTAssertTrue(manager.saveQueuedMutation(mutation(id: "first")))
        XCTAssertTrue(manager.saveQueuedMutation(mutation(id: "second")))

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &db), SQLITE_OK)
        try execute(db, """
        CREATE TRIGGER prevent_second_ack BEFORE DELETE ON outbox_mutations
        WHEN OLD.id = 'second'
        BEGIN SELECT RAISE(ABORT, 'simulated acknowledgement persistence failure'); END;
        """)
        sqlite3_close(db)

        XCTAssertFalse(manager.deleteQueuedMutations(ids: ["first", "second"]))
        XCTAssertEqual(Set(manager.loadQueuedMutations().map(\.id)), ["first", "second"])
    }

    func testUnpersistedEditorTextDefersRemoteContentUntilOutboxTakesOver() {
        let noteID = UUID()
        var fence = LocalEditFence()

        fence.begin(noteId: noteID)
        XCTAssertTrue(fence.shouldDeferRemoteChange(
            noteId: noteID.uuidString.lowercased(),
            hasQueuedMutation: false
        ))

        fence.markDurable(noteId: noteID)
        XCTAssertTrue(fence.shouldDeferRemoteChange(
            noteId: noteID.uuidString,
            hasQueuedMutation: true
        ))
        XCTAssertFalse(fence.shouldDeferRemoteChange(
            noteId: noteID.uuidString,
            hasQueuedMutation: false
        ))
    }

    func testRemoteContentInvalidatesStaleEditorSnapshot() {
        let noteID = UUID()
        var cache = EditorStateCache()
        cache[noteID] = #"{"doc":"stale text","anchor":10,"head":10,"scrollTop":0}"#

        cache.discardForRemoteUpdate(noteId: noteID)

        XCTAssertNil(cache[noteID])
    }

    @MainActor
    func testServerVersionsNeverMoveBackwardAndSyncedNotesCannotDetach() throws {
        let databaseURL = try makeTemporaryDirectory().appendingPathComponent("versions.sqlite")
        let persistence = PersistenceManager(databaseURL: databaseURL, migrateUserDefaults: false)
        let manager = NoteManager(persistenceManager: persistence)
        let noteID = UUID()
        let newer = serverNote(id: noteID, content: "new", version: 2)
        XCTAssertNotNil(manager.applyServerNote(newer))
        XCTAssertNil(manager.applyServerNote(serverNote(id: noteID, content: "old", version: 1)))
        XCTAssertEqual(manager.getNote(noteID)?.content, "new")
        XCTAssertNil(manager.updateNoteTaskList(noteID, taskListId: nil, taskListNameCache: nil))
        XCTAssertEqual(manager.getNote(noteID)?.taskListId, "list-1")

        let deletionDate = Date()
        manager.applyServerDeletion(ServerDeletePayload(
            noteId: noteID.uuidString,
            deletionReason: "google_deleted",
            serverVersion: 3,
            serverUpdatedAt: deletionDate
        ))
        let tombstone = try XCTUnwrap(persistence.loadNotes(includeDeleted: true).first { $0.id == noteID })
        XCTAssertEqual(tombstone.serverVersion, 3)
        XCTAssertEqual(tombstone.deletionReason, "google_deleted")
    }

    private func mutation(id: String) -> QueuedMutation {
        QueuedMutation(
            id: id,
            coalesceKey: "note:\(id)",
            noteId: id,
            type: .upsertNote,
            baseServerVersion: 0,
            payloadJSON: "{}",
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    private func serverNote(id: UUID, content: String, version: Int) -> ServerNoteDTO {
        ServerNoteDTO(
            id: id.uuidString,
            title: "Title",
            bodyMarkdown: content,
            bodyPlaintext: content,
            taskListId: "list-1",
            taskListNameCache: "Inbox",
            googleTaskId: nil,
            dueDate: nil,
            serverVersion: version,
            serverUpdatedAt: Date(),
            deletedAt: nil,
            deletionReason: nil,
            pendingProjection: false,
            lastProjectionError: nil
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StickyNotesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func execute(_ db: OpaquePointer?, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown SQLite error"
            sqlite3_free(error)
            throw NSError(domain: "SQLiteTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
