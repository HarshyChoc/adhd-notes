import Foundation

/// Protects text that has changed in CodeMirror but has not reached the durable outbox yet.
/// Once the corresponding full-note snapshot is queued, the outbox becomes the protection.
struct LocalEditFence {
    private var unpersistedNoteIDs: Set<String> = []

    mutating func begin(noteId: UUID) {
        unpersistedNoteIDs.insert(Self.normalize(noteId.uuidString))
    }

    mutating func markDurable(noteId: UUID) {
        unpersistedNoteIDs.remove(Self.normalize(noteId.uuidString))
    }

    mutating func remove(noteId: UUID) {
        unpersistedNoteIDs.remove(Self.normalize(noteId.uuidString))
    }

    mutating func removeAll() {
        unpersistedNoteIDs.removeAll()
    }

    func contains(noteId: String) -> Bool {
        unpersistedNoteIDs.contains(Self.normalize(noteId))
    }

    func shouldDeferRemoteChange(noteId: String, hasQueuedMutation: Bool) -> Bool {
        contains(noteId: noteId) || hasQueuedMutation
    }

    private static func normalize(_ noteId: String) -> String {
        noteId.lowercased()
    }
}

/// Stores cursor/scroll snapshots for inactive notes. A genuine remote content change must
/// invalidate the snapshot or the old document in that snapshot can replace newer content.
struct EditorStateCache {
    private var values: [UUID: String] = [:]

    subscript(noteId: UUID) -> String? {
        get { values[noteId] }
        set { values[noteId] = newValue }
    }

    mutating func discardForRemoteUpdate(noteId: UUID) {
        values.removeValue(forKey: noteId)
    }

    mutating func remove(noteId: UUID) {
        values.removeValue(forKey: noteId)
    }
}
