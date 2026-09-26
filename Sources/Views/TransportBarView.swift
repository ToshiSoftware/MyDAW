import SwiftUI
import CoreAudio

public struct TransportBarView: View {
    @ObservedObject public var audioEngine: AudioEngineManager
    @ObservedObject public var projectState: ProjectState
    @State private var showingBufferSettings = false
    @State private var bpmText = "120"
    @FocusState private var focusedField: FocusedField?

    private enum FocusedField {
        case bpm
    }

    public init(audioEngine: AudioEngineManager, projectState: ProjectState) {
        self.audioEngine = audioEngine
        self.projectState = projectState
    }

    private var timeString: String {
        let totalSeconds = audioEngine.currentTime
        let minutes = Int(totalSeconds) / 60
        let seconds = Int(totalSeconds) % 60
        let milliseconds = Int((totalSeconds.truncatingRemainder(dividingBy: 1.0)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", minutes / 60, minutes % 60, seconds, milliseconds)
    }

    private var barBeatString: String {
        let beatDuration = 60.0 / max(20.0, min(400.0, audioEngine.bpm))
        let totalBeats = max(0, Int(floor(audioEngine.currentTime / beatDuration)))
        return String(format: "%03d:%02d", totalBeats / 4 + 1, totalBeats % 4 + 1)
    }

    private var isTransportActive: Bool {
        audioEngine.isPlaying || audioEngine.isStartingPlayback
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
                .fastToolTip("Undo Clip Edit", horizontalOffset: 12)

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
                .fastToolTip("Redo Clip Edit")

                // Rewind (|<<)
                Button(action: {
                    audioEngine.rewind(tracks: projectState.tracks)
                    projectState.timelineScrollTime = 0.0
                }) {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 34, height: 28)
                        .background(Color.white.opacity(0.12))
                        .cornerRadius(5)
                }
                .buttonStyle(PlainButtonStyle())
                .fastToolTip("Rewind to Beginning (00:00.000)")

                Button(action: {
                    DispatchQueue.main.async {
                        let beatDuration = 60.0 / max(20.0, min(400.0, audioEngine.bpm))
                        audioEngine.setPunchRange(
                            startTime: projectState.punchRange.startBeat * beatDuration,
                            endTime: projectState.punchRange.endBeat * beatDuration,
                            enabled: projectState.punchRange.enabled
                        )
                        audioEngine.startPlayOrRecord(
                            tracks: projectState.tracks,
                            fxChannels: projectState.fxChannels,
                            recordArmedTracks: false
                        )
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
                .fastToolTip("Start / Pause (Spacebar)")

                // Record status indicator / start recording
                let anyArmed = projectState.tracks.contains { $0.isRecordArmed }
                Button(action: {
                    DispatchQueue.main.async {
                        let beatDuration = 60.0 / max(20.0, min(400.0, audioEngine.bpm))
                        audioEngine.setPunchRange(
                            startTime: projectState.punchRange.startBeat * beatDuration,
                            endTime: projectState.punchRange.endBeat * beatDuration,
                            enabled: projectState.punchRange.enabled
                        )
                        audioEngine.startPlayOrRecord(
                            tracks: projectState.tracks,
                            fxChannels: projectState.fxChannels,
                            recordArmedTracks: true
                        )
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
                .fastToolTip(anyArmed ? "Record Armed Tracks" : "No Tracks Armed for Recording")

                Button {
                    projectState.setPunchEnabled(!projectState.punchRange.enabled)
                } label: {
                    Text("P")
                        .font(.system(size: 11, weight: .black))
                        .foregroundColor(projectState.punchRange.enabled ? .black : .red.opacity(0.75))
                        .frame(width: 22, height: 20)
                        .background(projectState.punchRange.enabled ? Color.red : Color.white.opacity(0.08))
                        .cornerRadius(3)
                }
                .buttonStyle(PlainButtonStyle())
                .fastToolTip(projectState.punchRange.enabled ? "Disable Punch In/Out" : "Enable Punch In/Out")

                Button(action: {
                    projectState.deleteSelectedClip()
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.red.opacity(projectState.audioEngine.isRecording ? 0.35 : 0.9))
                        .frame(width: 34, height: 28)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(5)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(projectState.audioEngine.isRecording || !projectState.tracks.contains { $0.selectedClipId != nil })
                .fastToolTip("Delete Selected Recording")

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
                .fastToolTip("Save Project")

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
                .fastToolTip("Open Project")

                Toggle(isOn: $audioEngine.metronomeEnabled) {
                    Image(systemName: "metronome")
                        .font(.system(size: 13, weight: .bold))
                }
                .toggleStyle(.button)
                .tint(audioEngine.metronomeEnabled ? .orange : .white.opacity(0.35))
                .frame(width: 34, height: 28)
                .disabled(audioEngine.isPlaying || audioEngine.isRecording)
                .fastToolTip("Toggle Metronome Click")

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
                .fastToolTip("Audio Buffer Settings")

                Button(action: { projectState.snapToGrid.toggle() }) {
                    Image(systemName: projectState.snapToGrid ? "square.grid.3x3.fill" : "square.grid.3x3")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(projectState.snapToGrid ? .black : .white.opacity(0.75))
                        .frame(width: 34, height: 28)
                        .background(projectState.snapToGrid ? Color.orange : Color.white.opacity(0.08))
                        .cornerRadius(5)
                }
                .buttonStyle(PlainButtonStyle())
                .fastToolTip(projectState.snapToGrid ? "Disable Beat Snap" : "Enable Beat Snap")
            }

            // LCD Display: Time & Audio Format (Logic Pro Dark Glass Style)
            HStack(spacing: 16) {
                // Time counter
                VStack(alignment: .leading, spacing: 2) {
                    Text("TIME")
                        .font(.system(size: 8, weight: .black))
                        .foregroundColor(.white.opacity(0.4))
                    Text(projectState.showsBeats ? barBeatString : timeString)
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

                Divider()
                    .frame(height: 24)
                    .background(Color.white.opacity(0.15))

                // Direct to Disk Indicator
                VStack(alignment: .leading, spacing: 2) {
                    Text("STORAGE")
                        .font(.system(size: 8, weight: .black))
                        .foregroundColor(.white.opacity(0.4))
                    HStack(spacing: 4) {
                        Image(systemName: "internaldrive.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.green)
                        Text("Direct to Disk")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
            }
            .frame(width: 520, height: 38, alignment: .leading)
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
                Slider(
                    value: Binding(
                        get: { Double(projectState.pixelsPerSecond) },
                        set: { projectState.setPixelsPerSecond(CGFloat($0)) }
                    ),
                    in: 20.0...400.0
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
                Slider(value: $projectState.trackHeightScale, in: 0.5...3.0)
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
                        get: { Double(projectState.waveformVerticalScale) },
                        set: { projectState.waveformVerticalScale = CGFloat($0) }
                    ),
                    in: 1.0...32.0
                )
                .frame(width: 70)
                .accentColor(.orange)
                Text("×\(String(format: "%.1f", projectState.waveformVerticalScale))")
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

            // Master Volume
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.6))
                Slider(value: $audioEngine.masterVolume, in: 0.0...1.5)
                    .frame(width: 80)
                    .accentColor(.cyan)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(red: 0.16, green: 0.17, blue: 0.20))
        .overlay(
            Rectangle()
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .zIndex(2)
        .sheet(isPresented: $showingBufferSettings) {
            BufferSettingsView(
                deviceManager: projectState.deviceManager,
                audioEngine: audioEngine
            )
        }
    }
}

private extension View {
    func fastToolTip(_ text: String, horizontalOffset: CGFloat = 0) -> some View {
        modifier(FastToolTipModifier(text: text, horizontalOffset: horizontalOffset))
    }
}

private struct FastToolTipModifier: ViewModifier {
    let text: String
    let horizontalOffset: CGFloat
    @State private var isHovering = false
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        if isHovering {
                            isPresented = true
                        }
                    }
                } else {
                    isPresented = false
                }
            }
            .overlay(alignment: .top) {
                if isPresented {
                    Text(text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.94))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.white.opacity(0.2), lineWidth: 1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .fixedSize()
                        .offset(x: horizontalOffset, y: -34)
                        .zIndex(1)
                        .allowsHitTesting(false)
                }
            }
            .zIndex(isPresented ? 1 : 0)
    }
}

private struct BufferSettingsView: View {
    @ObservedObject var deviceManager: AudioDeviceManager
    @ObservedObject var audioEngine: AudioEngineManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedBufferSize: Int
    @State private var selectedInputDeviceID: AudioDeviceID
    @State private var selectedOutputDeviceID: AudioDeviceID
    @State private var selectedSampleRate: Double
    @State private var recordingCompensationText: String
    @State private var clickTimingOffsetText: String

    private let bufferSizes = [128, 256, 512, 1024, 2048, 4096]
    private let sampleRates = [44100.0, 48000.0, 88200.0, 96000.0]

    init(deviceManager: AudioDeviceManager, audioEngine: AudioEngineManager) {
        self.deviceManager = deviceManager
        self.audioEngine = audioEngine
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Audio Buffer Settings")
                .font(.headline)

            Text("Input and output devices use the same Core Audio buffer size.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("Recordings folder")
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    Text(audioEngine.recordingsDirectory.path)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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

            HStack {
                Text("Additional recording compensation")
                TextField("0", text: $recordingCompensationText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    .onSubmit {
                        commitRecordingCompensation()
                    }
                Text("ms")
            }

            Text("Enter the measured remaining offset. Positive values move new recordings earlier on the timeline.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Text("Click timing offset")
                TextField("0", text: $clickTimingOffsetText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 72)
                    .onSubmit {
                        commitClickTimingOffset()
                    }
                Text("ms")
            }

            Text("Positive values delay the click; negative values make it sound earlier. Range: -500 to +500 ms.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Text("Click volume")
                Slider(value: $audioEngine.metronomeVolume, in: 0.0...1.0)
                    .frame(width: 150)
                Text("\(Int(audioEngine.metronomeVolume * 100.0))%")
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }

            Picker("Buffer size", selection: $selectedBufferSize) {
                ForEach(bufferSizes, id: \.self) { size in
                    Text("\(size) frames (\(String(format: "%.1f", Double(size) / max(1.0, audioEngine.hardwareSampleRate) * 1000.0)) ms)")
                        .tag(size)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Apply") {
                    commitRecordingCompensation()
                    commitClickTimingOffset()
                    let devicesChanged = selectedInputDeviceID != deviceManager.selectedInputDeviceID ||
                        selectedOutputDeviceID != deviceManager.selectedOutputDeviceID
                    let sampleRateChanged = abs(selectedSampleRate - audioEngine.hardwareSampleRate) > 0.5
                    let bufferChanged = selectedBufferSize != deviceManager.bufferFrameSize

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
                        }
                    }
                    if bufferChanged,
                       deviceManager.setBufferFrameSize(selectedBufferSize) {
                        audioEngine.applyInputBufferFrameSize(selectedBufferSize)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}

