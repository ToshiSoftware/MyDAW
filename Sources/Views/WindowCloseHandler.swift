import SwiftUI
import AppKit

struct WindowCloseHandler: NSViewRepresentable {
    let projectState: ProjectState

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            if let window = view.window {
                context.coordinator.attach(to: window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            context.coordinator.attach(to: window)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(projectState: projectState)
    }

    /// Closing the window quits MyDAW; the save prompt lives in
    /// `applicationShouldTerminate` so the menu and ⌘Q ask too.
    final class Coordinator: NSObject, NSWindowDelegate {
        private let projectState: ProjectState
        private weak var window: NSWindow?

        init(projectState: ProjectState) {
            self.projectState = projectState
        }

        func attach(to window: NSWindow) {
            guard self.window !== window else { return }
            self.window = window
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
            return false
        }
    }
}

/// Double-clicking an empty spot of the title bar strip (the band holding
/// the close / minimise / zoom buttons) zooms the window to fill the screen
/// beside the menu bar and Dock, and back. With the hidden title bar the
/// strip lies over the content, so the click is caught before it gets there.
struct TitleBarZoomHandler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        weak var view: NSView?
        private var monitor: Any?

        func startMonitoring() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard event.clickCount == 2,
                      let window = self?.view?.window,
                      event.window === window,
                      Self.isInEmptyTitleBar(event.locationInWindow, of: window) else {
                    return event
                }
                window.zoom(nil)
                return nil
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        /// Above the content layout area (the title bar strip), and not on one
        /// of the window buttons.
        private static func isInEmptyTitleBar(_ point: NSPoint, of window: NSWindow) -> Bool {
            guard !window.styleMask.contains(.fullScreen),
                  point.y >= window.contentLayoutRect.maxY else { return false }
            let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
            return !buttons.contains { type in
                guard let button = window.standardWindowButton(type), let superview = button.superview else {
                    return false
                }
                return superview.convert(button.frame, to: nil).contains(point)
            }
        }
    }
}
