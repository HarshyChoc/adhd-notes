import Foundation
import Combine

/// Manages the collection of active notes persisted in the local SQLite store.
final class NoteManager: ObservableObject {
    @Published private(set) var notes: [Note] = []

    private let persistenceManager: PersistenceManager

    init(persistenceManager: PersistenceManager = PersistenceManager()) {
        self.persistenceManager = persistenceManager
        loadNotes()
    }

    func loadNotes() {
        notes = persistenceManager.loadNotes().filter {
            !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        if notes.isEmpty {
            createDefaultNote()
        }
    }

    @discardableResult
    func createNote(
        content: String = "",
        position: CGPoint = CGPoint(x: 100, y: 100),
        taskListId: String? = nil,
        taskListNameCache: String? = nil
    ) -> Note {
        let colors = NoteColor.allCases
        let colorTheme = colors[notes.count % colors.count].rawValue
        let syncState: NoteSyncState = taskListId == nil ? .localOnly : .pending

        let note = Note(
            content: content,
            position: position,
            colorTheme: colorTheme,
            taskListId: taskListId,
            taskListNameCache: taskListNameCache,
            syncState: syncState
        )

        notes.append(note)
        persistenceManager.saveNote(note)
        print("[NoteManager] Created new note: \(note.id)")
        return note
    }

    func updateNote(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else {
            print("[NoteManager] Warning: Attempting to update non-existent note: \(note.id)")
            return
        }

        var updatedNote = note
        updatedNote.updateModificationDate()
        notes[index] = updatedNote
        persistenceManager.saveNote(updatedNote)
    }

    func updateNoteContent(_ noteId: UUID, content: String) {
        guard let index = notes.firstIndex(where: { $0.id == noteId }) else { return }
        notes[index].content = content
        notes[index].updateModificationDate()
        persistenceManager.saveNote(notes[index])
    }

    func updateNoteWindow(
        _ noteId: UUID,
        position: CGPoint? = nil,
        size: CGSize? = nil,
        opacity: Double? = nil,
        isMinimized: Bool? = nil
    ) {
        guard let index = notes.firstIndex(where: { $0.id == noteId }) else { return }
        if let position {
            notes[index].position = position
        }
        if let size {
            notes[index].size = size
        }
        if let opacity {
            notes[index].opacity = opacity
        }
        if let isMinimized {
            notes[index].isMinimized = isMinimized
        }
        notes[index].updateModificationDate()
        persistenceManager.saveNote(notes[index])
    }

    func updateNoteColor(_ noteId: UUID, colorTheme: String) {
        guard let index = notes.firstIndex(where: { $0.id == noteId }) else { return }
        notes[index].colorTheme = colorTheme
        notes[index].updateModificationDate()
        persistenceManager.saveNote(notes[index])
    }

    func updateNoteCursorPosition(_ noteId: UUID, cursorPosition: Int) {
        guard let index = notes.firstIndex(where: { $0.id == noteId }) else { return }
        notes[index].cursorPosition = cursorPosition
        persistenceManager.saveNote(notes[index])
    }

    func updateNoteScrollTop(_ noteId: UUID, scrollTop: Double) {
        guard let index = notes.firstIndex(where: { $0.id == noteId }) else { return }
        notes[index].scrollTop = scrollTop
        persistenceManager.saveNote(notes[index])
    }

    func updateNoteAlwaysOnTop(_ noteId: UUID, alwaysOnTop: Bool) {
        guard let index = notes.firstIndex(where: { $0.id == noteId }) else { return }
        notes[index].alwaysOnTop = alwaysOnTop
        persistenceManager.saveNote(notes[index])
    }

    @discardableResult
    func updateNoteTaskList(_ noteId: UUID, taskListId: String?, taskListNameCache: String?) -> Note? {
        guard let index = notes.firstIndex(where: { $0.id == noteId }) else { return nil }
        notes[index].taskListId = taskListId
        notes[index].taskListNameCache = taskListNameCache
        notes[index].syncState = taskListId == nil ? .localOnly : .pending
        notes[index].updateModificationDate()
        persistenceManager.saveNote(notes[index])
        return notes[index]
    }

    @discardableResult
    func updateNoteDueDate(_ noteId: UUID, dueDate: String?) -> Note? {
        guard let index = notes.firstIndex(where: { $0.id == noteId }) else { return nil }
        notes[index].dueDate = dueDate
        if notes[index].taskListId != nil {
            notes[index].syncState = .pending
        }
        notes[index].updateModificationDate()
        persistenceManager.saveNote(notes[index])
        return notes[index]
    }

    func updateNoteSyncState(_ noteId: UUID, syncState: NoteSyncState, errorMessage: String? = nil) {
        guard let index = notes.firstIndex(where: { $0.id == noteId }) else { return }
        notes[index].syncState = syncState
        notes[index].deletionReason = errorMessage ?? notes[index].deletionReason
        persistenceManager.saveNote(notes[index])
    }

    func assignDefaultTaskListToUnsyncedNotes(_ defaultList: TaskListInfo) -> [Note] {
        var changed: [Note] = []
        for index in notes.indices where notes[index].taskListId == nil && notes[index].serverVersion == 0 {
            notes[index].taskListId = defaultList.id
            notes[index].taskListNameCache = defaultList.title
            notes[index].syncState = .pending
            notes[index].updateModificationDate()
            persistenceManager.saveNote(notes[index])
            changed.append(notes[index])
        }
        return changed
    }

    func applyServerNote(_ serverNote: ServerNoteDTO) -> Note? {
        let id = UUID(uuidString: serverNote.id) ?? UUID()
        if let index = notes.firstIndex(where: { $0.id == id }) {
            notes[index].content = serverNote.bodyMarkdown
            notes[index].taskListId = serverNote.taskListId
            notes[index].taskListNameCache = serverNote.taskListNameCache
            notes[index].dueDate = serverNote.dueDate
            notes[index].serverVersion = serverNote.serverVersion
            notes[index].serverUpdatedAt = serverNote.serverUpdatedAt
            notes[index].syncState = serverNote.pendingProjection
                ? (serverNote.lastProjectionError == nil ? .pending : .error)
                : .synced
            notes[index].deletionReason = serverNote.lastProjectionError
            notes[index].deletedAt = serverNote.deletedAt
            persistenceManager.saveNote(notes[index])
            return notes[index]
        }

        let newNote = Note(
            id: id,
            content: serverNote.bodyMarkdown,
            position: CGPoint(x: 100 + CGFloat(notes.count) * 24, y: 100 + CGFloat(notes.count) * 24),
            taskListId: serverNote.taskListId,
            taskListNameCache: serverNote.taskListNameCache,
            dueDate: serverNote.dueDate,
            syncState: serverNote.pendingProjection
                ? (serverNote.lastProjectionError == nil ? .pending : .error)
                : .synced,
            serverVersion: serverNote.serverVersion,
            serverUpdatedAt: serverNote.serverUpdatedAt,
            deletionReason: serverNote.lastProjectionError
        )
        notes.append(newNote)
        persistenceManager.saveNote(newNote)
        return newNote
    }

    func applyServerDeletion(noteIdString: String, reason: String) {
        guard let id = UUID(uuidString: noteIdString) else { return }
        persistenceManager.tombstoneNote(id, reason: reason, syncState: .synced)
        notes.removeAll { $0.id == id }
    }

    func deleteNote(_ noteId: UUID, reason: String = "desktop_delete") {
        persistenceManager.tombstoneNote(noteId, reason: reason)
        notes.removeAll { $0.id == noteId }
    }

    func saveNoteImmediately(_ note: Note) {
        updateNote(note)
        persistenceManager.saveNotes(notes)
    }

    func getNote(_ noteId: UUID) -> Note? {
        notes.first { $0.id == noteId }
    }

    func allActiveNotes() -> [Note] {
        notes
    }

    private func createDefaultNote() {
        let welcomeContent = """
# Welcome to Sticky Notes!

This is a **markdown-enabled** sticky note.

## Features
- Live markdown preview
- Math equations: $E = mc^2$
- Code blocks
- And more!

Start typing to get started.
"""

        _ = createNote(content: welcomeContent)
    }
}
