import AppKit
import SwiftUI
import Combine

/// Main coordinator that manages native windows, notes, and the backend sync client.
@MainActor
final class AppCoordinator: ObservableObject {
    @Published var noteManager: NoteManager
    @Published var windowManager: WindowManager
    @Published var syncManager: SyncManager
    @Published var launchAtLoginManager: LaunchAtLoginManager
    @Published private(set) var areNotesHidden = false

    var isQuitting = false

    let persistenceManager: PersistenceManager
    private var cancellables = Set<AnyCancellable>()

    init() {
        let persistenceManager = PersistenceManager()
        let noteManager = NoteManager(persistenceManager: persistenceManager)
        self.persistenceManager = persistenceManager
        self.noteManager = noteManager
        self.windowManager = WindowManager()
        self.launchAtLoginManager = LaunchAtLoginManager()
        self.syncManager = SyncManager(
            persistenceManager: persistenceManager,
            noteManager: noteManager
        )

        SharedWebViewManager.shared.coordinator = self

        syncManager.onRemoteNoteApplied = { [weak self] note in
            self?.reloadActiveEditorIfNeeded(note)
        }
        syncManager.onRemoteNoteDeleted = { noteId in
            if SharedWebViewManager.shared.activeNoteId == noteId {
                SharedWebViewManager.shared.removeCachedState(for: noteId)
            }
        }

        setupBindings()
        openInitialWindows()
    }

    func startServices() {
        syncManager.start()
    }

    func handleIncomingURL(_ url: URL) {
        syncManager.handleIncomingAuthURL(url)
    }

    func createNewNote() {
        let position = calculateNewNotePosition()
        let note = noteManager.createNote(
            position: position,
            taskListId: syncManager.taskLists.first(where: { $0.isDefault })?.id,
            taskListNameCache: syncManager.taskLists.first(where: { $0.isDefault })?.title
        )
        windowManager.openWindow(for: note, coordinator: self)
        if areNotesHidden {
            windowManager.hideWindow(note.id)
        }
        syncManager.noteCreated(note)
    }

    func closeNoteWindow(_ noteId: UUID) {
        let deletedNote = noteManager.getNote(noteId)
        windowManager.removeWindow(for: noteId)
        SharedWebViewManager.shared.removeCachedState(for: noteId)

        if isQuitting {
            return
        }

        if let deletedNote {
            syncManager.noteDeleted(deletedNote)
        }
        noteManager.deleteNote(noteId)
    }

    func handleContentChange(noteId: UUID, content: String) {
        noteManager.updateNoteContent(noteId, content: content)
        if let note = noteManager.getNote(noteId) {
            syncManager.noteContentChanged(note)
        }
    }

    func handleWindowStateChange(
        noteId: UUID,
        position: CGPoint? = nil,
        size: CGSize? = nil,
        isMinimized: Bool? = nil
    ) {
        noteManager.updateNoteWindow(
            noteId,
            position: position,
            size: size,
            isMinimized: isMinimized
        )
    }

    func showAllNotes() {
        let wasHidden = areNotesHidden
        areNotesHidden = false
        for note in noteManager.notes {
            windowManager.openWindow(for: note, coordinator: self)
            windowManager.showWindow(note.id)
        }
        restoreLastActiveNote(after: 0)
        if wasHidden {
            syncManager.syncNow()
        }
    }

    func toggleAllNotesVisibilityFromGlobalHotKey() {
        if areNotesHidden {
            showAllNotes()
        } else {
            hideAllNotes()
        }
    }

    func hideAllNotes() {
        saveLastActiveNote()
        areNotesHidden = true
        windowManager.hideAllWindows()
    }

    func toggleAllNotesVisibility() {
        areNotesHidden ? showAllNotes() : hideAllNotes()
    }

    func syncNow() {
        syncManager.syncNow()
    }

    func changeNoteColor(noteId: UUID, colorTheme: String) {
        noteManager.updateNoteColor(noteId, colorTheme: colorTheme)
        windowManager.getWindowController(for: noteId)?.setColorTheme(colorTheme)
    }

    func setNoteOpacity(noteId: UUID, opacity: Double) {
        noteManager.updateNoteWindow(noteId, opacity: opacity)
        windowManager.getWindowController(for: noteId)?.setOpacity(opacity)
    }

    func setNoteAlwaysOnTop(noteId: UUID, alwaysOnTop: Bool) {
        noteManager.updateNoteAlwaysOnTop(noteId, alwaysOnTop: alwaysOnTop)
        windowManager.getWindowController(for: noteId)?.setAlwaysOnTop(alwaysOnTop)
    }

    func setNoteTaskList(noteId: UUID, taskListId: String?) {
        let taskList = syncManager.taskLists.first(where: { $0.id == taskListId })
        guard let note = noteManager.updateNoteTaskList(
            noteId,
            taskListId: taskList?.id,
            taskListNameCache: taskList?.title
        ) else {
            return
        }
        syncManager.noteTaskListChanged(note)
    }

    func setNoteDueDate(noteId: UUID, dueDate: String?) {
        guard let note = noteManager.updateNoteDueDate(noteId, dueDate: dueDate) else { return }
        windowManager.getWindowController(for: noteId)?.setDueDate(dueDate)
        syncManager.noteDueDateChanged(note)
    }

    func focusedNoteId() -> UUID? {
        guard let keyWindow = NSApp.keyWindow else { return nil }
        return windowManager.noteId(for: keyWindow)
    }

    func cycleToNextWindow() {
        let allIds = windowManager.getAllWindowIds()
            .sorted { $0.uuidString < $1.uuidString }
        guard !allIds.isEmpty else { return }

        if let currentId = focusedNoteId(),
           let idx = allIds.firstIndex(of: currentId) {
            let next = allIds[(idx + 1) % allIds.count]
            windowManager.bringToFront(next)
        } else {
            windowManager.bringToFront(allIds[0])
        }
    }

    private static let lastActiveNoteKey = "lastActiveNoteId"

    func saveLastActiveNote() {
        if let noteId = SharedWebViewManager.shared.activeNoteId ?? focusedNoteId() {
            UserDefaults.standard.set(noteId.uuidString, forKey: Self.lastActiveNoteKey)
        }
    }

    func restoreLastActiveNote(after delay: TimeInterval = 0.3) {
        guard let idString = UserDefaults.standard.string(forKey: Self.lastActiveNoteKey),
              let noteId = UUID(uuidString: idString) else { return }

        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.windowManager.bringToFront(noteId)
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.windowManager.bringToFront(noteId)
            }
        }
    }

    func saveAllNotesImmediately() {
        SharedWebViewManager.shared.flushCurrentNoteState()
        persistenceManager.saveNotes(noteManager.notes)
    }

    private func setupBindings() {
        noteManager.$notes
            .sink { [weak self] notes in
                self?.syncWindowsWithNotes(notes)
            }
            .store(in: &cancellables)
    }

    private func openInitialWindows() {
        for note in noteManager.notes {
            windowManager.openWindow(for: note, coordinator: self)
        }
    }

    private func calculateNewNotePosition() -> CGPoint {
        let noteSize = CGSize(width: 300, height: 360)

        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let visibleFrame = screen.visibleFrame

        let existingFrames: [NSRect] = windowManager.getAllWindowIds().compactMap {
            windowManager.getWindowController(for: $0)?.window?.frame
        }
        let count = existingFrames.filter { visibleFrame.intersects($0) }.count

        let step: CGFloat = 30
        let x = visibleFrame.midX - noteSize.width / 2 + CGFloat(count) * step
        let y = visibleFrame.midY - noteSize.height / 2 - CGFloat(count) * step

        return CGPoint(
            x: min(max(x, visibleFrame.minX), visibleFrame.maxX - noteSize.width),
            y: min(max(y, visibleFrame.minY), visibleFrame.maxY - noteSize.height)
        )
    }

    private func syncWindowsWithNotes(_ notes: [Note]) {
        let noteIds = Set(notes.map(\.id))
        let windowIds = Set(windowManager.getAllWindowIds())

        for note in notes {
            windowManager.getWindowController(for: note.id)?.applyNoteState(note)
        }

        let windowsToOpen = noteIds.subtracting(windowIds)
        for noteId in windowsToOpen {
            guard let note = noteManager.getNote(noteId) else { continue }
            windowManager.openWindow(for: note, coordinator: self)
            if areNotesHidden {
                windowManager.hideWindow(noteId)
            }
        }

        let windowsToClose = windowIds.subtracting(noteIds)
        for windowId in windowsToClose {
            windowManager.closeWindow(for: windowId)
        }
    }

    private func reloadActiveEditorIfNeeded(_ note: Note) {
        guard SharedWebViewManager.shared.activeNoteId == note.id else { return }
        SharedWebViewManager.shared.switchToNoteSkippingSerialization(note.id, note: note)
    }
}
