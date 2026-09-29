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

    final class Coordinator: NSObject, NSWindowDelegate {
        private let projectState: ProjectState
        private weak var window: NSWindow?
        private var isClosing = false

        init(projectState: ProjectState) {
            self.projectState = projectState
        }

        func attach(to window: NSWindow) {
            guard self.window !== window else { return }
            self.window = window
            window.delegate = self
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if isClosing {
                return true
            }

            guard projectState.isProjectOpen else {
                closeWindow()
                return false
            }

            let alert = NSAlert()
            alert.messageText = String(localized: "Save changes to MyDAW?")
            alert.informativeText = String(localized: "Do you want to save the project before quitting MyDAW?")
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "Save"))
            alert.addButton(withTitle: String(localized: "Don't Save"))
            alert.addButton(withTitle: String(localized: "Cancel"))

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                guard projectState.saveProject() else { return false }
                closeWindow()
            case .alertSecondButtonReturn:
                closeWindow()
            default:
                break
            }
            return false
        }

        private func closeWindow() {
            guard let window else { return }
            isClosing = true
            window.close()
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}