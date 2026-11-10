import AppKit
import SwiftUI

/// Borderless overlay that sits above the menu bar on every Space, including over
/// full-screen apps. It never becomes key, so it never steals keyboard focus.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        // The app is almost never the active one, and tooltips are otherwise only
        // shown for active apps.
        allowsToolTipsWhenApplicationIsInactive = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosts the SwiftUI content. Lets the first click on an inactive panel hit controls
/// directly, and reports the pointer entering or leaving the panel, where global
/// event monitors can't see it.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    var onPointerCrossing: (@MainActor () -> Void)?

    required init(rootView: Content) {
        super.init(rootView: rootView)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onPointerCrossing?()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointerCrossing?()
    }
}

/// An invisible window matched to the closed notch's visible shape (see
/// `NotchController.updateGesturePanel`). It receives trackpad scrolls and clicks on
/// the notch and its wings, so they never fall through to hidden menu-bar items, and
/// files dragged onto the notch.
final class NotchGesturePanel: NSPanel {
    /// Handlers for files dragged onto the closed notch: each returns whether it
    /// takes them.
    struct FileDrop {
        let entered: @MainActor ([URL]) -> Bool
        let dropped: @MainActor ([URL]) -> Bool
    }

    init(onCrossing: @escaping @MainActor () -> Void,
         onScroll: @escaping @MainActor (NSEvent) -> Void,
         onClick: @escaping @MainActor () -> Void,
         fileDrop: FileDrop) {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        // Fully transparent windows are click-through, so keep a trace of alpha.
        backgroundColor = NSColor(white: 0, alpha: 0.01)
        isOpaque = false
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        contentView = GestureView(onCrossing: onCrossing, onScroll: onScroll, onClick: onClick, fileDrop: fileDrop)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private final class GestureView: NSView {
        let onCrossing: @MainActor () -> Void
        let onScroll: @MainActor (NSEvent) -> Void
        let onClick: @MainActor () -> Void
        let fileDrop: FileDrop
        private var accepting = false

        init(onCrossing: @escaping @MainActor () -> Void,
             onScroll: @escaping @MainActor (NSEvent) -> Void,
             onClick: @escaping @MainActor () -> Void,
             fileDrop: FileDrop) {
            self.onCrossing = onCrossing
            self.onScroll = onScroll
            self.onClick = onClick
            self.fileDrop = fileDrop
            super.init(frame: .zero)
            // Only file drags: windows, text and links passing over the notch are
            // ignored, as before. Costs nothing until a file drag reaches the notch.
            registerForDraggedTypes([.fileURL])
            // While the pointer is over this window, global monitors stop seeing its
            // movement, so report entering, leaving and moving here instead. Moves only
            // flow while the pointer is over this small window.
            addTrackingArea(NSTrackingArea(rect: .zero,
                                           options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func mouseEntered(with event: NSEvent) { onCrossing() }
        override func mouseExited(with event: NSEvent) { onCrossing() }
        override func mouseMoved(with event: NSEvent) { onCrossing() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func scrollWheel(with event: NSEvent) { onScroll(event) }
        override func mouseDown(with event: NSEvent) { onClick() }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            accepting = fileDrop.entered(Self.files(sender))
            return accepting ? .copy : []
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
            accepting ? .copy : []
        }

        override func draggingExited(_ sender: NSDraggingInfo?) {
            accepting = false
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            defer { accepting = false }
            return fileDrop.dropped(Self.files(sender))
        }

        private static func files(_ sender: NSDraggingInfo) -> [URL] {
            sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                  options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        }
    }
}
