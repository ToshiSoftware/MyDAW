import SwiftUI
import AVFoundation

@main
struct MyDAWApp: App {
    @StateObject private var projectState = ProjectState()

    init() {
        // Request microphone permission on app launch if needed
        requestAudioPermissions()
    }

    var body: some Scene {
        WindowGroup {
            MainDAWView(projectState: projectState)
                .navigationTitle("MyDAW - Professional Audio Workstation")
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About MyDAW") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationVersion: "1.0"
                    ])
                }
            }

            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                Button("Open Project…") {
                    projectState.loadProject()
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Save Project…") {
                    projectState.saveProject()
                }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(projectState.audioEngine.isPlaying || projectState.audioEngine.isRecording)

                Button("Export Master Mix…") {
                    projectState.beginMasterExportDialog()
                }
                .disabled(projectState.audioEngine.isPlaying || projectState.audioEngine.isRecording)
            }
            CommandGroup(after: .undoRedo) {
                Button("Undo Clip Edit") {
                    projectState.undo()
                }
                .keyboardShortcut("z", modifiers: [.command])
                .disabled(!projectState.canUndo || projectState.audioEngine.isPlaying || projectState.audioEngine.isRecording)

                Button("Redo Clip Edit") {
                    projectState.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!projectState.canRedo || projectState.audioEngine.isPlaying || projectState.audioEngine.isRecording)

                Button("Redo Clip Edit") {
                    projectState.redo()
                }
                .keyboardShortcut("y", modifiers: [.command])
                .disabled(!projectState.canRedo || projectState.audioEngine.isPlaying || projectState.audioEngine.isRecording)
            }
        }
    }

    private func requestAudioPermissions() {
        if #available(macOS 14.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                print("Microphone access granted: \(granted)")
            }
        } else {
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                print("Microphone access granted: \(granted)")
            }
        }
    }
}

