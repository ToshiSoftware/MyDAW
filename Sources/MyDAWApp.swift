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
        // Leave without running C++ static destructors. Plug-ins keep threads
        // of their own (JUCE timers, UAD services) that can outlive their
        // instances; exit() then tears down statics those threads still use,
        // and a plug-in crashes the quit now and then (seen with Deelay).
        // Everything MyDAW must write is written by now.
        UserDefaults.standard.synchronize()
        fflush(stdout)
        fflush(stderr)
        _exit(0)
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
        // The window cannot get shorter than its content's minimum, so the
        // tracks shrink to their minimum and the transport bar and mixer are
        // never cut off.
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1400, height: 900)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About MyDAW") {
                    let version = Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString"
                    ) as? String ?? "1.9"
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
                    projectState.saveProjectAndShowConfirmation()
                }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(projectState.audioEngine.isPlaying || projectState.audioEngine.isRecording)

                Divider()

                Button("Export Master Mix…") {
                    projectState.beginMasterExportDialog()
                }
                .disabled(projectState.audioEngine.isPlaying || projectState.audioEngine.isRecording)

                Divider()

                Button("Move Unused Recordings to Unused Folder") {
                    projectState.moveUnusedRecordings()
                }
                .disabled(!projectState.canMoveUnusedRecordings)
            }
            CommandGroup(replacing: .help) {
                Button("MyDAW Help") {
                    // The manual PDF on the web, in the GUI language; the
                    // system picks the app that opens it.
                    let urlString = AppLanguage.current == .japanese
                        ? "https://toshi.life.coocan.jp/note/OperationManual_jp.pdf"
                        : "https://toshi.life.coocan.jp/note/OperationManual_en.pdf"
                    if let url = URL(string: urlString) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .keyboardShortcut("?", modifiers: [.command])
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

