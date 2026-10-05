import SwiftUI
import AppKit

public struct MainDAWView: View {
    @ObservedObject private var projectState: ProjectState
    @State private var didInitializePlayhead = false
    /// Current height of the tracks area, which the mixer may take from
    /// down to `minimumArrangerHeight` when it is resized upward.
    @State private var arrangerHeight: CGFloat = 0

    static let minimumArrangerHeight: CGFloat = 180

    public init(projectState: ProjectState) {
        self.projectState = projectState
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 1. Top Transport Bar
            TransportBarView(
                audioEngine: projectState.audioEngine,
                projectState: projectState
            )
            .environmentObject(projectState.timelineGeometry)

            // 2. Center Arranger & Tracks View
            ArrangerView(
                projectState: projectState,
                audioEngine: projectState.audioEngine
            )
            .environmentObject(projectState.timelineGeometry)
            .environmentObject(projectState.waveformDrawWindow)
            .frame(minHeight: Self.minimumArrangerHeight, maxHeight: .infinity)
            .background(GeometryReader { geometry in
                Color.clear
                    .onAppear { arrangerHeight = geometry.size.height }
                    .onChange(of: geometry.size.height) { arrangerHeight = $0 }
            })

            MixerView(
                projectState: projectState,
                growthLimit: Double(max(0, arrangerHeight - Self.minimumArrangerHeight))
            )
                .layoutPriority(1)

            // 3. Bottom Status Bar
            HStack(spacing: 16) {
                // Audio Engine & Device status
                HStack(spacing: 6) {
                    Circle()
                        .fill(projectState.audioEngine.isAudioInputActive ? Color.green : Color.red)
                        .frame(width: 7, height: 7)
                    Text("\(projectState.deviceManager.deviceName) (\(projectState.deviceManager.hardwareInputChannelCount) In)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                }

                Divider()
                    .frame(height: 12)
                    .background(Color.white.opacity(0.15))

                // Audio processing load and dropout mark
                AudioLoadIndicator(monitor: projectState.audioEngine.loadMonitor)

                Divider()
                    .frame(height: 12)
                    .background(Color.white.opacity(0.15))

                // Storage location with Reveal in Finder button
                Button(action: {
                    projectState.audioEngine.revealRecordingsFolder()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.yellow.opacity(0.9))
                        Text(projectState.audioEngine.recordingsDirectory.path)
                            .font(.system(size: 10))
                            .foregroundColor(.cyan.opacity(0.9))
                            .underline()
                    }
                }
                .buttonStyle(PlainButtonStyle())
                .help("Click to reveal Recordings folder in Finder")

                Spacer()

                // Keyboard shortcuts guide
                HStack(spacing: 12) {
                    Text("Space: Play/Stop")
                    Text("Rewind: |<<")
                    Text("[R]: Arm Record")
                }
                .font(.system(size: 9, weight: .regular))
                .foregroundColor(.white.opacity(0.4))
            }
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(Color(red: 0.12, green: 0.13, blue: 0.15))
            .overlay(
                Rectangle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
        }
        .frame(minWidth: 800)
        .background(Color(red: 0.10, green: 0.11, blue: 0.13))
        .preferredColorScheme(.dark)
        .background(WindowCloseHandler(projectState: projectState))
        .background(TitleBarZoomHandler())
        .overlay {
            // The open project's name, centred in the title bar strip above
            // the transport bar (the window's own title is hidden).
            // The content starts just below the strip, so its distance from
            // the window top is the strip's height (0 in full screen).
            GeometryReader { geometry in
                let stripHeight = geometry.frame(in: .global).minY
                if let projectName = projectState.openProjectName, stripHeight > 0 {
                    Text(projectName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 90)
                        .frame(width: geometry.size.width, height: stripHeight)
                        .offset(y: -stripHeight)
                }
            }
            .allowsHitTesting(false)
        }
        .sheet(isPresented: $projectState.isShowingMasterExportDialog) {
            MasterExportDialog(projectState: projectState)
        }
        .overlay {
            // Removed (not just hidden) when done, so it cannot sit over the
            // controls and affect their tooltips.
            if projectState.isShowingStartupLog {
                StartupLogDialog(logs: projectState.startupLog)
            }
        }
        .overlay {
            if let message = projectState.saveConfirmationMessage {
                ZStack {
                    Color.black.opacity(0.28)
                    Text(message)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 28)
                        .padding(.vertical, 18)
                        .background(Color.black.opacity(0.8))
                        .cornerRadius(8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .overlay {
            if !projectState.isProjectOpen {
                ProjectSelectionView(
                    onCreate: {
                        DispatchQueue.main.async {
                            _ = projectState.createNewProject()
                        }
                    },
                    onOpen: {
                        DispatchQueue.main.async {
                            projectState.loadProject()
                        }
                    },
                    onOpenRecent: { entry in
                        DispatchQueue.main.async {
                            projectState.openRecentProject(entry)
                        }
                    }
                )
            }
        }
        // SwiftUI registers tooltip areas when the layout changes. Removing a
        // full-window overlay (start screen, plug-in scan log) leaves the
        // controls' layout unchanged, so their tooltips stay inactive until
        // the window is resized. Do the equivalent of a resize at those points.
        .onChange(of: projectState.isProjectOpen) { isOpen in
            if isOpen { refreshToolTips() }
        }
        .onChange(of: projectState.isShowingStartupLog) { isShowing in
            if !isShowing { refreshToolTips() }
        }
        .background(
            SpacebarHandler {
                guard !projectState.isShowingMasterExportDialog else { return }
                projectState.toggleTransport(recordArmedTracks: false)
            } rewind: {
                guard !projectState.isShowingMasterExportDialog else { return }
                projectState.rewindToSongStart()
            } record: {
                // Same as the record (red circle) button.
                guard !projectState.isShowingMasterExportDialog else { return }
                projectState.toggleTransport(recordArmedTracks: true)
            } undo: {
                guard !projectState.isShowingMasterExportDialog else { return }
                projectState.undo()
            } redo: {
                guard !projectState.isShowingMasterExportDialog else { return }
                projectState.redo()
            } edit: { command in
                guard !projectState.isShowingMasterExportDialog else { return }
                switch command {
                case .cut: projectState.cutSelection()
                case .copy: projectState.copySelection()
                case .paste: projectState.paste()
                case .selectAll: projectState.selectAllClips()
                case .clearSelection: projectState.clearSelection()
                }
            }
        )
        .onAppear {
            guard !didInitializePlayhead else { return }
            didInitializePlayhead = true
            projectState.audioEngine.rewind(tracks: projectState.tracks)
            if let projectArg = CommandLine.arguments.dropFirst().first(where: { $0.hasSuffix(".mydaw") }) {
                let url = URL(fileURLWithPath: projectArg)
                let folder = url.deletingLastPathComponent()
                DispatchQueue.main.async {
                    projectState.loadProject(from: url, projectFolderURL: folder)
                }
            }
        }
    }
}

extension MainDAWView {
    /// Nudges the window width by one point and back, which makes AppKit and
    /// SwiftUI re-register the tooltip areas just as a manual resize does.
    fileprivate func refreshToolTips() {
        DispatchQueue.main.async {
            // Only the main window (plug-in windows are titled after the plug-in).
            for window in NSApp.windows where window.isVisible && window.title.hasPrefix("MyDAW") {
                let frame = window.frame
                var nudged = frame
                nudged.size.width += 1
                window.setFrame(nudged, display: false)
                window.setFrame(frame, display: true)
            }
        }
    }
}

private struct StartupLogDialog: View {
    let logs: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning for plug-ins")
                        .font(.headline)
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(logs.enumerated()), id: \.offset) { index, log in
                                Text(log)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                    }
                    .frame(height: 190)
                    .onChange(of: logs.count) { _ in
                        if let lastIndex = logs.indices.last {
                            proxy.scrollTo(lastIndex, anchor: .bottom)
                        }
                    }
                }
        }
        .padding(20)
        .frame(width: 520, height: 280)
        .background(Color.black)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.white.opacity(0.45), lineWidth: 1)
        )
        .interactiveDismissDisabled(true)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private struct MasterExportDialog: View {
    @ObservedObject var projectState: ProjectState
    @Environment(\.dismiss) private var dismiss
    @State private var startText: String
    @State private var endText: String

    init(projectState: ProjectState) {
        self.projectState = projectState
        // The song start / end flags, when set, give the range to export.
        _startText = State(initialValue: String(format: "%.3f", projectState.songStartTime ?? 0.0))
        _endText = State(initialValue: String(format: "%.3f", projectState.songEndTime ?? projectState.audioContentEndTime))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Master Mix")
                .font(.headline)

            Text("The master output will be rendered in real time as a 24-bit WAV file.")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Output file")
                    .font(.caption.weight(.semibold))
                Text(projectState.masterExportURL?.path ?? String(localized: "No output file selected"))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Color.black.opacity(0.15))
                    .cornerRadius(4)
            }

            HStack {
                Text("Start (seconds)")
                TextField("0.000", text: $startText)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Text("End (seconds)")
                TextField("0.000", text: $endText)
                    .textFieldStyle(.roundedBorder)
            }

            if projectState.isExportingMasterMix {
                ProgressView("Exporting master mix…")
                    .controlSize(.small)
            } else if let error = projectState.masterExportError {
                Text("Export failed: \(error)")
                    .font(.caption)
                    .foregroundColor(.red)
            } else if projectState.masterExportCompleted {
                Text("Export completed successfully.")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.green)
            }

            HStack {
                Spacer()
                Button(projectState.masterExportCompleted ? "Close" : "Cancel") {
                    if projectState.isExportingMasterMix {
                        projectState.cancelMasterExport()
                    } else {
                        dismiss()
                    }
                }
                    .keyboardShortcut(projectState.masterExportCompleted ? .defaultAction : .cancelAction)
                Button("Export") {
                    guard let start = Double(startText),
                          let end = Double(endText),
                          start >= 0.0,
                          end > start else { return }
                    projectState.exportMasterMix(startTime: start, endTime: end)
                }
                .disabled(projectState.isExportingMasterMix || projectState.masterExportCompleted)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}

/// Clip-editing keys handled in the arranger (outside text fields).
private enum EditCommand {
    case cut, copy, paste, selectAll, clearSelection
}

private struct SpacebarHandler: NSViewRepresentable {
    let action: () -> Void
    let rewind: () -> Void
    let record: () -> Void
    let undo: () -> Void
    let redo: () -> Void
    let edit: (EditCommand) -> Void

    init(
        action: @escaping () -> Void,
        rewind: @escaping () -> Void,
        record: @escaping () -> Void,
        undo: @escaping () -> Void,
        redo: @escaping () -> Void,
        edit: @escaping (EditCommand) -> Void
    ) {
        self.action = action
        self.rewind = rewind
        self.record = record
        self.undo = undo
        self.redo = redo
        self.edit = edit
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action, rewind: rewind, record: record, undo: undo, redo: redo, edit: edit)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.action = action
        context.coordinator.rewind = rewind
        context.coordinator.record = record
        context.coordinator.undo = undo
        context.coordinator.redo = redo
        context.coordinator.edit = edit
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoring()
    }

    final class Coordinator {
        var action: () -> Void
        var rewind: () -> Void
        var record: () -> Void
        var undo: () -> Void
        var redo: () -> Void
        var edit: (EditCommand) -> Void
        private var monitor: Any?
        private var mouseMonitor: Any?

        init(
            action: @escaping () -> Void,
            rewind: @escaping () -> Void,
            record: @escaping () -> Void,
            undo: @escaping () -> Void,
            redo: @escaping () -> Void,
            edit: @escaping (EditCommand) -> Void
        ) {
            self.action = action
            self.rewind = rewind
            self.record = record
            self.undo = undo
            self.redo = redo
            self.edit = edit
        }

        func startMonitoring() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let modifiers = event.modifierFlags
                let hasCommand = modifiers.contains(.command)
                let hasShift = modifiers.contains(.shift)
                let hasOtherModifier = modifiers.intersection([.control, .option]).isEmpty == false

                if let firstResponder = event.window?.firstResponder,
                   firstResponder is NSTextView || firstResponder is NSTextField {
                    return event
                }

                if hasCommand && !hasOtherModifier {
                    if event.keyCode == 6 {
                        if hasShift {
                            self.redo()
                        } else {
                            self.undo()
                        }
                        return nil
                    }
                    if event.keyCode == 16 {
                        self.redo()
                        return nil
                    }
                    let editCommands: [UInt16: EditCommand] = [
                        7: .cut, 8: .copy, 9: .paste, 0: .selectAll
                    ]
                    if !hasShift, let command = editCommands[event.keyCode] {
                        self.edit(command)
                        return nil
                    }
                }

                guard modifiers.intersection([.command, .control, .option, .shift]).isEmpty else {
                    return event
                }
                switch event.keyCode {
                case 123:
                    self.rewind()
                    return nil
                case 15:
                    // R: start recording (or stop, like the record button).
                    // Holding the key must not toggle again.
                    if !event.isARepeat {
                        self.record()
                    }
                    return nil
                case 53:
                    // Pass Escape on so dialogs can still use it to cancel.
                    self.edit(.clearSelection)
                    return event
                default:
                    return event
                }
            }
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                guard let window = event.window,
                      let firstResponder = window.firstResponder as? NSView,
                                            let contentView = window.contentView else {
                                        return event
                                }
                                let contentPoint = contentView.convert(event.locationInWindow, from: nil)
                                guard let hitView = contentView.hitTest(contentPoint),
                      hitView !== firstResponder,
                      !hitView.isDescendant(of: firstResponder) else {
                    return event
                }
                window.makeFirstResponder(nil)
                return event
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            if let mouseMonitor {
                NSEvent.removeMonitor(mouseMonitor)
                self.mouseMonitor = nil
            }
        }
    }
}

