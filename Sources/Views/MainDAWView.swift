import SwiftUI

public struct MainDAWView: View {
    @ObservedObject private var projectState: ProjectState
    @State private var didInitializePlayhead = false

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

            // 2. Center Arranger & Tracks View
            ArrangerView(
                projectState: projectState,
                audioEngine: projectState.audioEngine
            )
            .frame(minHeight: 180, maxHeight: .infinity)

            MixerView(projectState: projectState)
                .frame(height: 370)
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
        .frame(minWidth: 800, minHeight: 450)
        .background(Color(red: 0.10, green: 0.11, blue: 0.13))
        .preferredColorScheme(.dark)
        .background(WindowCloseHandler(projectState: projectState))
        .sheet(isPresented: $projectState.isShowingMasterExportDialog) {
            MasterExportDialog(projectState: projectState)
        }
        .overlay {
            StartupLogDialog(logs: projectState.startupLog)
                .opacity(projectState.isShowingStartupLog ? 1.0 : 0.0)
                .allowsHitTesting(projectState.isShowingStartupLog)
        }
        .overlay {
            if !projectState.isProjectOpen {
                ProjectSelectionView(
                    onCreate: { _ = projectState.createNewProject() },
                    onOpen: { projectState.loadProject() }
                )
            }
        }
        .background(
            SpacebarHandler {
                guard !projectState.isShowingMasterExportDialog else { return }
                projectState.audioEngine.startPlayOrRecord(
                    tracks: projectState.tracks,
                    fxChannels: projectState.fxChannels
                )
            } rewind: {
                guard !projectState.isShowingMasterExportDialog else { return }
                projectState.audioEngine.rewind(tracks: projectState.tracks)
                projectState.timelineScrollTime = 0.0
            } record: {
                guard !projectState.isShowingMasterExportDialog else { return }
                if let selectedTrackID = projectState.selectedTrackId,
                   let track = projectState.tracks.first(where: { $0.id == selectedTrackID }) {
                    projectState.toggleRecordArm(for: track)
                } else if let firstTrack = projectState.tracks.first {
                    projectState.toggleRecordArm(for: firstTrack)
                }
            } undo: {
                guard !projectState.isShowingMasterExportDialog else { return }
                projectState.undo()
            } redo: {
                guard !projectState.isShowingMasterExportDialog else { return }
                projectState.redo()
            }
        )
        .onAppear {
            guard !didInitializePlayhead else { return }
            didInitializePlayhead = true
            projectState.audioEngine.rewind(tracks: projectState.tracks)
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
                    Text("プラグインを検出しています")
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
        _startText = State(initialValue: "0.000")
        _endText = State(initialValue: String(format: "%.3f", projectState.audioContentEndTime))
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
                Text(projectState.masterExportURL?.path ?? "No output file selected")
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

private struct SpacebarHandler: NSViewRepresentable {
    let action: () -> Void
    let rewind: () -> Void
    let record: () -> Void
    let undo: () -> Void
    let redo: () -> Void

    init(
        action: @escaping () -> Void,
        rewind: @escaping () -> Void,
        record: @escaping () -> Void,
        undo: @escaping () -> Void,
        redo: @escaping () -> Void
    ) {
        self.action = action
        self.rewind = rewind
        self.record = record
        self.undo = undo
        self.redo = redo
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action, rewind: rewind, record: record, undo: undo, redo: redo)
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
        private var monitor: Any?
        private var mouseMonitor: Any?

        init(
            action: @escaping () -> Void,
            rewind: @escaping () -> Void,
            record: @escaping () -> Void,
            undo: @escaping () -> Void,
            redo: @escaping () -> Void
        ) {
            self.action = action
            self.rewind = rewind
            self.record = record
            self.undo = undo
            self.redo = redo
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
                }

                guard modifiers.intersection([.command, .control, .option, .shift]).isEmpty else {
                    return event
                }
                switch event.keyCode {
                case 123:
                    self.rewind()
                    return nil
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

