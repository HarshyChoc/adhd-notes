import SwiftUI

struct NoteInspectorView: View {
    let coordinator: AppCoordinator
    @ObservedObject private var noteManager: NoteManager
    @ObservedObject private var syncManager: SyncManager
    let noteId: UUID

    init(coordinator: AppCoordinator, noteId: UUID) {
        self.coordinator = coordinator
        self.noteId = noteId
        _noteManager = ObservedObject(wrappedValue: coordinator.noteManager)
        _syncManager = ObservedObject(wrappedValue: coordinator.syncManager)
    }

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private var selectedTaskLists: [TaskListInfo] {
        syncManager.taskLists.filter(\.isSelected)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let note = noteManager.getNote(noteId) {
                Text("Task Sync")
                    .font(.headline)

                Picker("List", selection: Binding(
                    get: { note.taskListId ?? "" },
                    set: { newValue in
                        coordinator.setNoteTaskList(
                            noteId: noteId,
                            taskListId: newValue.isEmpty ? nil : newValue
                        )
                    }
                )) {
                    Text("Unassigned").tag("")
                    ForEach(selectedTaskLists) { taskList in
                        Text(taskList.title).tag(taskList.id)
                    }
                }
                .disabled(selectedTaskLists.isEmpty)

                if syncManager.isAuthenticated && syncManager.taskLists.isEmpty {
                    Text("No task lists loaded yet. Refresh them in Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if syncManager.isAuthenticated && selectedTaskLists.isEmpty {
                    Text("No sync lists are enabled. Check the list boxes in Settings first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                DatePicker(
                    "Due Date",
                    selection: Binding(
                        get: {
                            if let dueDate = note.dueDate, let date = dateFormatter.date(from: dueDate) {
                                return date
                            }
                            return Date()
                        },
                        set: { newValue in
                            coordinator.setNoteDueDate(
                                noteId: noteId,
                                dueDate: dateFormatter.string(from: newValue)
                            )
                        }
                    ),
                    displayedComponents: .date
                )

                Button("Clear Due Date") {
                    coordinator.setNoteDueDate(noteId: noteId, dueDate: nil)
                }

                Divider()

                Text("Sync State: \(note.syncState.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let dueDate = note.dueDate {
                    Text(NoteDueDateDisplay.fullText(for: dueDate) ?? "Due: \(dueDate)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Date: \(dueDate)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error = note.deletionReason, note.syncState == .error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } else {
                Text("Note unavailable.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 260)
    }
}
