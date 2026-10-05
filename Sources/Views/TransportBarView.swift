import SwiftUI
import AppKit
import CoreAudio

public struct TransportBarView: View {
    /// Zoom and track height: observed so this view follows them (see
    /// `ProjectState.timelineGeometry`).
    @EnvironmentObject var timelineGeometry: TimelineGeometry
    @ObservedObject public var audioEngine: AudioEngineManager
    @ObservedObject public var projectState: ProjectState
    @State private var showingBufferSettings = false
    @State private var isShowingClickVolume = false
    @State private var bpmText = "120"
    @FocusState private var focusedField: FocusedField?

    private enum FocusedField {
        case bpm
    }

    public init(audioEngine: AudioEngineManager, projectState: ProjectState) {
        self.audioEngine = audioEngine
        self.projectState = projectState
    }

    private var isTransportActive: Bool {
        audioEngine.isPlaying || audioEngine.isStartingPlayback
    }

    private var rollbackHelp: LocalizedStringKey {
        let bars = projectState.recordRollbackBars
        if projectState.recordRollbackEnabled {
            return "Disable Rollback Recording (\(bars) bars)"
        }
        return "Enable Rollback Recording (\(bars) bars)"
    }

    private func commitBPMText() {
        let parsedValue = Double(bpmText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? audioEngine.bpm
        let clamped = max(20.0, min(400.0, parsedValue))
        audioEngine.commitBPM(clamped)
        bpmText = String(format: "%.0f", clamped)
    }

    public var body: some View {
        HStack(spacing: 12) {
            // Transport Controls: Rewind, Stop, Play, Record
            HStack(spacing: 4) {
                Button(action: { showingBufferSettings = true }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white.opacity(0.75))
                        .frame(width: 34, height: 28)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(5)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(audioEngine.isPlaying || audioEngine.isRecording)
                .help("Settings")

                Button(action: { projectState.undo() }) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(projectState.canUndo ? .white : .white.opacity(0.3))
                        .frame(width: 34, height: 28)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(5)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(!projectState.canUndo || audioEngine.isPlaying || audioEngine.isRecording)
                .help("Undo Clip Edit")

                Button(action: { projectState.redo() }) {
                    Image(systemName: "arrow.uturn.forward")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(projectState.canRedo ? .white : .white.opacity(0.3))
                        .frame(width: 34, height: 28)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(5)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(!projectState.canRedo || audioEngine.isPlaying || audioEngine.isRecording)
                .help("Redo Clip Edit")

                // Rewind (|<<)
                Button(action: {
                    projectState.rewindToSongStart()
                }) {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 34, height: 28)
                        .background(Color.white.opacity(0.12))
                        .cornerRadius(5)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Rewind to Song Start (on or before it: to 00:00.000)")

                Button(action: {
                    DispatchQueue.main.async {
                        projectState.toggleTransport(recordArmedTracks: false)
                    }
                }) {
                    Image(systemName: isTransportActive ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(isTransportActive ? .black : .green)
                        .frame(width: 40, height: 28)
                        .background(
                            isTransportActive
                                ? Color.green
                                : Color.green.opacity(0.18)
                        )
                        .cornerRadius(5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.green.opacity(0.6), lineWidth: 1)
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .keyboardShortcut(.space, modifiers: [])
                .help("Start / Pause (Spacebar)")

                // Record status indicator / start recording
                let anyArmed = projectState.tracks.contains { $0.isRecordArmed }
                Button(action: {
                    DispatchQueue.main.async {
                        projectState.toggleTransport(recordArmedTracks: true)
                    }
                }) {
                    Circle()
                        .fill(audioEngine.isRecording ? Color.red : (anyArmed ? Color.red.opacity(0.8) : Color.white.opacity(0.12)))
                        .frame(width: 14, height: 14)
                        .frame(width: 34, height: 28)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(audioEngine.isRecording ? Color.red : Color.clear, lineWidth: 1.5)
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .help(anyArmed ? "Record Armed Tracks (R)" : "No Tracks Armed for Recording")

                Button {
                    projectState.setPunchEnabled(!projectState.punchRange.enabled)
                } label: {
                    Text("P")
                        .font(.system(size: 11, weight: .black))
                        .foregroundColor(projectState.punchRange.enabled ? .black : .red.opacity(0.75))
                        .frame(width: 34, height: 20)
                        .background(projectState.punchRange.enabled ? Color.red : Color.white.opacity(0.08))
                        .cornerRadius(3)
                }
                .buttonStyle(PlainButtonStyle())
                .help(projectState.punchRange.enabled ? "Disable Punch In/Out" : "Enable Punch In/Out")

                // Rollback recording; a punch recording ignores it (dimmed).
                Button {
                    projectState.recordRollbackEnabled.toggle()
                } label: {
                    let isOn = projectState.recordRollbackEnabled
                    HStack(spacing: 1) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9, weight: .black))
                        Text(verbatim: "\(projectState.recordRollbackBars)")
                            .font(.system(size: 11, weight: .black))
                    }
                    .foregroundColor(isOn ? .black : .red.opacity(0.75))
                    .frame(width: 34, height: 20)
                    .background(isOn ? Color.red : Color.white.opacity(0.08))
                    .cornerRadius(3)
                    .opacity(isOn && projectState.punchRange.enabled ? 0.45 : 1.0)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(audioEngine.isPlaying || audioEngine.isRecording)
                .help(rollbackHelp)

                Toggle(isOn: $audioEngine.metronomeEnabled) {
                    Image(systemName: "metronome")
                        .font(.system(size: 13, weight: .bold))
                }
                .toggleStyle(.button)
                .tint(audioEngine.metronomeEnabled ? .orange : .white.opacity(0.35))
                .frame(width: 34, height: 28)
                .help("Toggle Metronome Click (right-click for click volume)")
                // Right-click: a fader for the click volume, usable while
                // playing.
                .background(RightClickCatcher { isShowingClickVolume = true })
                .popover(isPresented: $isShowingClickVolume, arrowEdge: .bottom) {
                    ClickVolumeFader(audioEngine: audioEngine)
                }

                Button(action: { projectState.saveProjectAndShowConfirmation() }) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.cyan.opacity(audioEngine.isPlaying ? 0.35 : 0.9))
                        .frame(width: 34, height: 28)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(5)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(audioEngine.isPlaying || audioEngine.isRecording)
                .help("Save Project")

                Button(action: { projectState.loadProject() }) {
                    Image(systemName: "folder")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.cyan.opacity(audioEngine.isPlaying ? 0.35 : 0.9))
                        .frame(width: 34, height: 28)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(5)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(audioEngine.isPlaying || audioEngine.isRecording)
                .help("Open Project")

                Button(action: { projectState.snapToGrid.toggle() }) {
                    Image(systemName: projectState.snapToGrid ? "square.grid.3x3.fill" : "square.grid.3x3")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(projectState.snapToGrid ? .black : .white.opacity(0.75))
                        .frame(width: 34, height: 28)
                        .background(projectState.snapToGrid ? Color.orange : Color.white.opacity(0.08))
                        .cornerRadius(5)
                }
                .buttonStyle(PlainButtonStyle())
                .help(projectState.snapToGrid ? "Disable Beat Snap" : "Enable Beat Snap")

                Button(action: { projectState.autoScrollEnabled.toggle() }) {
                    // |-> : the view follows the playhead.
                    HStack(spacing: 1) {
                        Rectangle()
                            .frame(width: 2, height: 12)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundColor(projectState.autoScrollEnabled ? .black : .white.opacity(0.75))
                    .frame(width: 34, height: 28)
                    .background(projectState.autoScrollEnabled ? Color.orange : Color.white.opacity(0.08))
                    .cornerRadius(5)
                }
                .buttonStyle(PlainButtonStyle())
                .help(projectState.autoScrollEnabled ? "Disable Auto-Scroll" : "Enable Auto-Scroll")
            }

            // LCD Display: Time & Audio Format (Logic Pro Dark Glass Style)
            HStack(spacing: 16) {
                // Time counter
                VStack(alignment: .leading, spacing: 2) {
                    Text("TIME")
                        .font(.system(size: 8, weight: .black))
                        .foregroundColor(.white.opacity(0.4))
                    TransportTimeText(
                        clock: audioEngine.transportClock,
                        showsBeats: projectState.showsBeats,
                        bpm: audioEngine.bpm
                    )
                        .font(.system(size: 17, weight: .bold, design: .monospaced))
                        .foregroundColor(audioEngine.isRecording ? Color.red : Color.cyan)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }

                Divider()
                    .frame(height: 24)
                    .background(Color.white.opacity(0.15))

                VStack(alignment: .leading, spacing: 2) {
                    Text("TEMPO")
                        .font(.system(size: 8, weight: .black))
                        .foregroundColor(.white.opacity(0.4))
                    HStack(spacing: 3) {
                        TextField("BPM", text: $bpmText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .frame(width: 38)
                            .multilineTextAlignment(.trailing)
                            .focused($focusedField, equals: .bpm)
                            .onAppear {
                                bpmText = String(format: "%.0f", audioEngine.bpm)
                            }
                            .onChange(of: audioEngine.bpm) { newValue in
                                bpmText = String(format: "%.0f", newValue)
                            }
                            .onChange(of: bpmText) { newValue in
                                let sanitizedValue = newValue.filter { !$0.isWhitespace }
                                if sanitizedValue != newValue {
                                    bpmText = sanitizedValue
                                    return
                                }
                                guard let value = Double(newValue),
                                      value >= 20.0,
                                      value <= 400.0 else { return }
                                audioEngine.commitBPM(value)
                            }
                            .onSubmit {
                                commitBPMText()
                            }
                            .onChange(of: focusedField) { newValue in
                                if newValue == nil {
                                    commitBPMText()
                                }
                            }
                        Text("BPM")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.orange)
                    }
                }

                // Format & Sample Rate Badge
                VStack(alignment: .leading, spacing: 2) {
                    Text("FORMAT")
                        .font(.system(size: 8, weight: .black))
                        .foregroundColor(.white.opacity(0.4))
                    HStack(spacing: 6) {
                        Text("24-bit WAV")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.orange)

                        Text("\(Int(audioEngine.hardwareSampleRate / 1000.0)) kHz")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.white.opacity(0.15))
                            .cornerRadius(3)
                    }
                }

            }
            .frame(height: 38, alignment: .leading)
            .layoutPriority(1)
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(Color(red: 0.10, green: 0.11, blue: 0.13))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
            )

            Spacer()

            // Zoom Controls
            HStack(spacing: 2) {
                Button(action: { projectState.zoomOut() }) {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(4)
                }
                .buttonStyle(PlainButtonStyle())

                Button(action: { projectState.zoomIn() }) {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.7))
                        .frame(width: 24, height: 24)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(4)
                }
                .buttonStyle(PlainButtonStyle())
            }

            HStack(spacing: 5) {
                Image(systemName: "timeline.selection")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                // Logarithmic, so each step zooms by the same ratio.
                Slider(
                    value: Binding(
                        get: { log2(Double(projectState.pixelsPerSecond)) },
                        set: { projectState.setPixelsPerSecond(CGFloat(pow(2.0, $0))) }
                    ),
                    in: log2(Double(ProjectState.minimumPixelsPerSecond))...log2(Double(ProjectState.maximumPixelsPerSecond))
                )
                .frame(width: 90)
                .accentColor(.cyan)
                Text("\(Int(projectState.pixelsPerSecond))")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 28, alignment: .trailing)
                    .help("Timeline pixels per second")
            }

            HStack(spacing: 4) {
                Image(systemName: "rectangle.split.3x1")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                Slider(
                    value: Binding(
                        get: { projectState.trackHeightScale },
                        set: { projectState.setTrackHeightScale($0) }
                    ),
                    in: ProjectState.minimumTrackHeightScale...ProjectState.maximumTrackHeightScale
                )
                    .frame(width: 70)
                    .accentColor(.yellow)
                Text("×\(String(format: "%.1f", projectState.trackHeightScale))")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 28, alignment: .trailing)
                    .help("All track heights")

                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                Slider(
                    value: Binding(
                        get: { log2(Double(projectState.waveformScalePreview.target ?? projectState.waveformVerticalScale)) },
                        set: { projectState.previewWaveformVerticalScale(CGFloat(pow(2.0, $0))) }
                    ),
                    in: 0.0...log2(Double(ProjectState.maximumWaveformVerticalScale))
                )
                .frame(width: 70)
                .accentColor(.orange)
                PreviewValueText(preview: projectState.waveformScalePreview, value: projectState.waveformVerticalScale) {
                    "×\(String(format: $0 < 10.0 ? "%.1f" : "%.0f", $0))"
                }
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 30, alignment: .trailing)
                    .help("Waveform vertical scale")
            }

            Button(action: {
                projectState.showsBeats.toggle()
            }) {
                Image(systemName: projectState.showsBeats ? "music.note.list" : "clock")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(projectState.showsBeats ? .orange : .cyan)
                    .frame(width: 34, height: 24)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(4)
            }
            .buttonStyle(PlainButtonStyle())
            .help(projectState.showsBeats ? "Show Time Ruler" : "Show Bars and Beats Ruler")

        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        // When the window is narrower than the bar, pin it to the left and
        // cut off the right end, so the transport buttons stay visible
        // (by default the overflow is centred, clipping both ends).
        // minWidth 0: without it the frame grows to the bar's full width.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        .background(Color(red: 0.16, green: 0.17, blue: 0.20))
        .overlay(
            Rectangle()
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .zIndex(2)
        .sheet(isPresented: $showingBufferSettings) {
            BufferSettingsView(
                deviceManager: projectState.deviceManager,
                audioEngine: audioEngine,
                projectState: projectState,
                onAudioDevicesChanged: {
                    // Let the sheet close before the modal alert appears.
                    DispatchQueue.main.async {
                        projectState.promptRestartForAudioSettings()
                    }
                }
            )
        }
    }
}

/// A control's value label that follows its preview while the control moves.
private struct PreviewValueText: View {
    @ObservedObject var preview: PreviewScale
    let value: CGFloat
    let format: (CGFloat) -> String

    var body: some View {
        Text(verbatim: format(preview.target ?? value))
    }
}

/// The click volume as a vertical fader, popped up from the metronome
/// button. It changes the volume at once, also while playing.
private struct ClickVolumeFader: View {
    @ObservedObject var audioEngine: AudioEngineManager

    var body: some View {
        VStack(spacing: 6) {
            Text("Click")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
            // Drawn here rather than a rotated Slider: a rotated AppKit
            // slider takes clicks but is not drawn in a popover.
            VerticalLevelFader(value: $audioEngine.metronomeVolume)
                .frame(width: 28, height: 140)
            Text(verbatim: "\(Int((audioEngine.metronomeVolume * 100.0).rounded()))%")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
        }
        .padding(10)
    }
}

/// A vertical fader for a 0...1 value: click or drag anywhere on it.
private struct VerticalLevelFader: View {
    @Binding var value: Double

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let knobHeight: CGFloat = 10
            let travel = max(1, height - knobHeight)
            let level = CGFloat(min(1, max(0, value)))
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 4)
                    .frame(maxHeight: .infinity)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.orange)
                    .frame(width: 4, height: knobHeight / 2 + travel * level)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.black.opacity(0.35), lineWidth: 0.5))
                    .frame(width: 24, height: knobHeight)
                    .offset(y: -travel * level)
            }
            .frame(width: geometry.size.width, height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let fromBottom = height - knobHeight / 2 - drag.location.y
                        value = Double(min(1, max(0, fromBottom / travel)))
                    }
            )
        }
    }
}

/// Calls `action` on a right-click (or Control-click) on the view it is the
/// background of, leaving left-clicks to the view.
private struct RightClickCatcher: NSViewRepresentable {
    let action: @MainActor () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.action = action
    }

    final class CatcherView: NSView {
        var action: (@MainActor () -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
            } else if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { [weak self] event in
                    self?.handle(event) ?? event
                }
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window, window.attachedSheet == nil else { return event }
            if event.type == .leftMouseDown && !event.modifierFlags.contains(.control) { return event }
            let point = convert(event.locationInWindow, from: nil)
            guard visibleRect.contains(point) else { return event }
            action?()
            return nil
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            removeMonitor()
        }
    }
}

/// The time counter, observing only the playhead.
private struct TransportTimeText: View {
    @ObservedObject var clock: TransportClock
    let showsBeats: Bool
    let bpm: Double

    var body: some View {
        Text(showsBeats ? barBeatString : timeString)
    }

    private var timeString: String {
        let totalSeconds = clock.time
        let minutes = Int(totalSeconds) / 60
        let seconds = Int(totalSeconds) % 60
        let milliseconds = Int((totalSeconds.truncatingRemainder(dividingBy: 1.0)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", minutes / 60, minutes % 60, seconds, milliseconds)
    }

    private var barBeatString: String {
        let beatDuration = 60.0 / max(20.0, min(400.0, bpm))
        let totalBeats = max(0, Int(floor(clock.time / beatDuration)))
        return String(format: "%03d:%02d", totalBeats / 4 + 1, totalBeats % 4 + 1)
    }
}

private struct BufferSettingsView: View {
    @ObservedObject var deviceManager: AudioDeviceManager
    @ObservedObject var audioEngine: AudioEngineManager
    @ObservedObject var projectState: ProjectState
    /// Called after a change that needs a restart (device, sample rate or
    /// language) was applied.
    let onAudioDevicesChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedBufferSize: Int
    @State private var selectedInputDeviceID: AudioDeviceID
    @State private var selectedOutputDeviceID: AudioDeviceID
    @State private var selectedSampleRate: Double
    @State private var recordingCompensationText: String
    @State private var clickTimingOffsetText: String
    @State private var rollbackBarsText: String
    @State private var selectedLanguage = AppLanguage.current

    private let bufferSizes = [128, 256, 512, 1024, 2048, 4096]
    private let sampleRates = [44100.0, 48000.0, 88200.0, 96000.0]

    init(
        deviceManager: AudioDeviceManager,
        audioEngine: AudioEngineManager,
        projectState: ProjectState,
        onAudioDevicesChanged: @escaping () -> Void
    ) {
        self.deviceManager = deviceManager
        self.audioEngine = audioEngine
        self.projectState = projectState
        _rollbackBarsText = State(initialValue: "\(projectState.recordRollbackBars)")
        self.onAudioDevicesChanged = onAudioDevicesChanged
        _selectedBufferSize = State(initialValue: deviceManager.bufferFrameSize)
        _selectedInputDeviceID = State(initialValue: deviceManager.selectedInputDeviceID)
        _selectedOutputDeviceID = State(initialValue: deviceManager.selectedOutputDeviceID)
        _selectedSampleRate = State(initialValue: audioEngine.hardwareSampleRate)
        _recordingCompensationText = State(
            initialValue: String(format: "%.1f", audioEngine.manualRecordingCompensationMs)
        )
        _clickTimingOffsetText = State(
            initialValue: String(format: "%.1f", audioEngine.metronomeTimingOffsetMs)
        )
    }

    private func commitRecordingCompensation() {
        guard let value = Double(recordingCompensationText) else {
            recordingCompensationText = String(format: "%.1f", audioEngine.manualRecordingCompensationMs)
            return
        }
        audioEngine.manualRecordingCompensationMs = value
        recordingCompensationText = String(format: "%.1f", audioEngine.manualRecordingCompensationMs)
    }

    private func commitClickTimingOffset() {
        guard let value = Double(clickTimingOffsetText) else {
            clickTimingOffsetText = String(format: "%.1f", audioEngine.metronomeTimingOffsetMs)
            return
        }
        audioEngine.metronomeTimingOffsetMs = value
        clickTimingOffsetText = String(format: "%.1f", audioEngine.metronomeTimingOffsetMs)
    }

    private func commitRollbackBars() {
        let range = ProjectState.recordRollbackBarsRange
        if let value = Int(rollbackBarsText.trimmingCharacters(in: .whitespaces)) {
            projectState.recordRollbackBars = min(range.upperBound, max(range.lowerBound, value))
        }
        rollbackBarsText = "\(projectState.recordRollbackBars)"
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.subheadline.weight(.bold))
    }

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Settings")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Environment")
                Picker("Language", selection: $selectedLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(verbatim: language.displayName).tag(language)
                    }
                }
                .pickerStyle(.menu)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Audio")
                HStack(spacing: 8) {
                    Text("Recordings folder")
                    Text(audioEngine.recordingsDirectory.path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Picker("Input device", selection: $selectedInputDeviceID) {
                    ForEach(deviceManager.inputDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .pickerStyle(.menu)

                Picker("Output device", selection: $selectedOutputDeviceID) {
                    ForEach(deviceManager.outputDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                .pickerStyle(.menu)

                Picker("Sample rate", selection: $selectedSampleRate) {
                    ForEach(sampleRates, id: \.self) { rate in
                        Text("\(Int(rate / 1000.0)) kHz").tag(rate)
                    }
                }
                .pickerStyle(.menu)

                Picker("Buffer size", selection: $selectedBufferSize) {
                    ForEach(bufferSizes, id: \.self) { size in
                        Text("\(size) frames (\(String(format: "%.1f", Double(size) / max(1.0, audioEngine.hardwareSampleRate) * 1000.0)) ms)")
                            .tag(size)
                    }
                }
                .pickerStyle(.menu)
                note("Input and output devices use the same Core Audio buffer size.")
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Compensation")
                HStack {
                    Text("Recording latency (optional)")
                    TextField("0", text: $recordingCompensationText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                        .onSubmit {
                            commitRecordingCompensation()
                        }
                    Text("ms")
                }
                note("Corrects the position of recorded clips. Positive values move them earlier.")

                HStack {
                    Text("Click timing")
                    TextField("0", text: $clickTimingOffsetText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                        .onSubmit {
                            commitClickTimingOffset()
                        }
                    Text("ms")
                }
                note("Corrects when the click sounds. Positive values make it sound later.")
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("Other")
                HStack {
                    Text("Click volume")
                    Slider(value: $audioEngine.metronomeVolume, in: 0.0...1.0)
                        .frame(width: 150)
                    Text("\(Int(audioEngine.metronomeVolume * 100.0))%")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                }

                HStack {
                    Text("Rollback when recording")
                    TextField("2", text: $rollbackBarsText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 48)
                        .onSubmit {
                            commitRollbackBars()
                        }
                    Text("bars")
                }
                note("In normal recording, the playhead rolls back by this many bars. Recording starts at the current playhead position.")
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Apply") {
                    commitRecordingCompensation()
                    commitClickTimingOffset()
                    commitRollbackBars()
                    let devicesChanged = selectedInputDeviceID != deviceManager.selectedInputDeviceID ||
                        selectedOutputDeviceID != deviceManager.selectedOutputDeviceID
                    let sampleRateChanged = abs(selectedSampleRate - audioEngine.hardwareSampleRate) > 0.5
                    let bufferChanged = selectedBufferSize != deviceManager.bufferFrameSize
                    var needsRestart = false
                    if selectedLanguage != AppLanguage.current {
                        AppLanguage.select(selectedLanguage)
                        needsRestart = true
                    }

                    if devicesChanged || sampleRateChanged {
                        let applied = audioEngine.applyAudioDevices(
                            inputDeviceID: selectedInputDeviceID,
                            outputDeviceID: selectedOutputDeviceID,
                            sampleRate: selectedSampleRate
                        )
                        if applied {
                            deviceManager.setSelectedDeviceIDs(
                                input: selectedInputDeviceID,
                                output: selectedOutputDeviceID
                            )
                            needsRestart = true
                        }
                    }
                    if bufferChanged,
                       deviceManager.setBufferFrameSize(selectedBufferSize) {
                        audioEngine.applyInputBufferFrameSize(selectedBufferSize)
                    }
                    dismiss()
                    if needsRestart {
                        onAudioDevicesChanged()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

