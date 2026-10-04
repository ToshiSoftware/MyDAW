import SwiftUI
import AVFoundation

final class MyDAWApplicationDelegate: NSObject, NSApplicationDelegate {
    var shutdownAudioEngine: (() -> Void)?
    /// Asks whether to save the project; false cancels the quit.
    var confirmQuit: (() -> Bool)?

    /// Opens a .mydaw file from the Finder. Files that arrive before the
    /// window has set this (MyDAW launched by a double-click) wait here.
    var openProjectFile: ((URL) -> Void)? {
        didSet { openPendingProjectFile() }
    }
    private var pendingProjectURL: URL?

    func application(_ application: NSApplication, open urls: [URL]) {
        // Only one project is open at a time, so the last file wins.
        guard let url = urls.last(where: { $0.isFileURL && $0.pathExtension.lowercased() == "mydaw" }) else { return }
        pendingProjectURL = url
        openPendingProjectFile()
    }

    private func openPendingProjectFile() {
        guard let openProjectFile, let url = pendingProjectURL else { return }
        pendingProjectURL = nil
        DispatchQueue.main.async { openProjectFile(url) }
    }

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
        Self.raiseOpenFileLimit()
        PluginManager.runVST3ScanChildIfRequested()
        // Request microphone permission on app launch if needed
        requestAudioPermissions()
    }

    /// Every clip keeps its audio file open for playback, and a project
    /// split into hundreds of clips passed the default limit of 256 open
    /// files; AppKit then failed to load menu resources and crashed. Raise
    /// the soft limit as far as the system allows.
    private static func raiseOpenFileLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        var perProcess: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let systemMax = sysctlbyname("kern.maxfilesperproc", &perProcess, &size, nil, 0) == 0 && perProcess > 0
            ? rlim_t(perProcess)
            : rlim_t(OPEN_MAX)
        let target = min(limit.rlim_max, systemMax, 65_536)
        guard target > limit.rlim_cur else { return }
        limit.rlim_cur = target
        if setrlimit(RLIMIT_NOFILE, &limit) != 0 {
            limit.rlim_cur = min(target, rlim_t(OPEN_MAX))
            _ = setrlimit(RLIMIT_NOFILE, &limit)
        }
    }

    var body: some Scene {
        WindowGroup {
            MainDAWView(projectState: projectState)
                // Shown in the Window menu and Mission Control; the plug-in
                // windows are told apart from this one by the "MyDAW" prefix.
                .navigationTitle(
                    projectState.openProjectName.map { Text(verbatim: "MyDAW - \($0)") }
                        ?? Text("MyDAW - Professional Audio Workstation")
                )
                .onAppear {
                    applicationDelegate.shutdownAudioEngine = {
                        projectState.audioEngine.shutdown()
                    }
                    applicationDelegate.confirmQuit = {
                        projectState.confirmQuit()
                    }
                    applicationDelegate.openProjectFile = { url in
                        projectState.openProjectFile(url)
                    }
                }
        }
        // Finder opens arrive through the delegate; without this SwiftUI
        // would also open a second window for each file.
        .handlesExternalEvents(matching: [])
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
                    ) as? String ?? "2.1"
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

                Button("Save Project As…") {
                    projectState.saveProjectAs()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!projectState.isProjectOpen || projectState.audioEngine.isPlaying || projectState.audioEngine.isRecording)

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

