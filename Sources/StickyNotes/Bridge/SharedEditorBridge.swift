import Foundation
import WebKit

/// Bridge between Swift and the shared JavaScript editor.
/// Routes messages by noteId to the appropriate handler.
final class SharedEditorBridge: NSObject, WKScriptMessageHandler {

    private enum EditorAction: Sendable {
        case ready
        case localEditStarted(noteId: UUID?)
        case contentChanged(content: String, noteId: UUID?)
        case requestSave
        case openURL(URL)
        case log(String)
        case error(String)
        case unknown(String)
    }

    // MARK: - WKScriptMessageHandler

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let action = Self.parseAction(message.body) else {
            print("[SharedEditorBridge] Invalid message format")
            return
        }

        Task { @MainActor in
            Self.handleAction(action)
        }
    }

    // MARK: - Action Handling

    private static func parseAction(_ messageBody: Any) -> EditorAction? {
        guard let body = messageBody as? [String: Any],
              let action = body["action"] as? String else {
            return nil
        }

        switch action {
        case "ready":
            return .ready

        case "contentChanged":
            guard let content = body["content"] as? String else { return nil }
            let noteId = (body["noteId"] as? String).flatMap(UUID.init(uuidString:))
            return .contentChanged(content: content, noteId: noteId)

        case "localEditStarted":
            let noteId = (body["noteId"] as? String).flatMap(UUID.init(uuidString:))
            return .localEditStarted(noteId: noteId)

        case "requestSave":
            return .requestSave

        case "openURL":
            guard let urlString = body["url"] as? String,
                  let url = URL(string: urlString) else { return nil }
            return .openURL(url)

        case "log":
            guard let message = body["message"] as? String else { return nil }
            return .log(message)

        case "error":
            guard let message = body["message"] as? String else { return nil }
            return .error(message)

        default:
            return .unknown(action)
        }
    }

    @MainActor
    private static func handleAction(_ action: EditorAction) {
        let manager = SharedWebViewManager.shared

        switch action {
        case .ready:
            // markReady() handles loading any queued note internally
            manager.markReady()

        case let .localEditStarted(messageNoteId):
            guard let noteId = messageNoteId ?? manager.activeNoteId else { return }
            manager.coordinator?.handleEditorChangeStarted(noteId: noteId)

        case let .contentChanged(content, messageNoteId):
            // Route to the correct note via noteId
            let noteId: UUID
            if let messageNoteId {
                noteId = messageNoteId
            } else if let activeId = manager.activeNoteId {
                noteId = activeId
            } else {
                return
            }
            manager.coordinator?.handleContentChange(noteId: noteId, content: content)

        case .requestSave:
            manager.flushCurrentNoteState()

        case let .openURL(url):
            NSWorkspace.shared.open(url)

        case let .log(message):
            print("[SharedEditorBridge][JS] \(message)")

        case let .error(message):
            print("[SharedEditorBridge][JS Error] \(message)")

        case let .unknown(action):
            print("[SharedEditorBridge] Unknown action: \(action)")
        }
    }
}
