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
