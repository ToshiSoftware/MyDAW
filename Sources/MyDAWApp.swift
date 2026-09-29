import SwiftUI
import AVFoundation

final class MyDAWApplicationDelegate: NSObject, NSApplicationDelegate {
    var shutdownAudioEngine: (() -> Void)?
    /// Asks whether to save the project; false cancels the quit.
    var confirmQuit: (() -> Bool)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        (confirmQuit?() ?? true) ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        shutdownAudioEngine?()
        shutdownAudioEngine = nil
    }
}

@main
struct MyDAWApp: App {
    @NSApplicationDelegateAdaptor(MyDAWApplicationDelegate.self)
    private var applicationDelegate
    @StateObject private var projectState = ProjectState()

    init() {
        PluginManager.runVST3ScanChildIfRequested()
        // Request microphone permission on app launch if needed
        requestAudioPermissions()
    }

    var body: some Scene {
        WindowGroup {
            MainDAWView(projectState: projectState)
                .navigationTitle("MyDAW - Professional Audio Workstation")
                .onAppear {
                    applicationDelegate.shutdownAudioEngine = {
                        projectState.audioEngine.shutdown()
                    }
                    applicationDelegate.confirmQuit = {
                        projectState.confirmQuit()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1400, height: 900)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About MyDAW") {
                    let version = Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString"
                    ) as? String ?? "1.6"
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationVersion: version
                    ])
                }
            }

            SidebarCommands()
            CommandGroup(replacing: .newItem) {
                Button("New Project…") {
                    _ = projectState.createNewProject()
                }
                .keyboardShortcut("n", modifiers: [.command])

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

