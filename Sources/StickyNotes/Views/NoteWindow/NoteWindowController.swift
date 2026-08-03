import AppKit
import SwiftUI
import WebKit

/// Window controller for a single note window.
/// Uses a shared WKWebView that gets reparented to the active (key) window.
/// Inactive windows show a snapshot image of their last editor state.
class NoteWindowController: NSWindowController, NSWindowDelegate {
    private enum AuxiliaryOverlay: Equatable {
        case deleteConfirmation
        case colorPicker
        case inspector
    }

    // MARK: - Properties

    private var note: Note
    private weak var coordinator: AppCoordinator?
    private var colorButton: NSButton?
    private var pinButton: NSButton?
    private var opacitySlider: NSSlider?
    private var inspectorButton: NSButton?
    private var dueDateLabel: NSTextField?
    private var auxiliaryOverlay: AuxiliaryOverlay?
    private var auxiliaryOverlayHostingView: NSHostingView<AnyView>?
    private var suppressCloseCallback = false
    private var skipDeleteConfirmation = false
    private var isAwaitingDeleteConfirmation = false
    private var dueDateRefreshTimer: Timer?

    /// The main content container that holds either WKWebView or text preview/snapshot
    private var contentContainer: NSView!

    /// Whether the shared WKWebView is currently attached to this window
    private(set) var hasWebView = false

    /// Cached snapshot of the last rendered editor state (shown when WebView moves to another window)
    private var snapshotView: NSImageView?

    // MARK: - Initialization

    init(note: Note, coordinator: AppCoordinator) {
        self.note = note
        self.coordinator = coordinator

        // Create the panel (floating window)
        let panel = NSPanel(
            contentRect: NSRect(
                origin: note.position,
                size: note.size
            ),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .utilityWindow,
                .fullSizeContentView,
                .nonactivatingPanel,
            ],
            backing: .buffered,
            defer: false
        )

        super.init(window: panel)

        setupPanel(panel)
        setupTitlebarAccessory(panel)
        setupContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        dueDateRefreshTimer?.invalidate()
    }

    // MARK: - Setup Methods

    func closeFromModelSync() {
        suppressCloseCallback = true
        close()
    }

    private func setupPanel(_ panel: NSPanel) {
        panel.hidesOnDeactivate = false
        applyPanelBehavior(panel, alwaysOnTop: note.alwaysOnTop)
        panel.becomesKeyOnlyIfNeeded = false
        panel.worksWhenModal = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = NoteColor.color(from: note.colorTheme)
        panel.alphaValue = CGFloat(note.opacity)
        panel.title = "Sticky Note"
        panel.delegate = self

        panel.minSize = NSSize(width: 300, height: 150)

        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden

        if note.isMinimized {
            panel.miniaturize(nil)
        }
    }

    private func setupTitlebarAccessory(_ panel: NSPanel) {
        while !panel.titlebarAccessoryViewControllers.isEmpty {
            panel.removeTitlebarAccessoryViewController(at: 0)
        }

        let container = TitlebarControlsView(frame: NSRect(x: 0, y: 0, width: 228, height: 22))
        var xOffset: CGFloat = 4

        // Opacity slider
        let slider = NSSlider(frame: NSRect(x: xOffset, y: 4, width: 50, height: 14))
        slider.minValue = 0.2
        slider.maxValue = 1.0
        slider.doubleValue = note.opacity
        slider.target = self
        slider.action = #selector(opacityChanged(_:))
        slider.controlSize = .mini
        slider.toolTip = "Opacity"
        opacitySlider = slider
        container.addSubview(slider)
        xOffset += 58

        // Pin button
        let pin = NSButton(frame: NSRect(x: xOffset, y: 2, width: 18, height: 18))
        pin.wantsLayer = true
        pin.bezelStyle = .regularSquare
        pin.isBordered = false
        pin.title = ""
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        if let img = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pin")?
            .withSymbolConfiguration(config) {
            pin.image = img
        }
        pin.contentTintColor = .labelColor
        pin.alphaValue = note.alwaysOnTop ? 1.0 : 0.25
        pin.imagePosition = .imageOnly
        pin.target = self
        pin.action = #selector(toggleAlwaysOnTop)
        pin.toolTip = "Always on Top"
        pinButton = pin
        container.addSubview(pin)
        xOffset += 26

        let inspector = NSButton(frame: NSRect(x: xOffset, y: 2, width: 18, height: 18))
        inspector.isBordered = false
        inspector.title = ""
        if let img = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "Sync")?
            .withSymbolConfiguration(config) {
            inspector.image = img
        }
        inspector.contentTintColor = .labelColor
        inspector.imagePosition = .imageOnly
        inspector.target = self
        inspector.action = #selector(toggleInspector(_:))
        inspector.toolTip = "Task Sync"
        inspectorButton = inspector
        container.addSubview(inspector)
        xOffset += 24

        let color = NSButton(frame: NSRect(x: xOffset, y: 3, width: 16, height: 16))
        color.wantsLayer = true
        color.layer?.cornerRadius = 8
        color.isBordered = false
        color.title = ""
        color.target = self
        color.action = #selector(toggleColorPicker(_:))
        color.toolTip = "Note Color"
        colorButton = color
        container.addSubview(color)
        xOffset += 24

        let countdown = NSTextField(labelWithString: "")
        countdown.frame = NSRect(x: xOffset, y: 1, width: 78, height: 18)
        countdown.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        countdown.alignment = .center
        countdown.wantsLayer = true
        countdown.layer?.cornerRadius = 9
        countdown.layer?.masksToBounds = true
        countdown.layer?.borderWidth = 0
        countdown.lineBreakMode = .byTruncatingTail
        countdown.isHidden = true
        dueDateLabel = countdown
        container.addSubview(countdown)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .right
        panel.addTitlebarAccessoryViewController(accessory)

        refreshColorSelectionUI()
        updateDueDateLabel()
        startDueDateRefreshTimer()
    }

    @objc private func toggleColorPicker(_ sender: NSButton) {
        toggleAuxiliaryOverlay(.colorPicker)
    }

    private func applySelectedColorValue(_ colorValue: String) {
        note.colorTheme = colorValue
        window?.backgroundColor = NoteColor.color(from: colorValue)
        coordinator?.changeNoteColor(noteId: note.id, colorTheme: colorValue)
        refreshColorSelectionUI()

        // Update titlebar mask in JS (only if we have the webview)
        if hasWebView {
            SharedWebViewManager.shared.webView.evaluateJavaScript(
                "window.setNoteColor('\(colorValue)')", completionHandler: nil
            )
        }
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        let opacity = sender.doubleValue
        note.opacity = opacity
        window?.alphaValue = CGFloat(opacity)
        coordinator?.setNoteOpacity(noteId: note.id, opacity: opacity)
    }

    @objc private func toggleAlwaysOnTop() {
        note.alwaysOnTop.toggle()
        setAlwaysOnTop(note.alwaysOnTop)
        coordinator?.setNoteAlwaysOnTop(noteId: note.id, alwaysOnTop: note.alwaysOnTop)
        pinButton?.alphaValue = note.alwaysOnTop ? 1.0 : 0.25
    }

    @objc private func toggleInspector(_ sender: NSButton) {
        guard coordinator != nil else { return }
        toggleAuxiliaryOverlay(.inspector)
    }

    private func toggleAuxiliaryOverlay(_ overlay: AuxiliaryOverlay) {
        if auxiliaryOverlay == overlay {
            dismissAuxiliaryOverlay()
            return
        }
        showAuxiliaryOverlay(overlay)
    }

    private func showAuxiliaryOverlay(_ overlay: AuxiliaryOverlay) {
        guard let panel = window as? NSPanel,
              let contentView = panel.contentView else {
            return
        }

        dismissAuxiliaryOverlay()
        auxiliaryOverlay = overlay
        isAwaitingDeleteConfirmation = overlay == .deleteConfirmation

        panel.orderFrontRegardless()

        let host = NSHostingView(rootView: AnyView(
            NoteAuxiliaryOverlayContainer(
                content: auxiliaryOverlayContent(for: overlay),
                onDismiss: { [weak self] in
                    self?.dismissAuxiliaryOverlay()
                }
            )
        ))
        host.frame = contentView.bounds
        host.autoresizingMask = [.width, .height]
        contentView.addSubview(host)
        auxiliaryOverlayHostingView = host
    }

    private func dismissAuxiliaryOverlay() {
        auxiliaryOverlayHostingView?.removeFromSuperview()
        auxiliaryOverlayHostingView = nil
        auxiliaryOverlay = nil
        isAwaitingDeleteConfirmation = false
    }

    private func auxiliaryOverlayContent(for overlay: AuxiliaryOverlay) -> AnyView {
        switch overlay {
        case .deleteConfirmation:
            return AnyView(
                NoteDeleteConfirmationOverlayView(
                    onCancel: { [weak self] in
                        self?.dismissAuxiliaryOverlay()
                    },
                    onDelete: { [weak self] in
                        guard let self else { return }
                        dismissAuxiliaryOverlay()
                        skipDeleteConfirmation = true
                        window?.close()
                    }
                )
            )
        case .colorPicker:
            return AnyView(
                NoteColorPickerPopoverView(
                    selectedColorValue: note.colorTheme,
                    onSelectColorValue: { [weak self] colorValue in
                        self?.applySelectedColorValue(colorValue)
                    }
                )
            )
        case .inspector:
            guard let coordinator else {
                return AnyView(Text("Inspector unavailable.").padding(12))
            }
            return AnyView(NoteInspectorView(coordinator: coordinator, noteId: note.id))
        }
    }

    private func setupContent() {
        guard let panel = window as? NSPanel else { return }

        let contentRect = panel.contentRect(forFrameRect: panel.frame)

        // Main container
        let container = NSView(frame: NSRect(origin: .zero, size: contentRect.size))
        container.autoresizingMask = [.width, .height]

        // Content container (will hold WKWebView or snapshot)
        contentContainer = NSView(frame: container.bounds)
        contentContainer.autoresizingMask = [.width, .height]
        container.addSubview(contentContainer)

        // Titlebar cursor overlay
        let titlebarOverlay = TitlebarCursorView(
            frame: NSRect(x: 0, y: contentRect.height - 28, width: contentRect.width, height: 28)
        )
        titlebarOverlay.autoresizingMask = [.width, .minYMargin]
        container.addSubview(titlebarOverlay)

        panel.contentView = container

        // Start with text preview of note content
        showTextPreview()
    }

    // MARK: - WebView Attach / Detach

    /// Attach the shared WKWebView to this window and switch editor to this note.
    /// Uses synchronous RunLoop-spin snapshot to avoid async timing gaps.
    func attachWebView() {
        guard !hasWebView else {
            if SharedWebViewManager.shared.isReady {
                revealWebView()
            }
            return
        }

        let manager = SharedWebViewManager.shared
        let wv = manager.webView

        let oldWC: NoteWindowController? = {
            guard let id = manager.activeNoteId, id != note.id else { return nil }
            return coordinator?.windowManager.getWindowController(for: id)
        }()
        let oldHadWebView = oldWC?.hasWebView ?? false

        guard let currentNote = coordinator?.noteManager.getNote(note.id) else { return }

        // 1. Synchronous snapshot of old content (WebView still in old window)
        if oldHadWebView {
            oldWC?.hasWebView = false

            if manager.isReady {
                // A. Serialize state first (preserves cursor position before we reset it)
                var serializedState: String?
                var serializeDone = false
                wv.evaluateJavaScript("window.serializeState()") { result, _ in
                    serializedState = result as? String
                    serializeDone = true
                }
                let serializeDeadline = Date().addingTimeInterval(0.1)
                while !serializeDone && Date() < serializeDeadline {
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
                }
                if let json = serializedState, let oldId = manager.activeNoteId {
                    manager.cacheSerializedState(json, for: oldId)
                }

                // B. Collapse all cursor unfolds, disable transitions, and blur
                var prepareDone = false
                wv.evaluateJavaScript("window.prepareForSnapshot()") { _, _ in
                    prepareDone = true
                }
                let prepareDeadline = Date().addingTimeInterval(0.1)
                while !prepareDone && Date() < prepareDeadline {
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
                }

                // C. Wait for compositor (transitions disabled, just need one paint cycle)
                let renderDeadline = Date().addingTimeInterval(0.05)
                while Date() < renderDeadline {
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
                }

                // D. Take snapshot
                var snapshot: NSImage?
                var done = false
                wv.takeSnapshot(with: WKSnapshotConfiguration()) { image, _ in
                    snapshot = image
                    done = true
                }
                let deadline = Date().addingTimeInterval(0.1)
                while !done && Date() < deadline {
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
                }

                // E. Re-enable transitions
                wv.evaluateJavaScript("window.endSnapshotMode()")

                if let image = snapshot {
                    oldWC?.showSnapshot(image)
                } else {
                    oldWC?.showTextPreview()
                }
            } else {
                // Editor not ready yet — show text preview (don't serialize empty editor state)
                oldWC?.showTextPreview()
            }
        }

        // 2. Move WebView to this window (hidden behind existing preview)
        wv.alphaValue = 0
        wv.frame = contentContainer.bounds
        wv.autoresizingMask = [.width, .height]
        contentContainer.addSubview(wv)
        hasWebView = true

        // 3. Switch editor to this note's content (skip serialization — already cached above)
        manager.switchToNoteSkippingSerialization(note.id, note: currentNote)

        // 4. Reveal after content renders (skip if editor not ready — markReady handles reveal)
        if manager.isReady {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.revealWebView()
            }
        }

        print("[NoteWindowController] Attached WebView for note: \(note.id)")
    }

    /// Reveal the hidden WebView, remove preview underneath, and focus the editor.
    func revealWebView() {
        guard hasWebView else { return }
        let wv = SharedWebViewManager.shared.webView
        wv.alphaValue = 1
        removeNonWebViewSubviews()
        wv.window?.makeFirstResponder(wv)
        wv.evaluateJavaScript("window.focusEditor()")
    }

    /// Show a snapshot of the last rendered editor state (preserves markdown rendering)
    func showSnapshot(_ image: NSImage) {
        removeNonWebViewSubviews()

        let imageView = NSImageView(frame: contentContainer.bounds)
        imageView.autoresizingMask = [.width, .height]
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignTopLeft
        snapshotView = imageView
        contentContainer.addSubview(imageView)
    }

    /// Show a plain-text preview of the note content (used on first load before any snapshot exists)
    func showTextPreview() {
        removeNonWebViewSubviews()

        let content = coordinator?.noteManager.getNote(note.id)?.content ?? note.content

        // Empty note — just show note color background
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let scrollView = NSScrollView(frame: contentContainer.bounds)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 32)
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = NSColor(white: 0.1, alpha: 0.75)
        textView.string = content
        textView.textContainer?.lineFragmentPadding = 4

        scrollView.documentView = textView
        contentContainer.addSubview(scrollView)
    }

    /// Remove all subviews except the WKWebView from contentContainer
    private func removeNonWebViewSubviews() {
        for sub in contentContainer.subviews where !(sub is WKWebView) {
            sub.removeFromSuperview()
        }
        snapshotView = nil
    }

    // MARK: - NSWindowDelegate Methods

    func windowDidBecomeKey(_ notification: Notification) {
        attachWebView()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Detach is handled by the NEW window's attachWebView().
        // This avoids the async timing race where detach would run
        // after the new window has already switched content.
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if suppressCloseCallback {
            return true
        }
        guard let coordinator = coordinator else { return true }
        if coordinator.isQuitting { return true }
        if skipDeleteConfirmation {
            skipDeleteConfirmation = false
            return true
        }

        guard let current = coordinator.noteManager.getNote(note.id),
              !current.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }

        presentDeleteConfirmationOverlay()
        return false
    }

    private func presentDeleteConfirmationOverlay() {
        guard !isAwaitingDeleteConfirmation else {
            return
        }
        showAuxiliaryOverlay(.deleteConfirmation)
    }

    func windowWillClose(_ notification: Notification) {
        dismissAuxiliaryOverlay()
        // If this window has the WebView, detach it
        if hasWebView {
            SharedWebViewManager.shared.webView.removeFromSuperview()
            hasWebView = false
        }
        guard !suppressCloseCallback else {
            suppressCloseCallback = false
            return
        }
        coordinator?.closeNoteWindow(note.id)
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = window else { return }
        coordinator?.handleWindowStateChange(noteId: note.id, size: window.frame.size)
    }

    func windowDidMove(_ notification: Notification) {
        guard let window = window else { return }
        coordinator?.handleWindowStateChange(noteId: note.id, position: window.frame.origin)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        coordinator?.handleWindowStateChange(noteId: note.id, isMinimized: true)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        coordinator?.handleWindowStateChange(noteId: note.id, isMinimized: false)
    }

    // MARK: - Public Methods

    func setOpacity(_ opacity: Double) {
        note.opacity = opacity
        window?.alphaValue = CGFloat(opacity)
    }

    func setColorTheme(_ theme: String) {
        note.colorTheme = theme
        window?.backgroundColor = NoteColor.color(from: theme)
        refreshColorSelectionUI()
        if hasWebView {
            SharedWebViewManager.shared.webView.evaluateJavaScript(
                "window.setNoteColor('\(theme)')", completionHandler: nil
            )
        }
    }

    func setAlwaysOnTop(_ alwaysOnTop: Bool) {
        note.alwaysOnTop = alwaysOnTop
        guard let panel = window as? NSPanel else { return }

        applyPanelBehavior(panel, alwaysOnTop: alwaysOnTop)
        if alwaysOnTop {
            panel.orderFrontRegardless()
        }

        pinButton?.alphaValue = alwaysOnTop ? 1.0 : 0.25
    }

    func setDueDate(_ dueDate: String?) {
        note.dueDate = dueDate
        updateDueDateLabel()
    }

    func applyNoteState(_ updatedNote: Note) {
        let previous = note
        note = updatedNote

        if previous.opacity != updatedNote.opacity {
            setOpacity(updatedNote.opacity)
        }
        if previous.colorTheme != updatedNote.colorTheme {
            setColorTheme(updatedNote.colorTheme)
        } else {
            refreshColorSelectionUI()
        }
        if previous.alwaysOnTop != updatedNote.alwaysOnTop {
            setAlwaysOnTop(updatedNote.alwaysOnTop)
        }
        if previous.dueDate != updatedNote.dueDate {
            setDueDate(updatedNote.dueDate)
        } else {
            updateDueDateLabel()
        }
    }

    func moveToActiveSpaceIfNeeded() {
        guard let panel = window as? NSPanel else { return }
        applyPanelBehavior(panel, alwaysOnTop: note.alwaysOnTop)
    }

    private func applyPanelBehavior(_ panel: NSPanel, alwaysOnTop: Bool) {
        var behavior: NSWindow.CollectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .transient,
        ]
        if #available(macOS 15.0, *) {
            behavior.insert(.canJoinAllApplications)
        } else {
            behavior.insert(.fullScreenAuxiliary)
        }
        panel.collectionBehavior = behavior

        if alwaysOnTop {
            panel.level = .popUpMenu
            panel.isFloatingPanel = true
        } else {
            panel.level = .floating
            panel.isFloatingPanel = true
        }
    }

    var noteId: UUID { note.id }

    /// Access the shared WKWebView (only valid when this window is active)
    var webView: WKWebView? {
        hasWebView ? SharedWebViewManager.shared.webView : nil
    }

    private func refreshColorSelectionUI() {
        let selectedColor = NoteColor.color(from: note.colorTheme)

        colorButton?.layer?.backgroundColor = selectedColor.cgColor
        colorButton?.layer?.borderWidth = 1.5
        colorButton?.layer?.borderColor = NSColor(white: 0, alpha: 0.18).cgColor
        colorButton?.toolTip = "Note Color: \(NoteColor.displayName(for: note.colorTheme))"
    }

    private func startDueDateRefreshTimer() {
        dueDateRefreshTimer?.invalidate()
        dueDateRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.updateDueDateLabel()
        }
        if let dueDateRefreshTimer {
            RunLoop.main.add(dueDateRefreshTimer, forMode: .common)
        }
    }

    private func updateDueDateLabel() {
        guard let dueDate = note.dueDate,
              let compactText = NoteDueDateDisplay.compactText(for: dueDate),
              let fullText = NoteDueDateDisplay.fullText(for: dueDate),
              let dayOffset = NoteDueDateDisplay.dayOffset(for: dueDate),
              let dueDateLabel else {
            self.dueDateLabel?.isHidden = true
            return
        }

        dueDateLabel.stringValue = compactText
        dueDateLabel.toolTip = "\(fullText) (\(dueDate))"
        let badgeStyle = dueDateBadgeStyle(for: dayOffset)
        dueDateLabel.textColor = badgeStyle.textColor
        dueDateLabel.layer?.backgroundColor = badgeStyle.backgroundColor.cgColor
        dueDateLabel.layer?.borderColor = badgeStyle.borderColor.cgColor
        dueDateLabel.layer?.borderWidth = badgeStyle.borderWidth
        dueDateLabel.isHidden = false
    }

    private func dueDateBadgeStyle(for dayOffset: Int) -> DueDateBadgeStyle {
        if dayOffset < 0 {
            let hue: CGFloat = 0
            return DueDateBadgeStyle(
                textColor: NSColor(calibratedHue: hue, saturation: 0.86, brightness: 0.58, alpha: 1),
                backgroundColor: NSColor(calibratedHue: hue, saturation: 0.16, brightness: 1, alpha: 1),
                borderColor: NSColor(calibratedHue: hue, saturation: 0.28, brightness: 0.86, alpha: 1),
                borderWidth: 1
            )
        }

        let maxDays: CGFloat = 14
        let progress = min(CGFloat(dayOffset), maxDays) / maxDays
        let hue = 0.33 * progress

        return DueDateBadgeStyle(
            textColor: NSColor(calibratedHue: hue, saturation: 0.84, brightness: 0.46, alpha: 1),
            backgroundColor: NSColor(calibratedHue: hue, saturation: 0.15, brightness: 1, alpha: 1),
            borderColor: NSColor(calibratedHue: hue, saturation: 0.24, brightness: 0.88, alpha: 1),
            borderWidth: 1
        )
    }

    private struct DueDateBadgeStyle {
        let textColor: NSColor
        let backgroundColor: NSColor
        let borderColor: NSColor
        let borderWidth: CGFloat
    }
}

// MARK: - Titlebar Views

private class TitlebarControlsView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}

private class TitlebarCursorView: NSView {
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .cursorUpdate, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        nextResponder?.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        nextResponder?.mouseUp(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        nextResponder?.mouseDragged(with: event)
    }
}

// MARK: - In-Window Auxiliary Overlay

private struct NoteAuxiliaryOverlayContainer: View {
    let content: AnyView
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            content
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .shadow(color: .black.opacity(0.24), radius: 18, x: 0, y: 10)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.black.opacity(0.12), lineWidth: 1)
                )
                .padding(.top, 30)
                .padding(.trailing, 12)
        }
    }
}

private struct NoteDeleteConfirmationOverlayView: View {
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete this note?")
                .font(.system(size: 15, weight: .semibold))

            Text("This note has content that will be lost and deleted from sync.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Delete", role: .destructive, action: onDelete)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 260)
    }
}
