import Foundation
import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers
import AVFoundation

/// Clips being dragged. The clips themselves move in time as the pointer
/// moves; they change tracks only when the drag ends, so until then they are
/// hidden in their lanes and drawn as a block that follows the pointer.
public struct ClipDragPreview {
    /// Every clip moving with the drag (the whole selection).
    public let clipIDs: Set<UUID>
    /// Vertical pointer travel since the drag began.
    public var verticalOffset: CGFloat
    /// Tracks down (up when negative) the clips will land; 0 when some clip
    /// would have no track to land on, in which case none changes track.
    public var trackDelta: Int
}

@MainActor
public final class ProjectState: ObservableObject {
    private struct ClipSnapshot: Equatable {
        let id: UUID
        let startTime: Double
        let sourceStartTime: Double
        let duration: Double
        let originalDuration: Double
        let gainDB: Double
        let fadeInDuration: Double
        let fadeOutDuration: Double
        let fadeInCurve: FadeCurve
        let fadeOutCurve: FadeCurve
        let isMuted: Bool
        let fileURL: URL
    }

    private struct ClipEditSnapshot {
        let clipsByTrack: [UUID: [ClipSnapshot]]
        let selectedClipIDs: [UUID: Set<UUID>]
    }

    @Published public var tracks: [AudioTrack] = []
    @Published public var fxChannels: [FXChannel] = []
    @Published public var masterPlugins: [TrackPluginDescriptor] = []
    @Published public var selectedTrackId: UUID?
    @Published public var clipDragPreview: ClipDragPreview?
    /// Time range selected across one or more adjacent tracks. Exclusive with
    /// clip selection: making one clears the other.
    @Published public var timeSelection: TimeSelection?
    /// Clips copied or cut with Cmd+C / Cmd+X, ready to paste.
    @Published public internal(set) var clipboard: [ClipboardClip] = []
    var timeSelectionAnchor: (time: Double, trackIndex: Int)?
    /// Rubber-band rectangle (in the "timelineScroll" space) while dragging
    /// over empty lane space.
    @Published public internal(set) var marqueeRect: CGRect?
    var marqueeBaseSelection: [UUID: Set<UUID>] = [:]
    var groupDragStarts: [UUID: Double] = [:]
    @Published public var pixelsPerSecond: CGFloat = 80.0 // Horizontal zoom factor
    @Published public var timelineScrollTime: Double = 0.0
    @Published public var punchRange = PunchRangeDocument()
    @Published public var songRange = SongRangeDocument() {
        didSet { audioEngine.songEndTime = songEndTime }
    }
    @Published public private(set) var zoomRevision: Int = 0
    @Published public private(set) var scrollRestoreRevision: Int = 0
    @Published public var isRestoringScrollPosition: Bool = false
    @Published public var showsBeats: Bool = true
    @Published public var snapToGrid: Bool = UserDefaults.standard.object(forKey: "MyDAW.snapToGrid") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(snapToGrid, forKey: "MyDAW.snapToGrid")
        }
    }
    /// Whether the view follows the playhead while playing or recording.
    @Published public var autoScrollEnabled: Bool = UserDefaults.standard.object(forKey: "MyDAW.autoScroll") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(autoScrollEnabled, forKey: "MyDAW.autoScroll")
        }
    }
    @Published public var pluginManager: PluginManager
    @Published public private(set) var startupLog: [String] = [String(localized: "Starting MyDAW...")]
    @Published public private(set) var isShowingStartupLog = true
    @Published public var isShowingMasterExportDialog = false
    @Published public var isExportingMasterMix = false
    @Published public var masterExportCompleted = false
    @Published public var masterExportError: String?
    @Published public private(set) var saveConfirmationMessage: String?
    @Published public private(set) var isProjectOpen = false
    public var masterExportURL: URL?
    /// The master export's file name as last chosen; saved with the project.
    public var masterExportFileName: String?
    private var masterExportTask: Task<Void, Never>?
    private var saveConfirmationTask: Task<Void, Never>?
    @Published public private(set) var canUndo = false
    @Published public private(set) var canRedo = false
    @Published public var waveformVerticalScale: CGFloat = 1.0 {
        didSet {
            let clamped = min(32.0, max(1.0, waveformVerticalScale))
            if clamped != waveformVerticalScale {
                waveformVerticalScale = clamped
            }
        }
    }
    @Published public var trackHeightScale: CGFloat = 1.0 {
        didSet {
            let clamped = min(3.0, max(0.5, trackHeightScale))
            if clamped != trackHeightScale {
                trackHeightScale = clamped
            }
        }
    }

    public var currentProjectURL: URL?
    public private(set) var projectFolderURL: URL?

    public var audioContentEndTime: Double {
        tracks
            .flatMap { $0.clips }
            .map { $0.startTime + $0.duration }
            .max() ?? 0.0
    }

    public func setPunchRange(startBeat: Double, endBeat: Double) {
        let lower = max(0.0, min(startBeat, endBeat))
        let upper = max(lower + 1.0, max(startBeat, endBeat))
        punchRange = PunchRangeDocument(
            startBeat: lower,
            endBeat: upper,
            enabled: punchRange.enabled
        )
    }

    public func setPunchStartBeat(_ startBeat: Double) {
        setPunchRange(startBeat: startBeat, endBeat: punchRange.endBeat)
    }

    public func setPunchEndBeat(_ endBeat: Double) {
        setPunchRange(startBeat: punchRange.startBeat, endBeat: endBeat)
    }

    public func setPunchEnabled(_ enabled: Bool) {
        punchRange = PunchRangeDocument(
            startBeat: punchRange.startBeat,
            endBeat: punchRange.endBeat,
            enabled: enabled
        )
        let beatDuration = 60.0 / max(20.0, min(400.0, audioEngine.bpm))
        audioEngine.setPunchRange(
            startTime: punchRange.startBeat * beatDuration,
            endTime: punchRange.endBeat * beatDuration,
            enabled: enabled
        )
    }

    // MARK: Song start / end flags

    /// Smallest distance kept between the start and end flags, in beats.
    public static let minimumSongLengthBeats = 1.0

    private var currentBeatDuration: Double {
        60.0 / max(20.0, min(400.0, audioEngine.bpm))
    }

    public var songStartTime: Double? {
        songRange.startBeat.map { $0 * currentBeatDuration }
    }

    public var songEndTime: Double? {
        songRange.endBeat.map { $0 * currentBeatDuration }
    }

    /// Whether a start flag may go at `time` (it must stay before the end flag).
    public func canPlaceSongStart(at time: Double) -> Bool {
        guard let endBeat = songRange.endBeat else { return true }
        return time / currentBeatDuration <= endBeat - Self.minimumSongLengthBeats
    }

    /// Whether an end flag may go at `time` (it must stay after the start flag).
    public func canPlaceSongEnd(at time: Double) -> Bool {
        let startBeat = songRange.startBeat ?? 0.0
        return time / currentBeatDuration >= startBeat + Self.minimumSongLengthBeats
    }

    /// Places (or with nil removes) the start flag, kept before the end flag.
    public func setSongStart(time: Double?) {
        let beat = time.map { t -> Double in
            let requested = max(0.0, t / currentBeatDuration)
            guard let endBeat = songRange.endBeat else { return requested }
            return max(0.0, min(requested, endBeat - Self.minimumSongLengthBeats))
        }
        songRange = SongRangeDocument(startBeat: beat, endBeat: songRange.endBeat)
    }

    /// Places (or with nil removes) the end flag, kept after the start flag.
    public func setSongEnd(time: Double?) {
        let beat = time.map { t -> Double in
            let lowest = (songRange.startBeat ?? 0.0) + Self.minimumSongLengthBeats
            return max(lowest, t / currentBeatDuration)
        }
        songRange = SongRangeDocument(startBeat: songRange.startBeat, endBeat: beat)
    }

    /// Starts (or pauses) playback, or recording on armed tracks, with the
    /// punch range and song end in seconds at the current tempo.
    public func toggleTransport(recordArmedTracks: Bool) {
        let beatDuration = currentBeatDuration
        audioEngine.setPunchRange(
            startTime: punchRange.startBeat * beatDuration,
            endTime: punchRange.endBeat * beatDuration,
            enabled: punchRange.enabled
        )
        audioEngine.songEndTime = songEndTime
        audioEngine.startPlayOrRecord(
            tracks: tracks,
            fxChannels: fxChannels,
            recordArmedTracks: recordArmedTracks
        )
    }

    /// Returns to the start flag, or to 0 when already on the flag, before
    /// it, or when there is none.
    public func rewindToSongStart() {
        let target: Double
        if let start = songStartTime, audioEngine.currentTime > start + 0.001 {
            target = start
        } else {
            target = 0.0
        }
        audioEngine.rewind(tracks: tracks, to: target)
        // Keep the flag a little in from the left edge.
        timelineScrollTime = max(0.0, target - Double(40.0 / max(0.001, pixelsPerSecond)))
    }

    public let audioEngine: AudioEngineManager
    public let deviceManager: AudioDeviceManager

    private let defaultColors: [Color] = [
        Color(red: 0.20, green: 0.60, blue: 1.00), // Azure
        Color(red: 0.25, green: 0.85, blue: 0.60), // Emerald
        Color(red: 1.00, green: 0.65, blue: 0.15), // Amber
        Color(red: 0.90, green: 0.35, blue: 0.45), // Coral
        Color(red: 0.70, green: 0.45, blue: 0.95), // Purple
        Color(red: 0.35, green: 0.80, blue: 0.95), // Cyan
    ]
    private var undoStack: [ClipEditSnapshot] = []
    private var redoStack: [ClipEditSnapshot] = []
    private var activeClipEditSnapshot: ClipEditSnapshot?
    private var transportStateObservation: AnyCancellable?

    public init(audioEngine: AudioEngineManager? = nil, deviceManager: AudioDeviceManager? = nil, pluginManager: PluginManager? = nil) {
        let deviceManager = deviceManager ?? AudioDeviceManager()
        self.deviceManager = deviceManager
        // The engine must be bound to its devices before it first starts.
        self.audioEngine = audioEngine ?? AudioEngineManager(
            inputDeviceID: deviceManager.selectedInputDeviceID,
            outputDeviceID: deviceManager.selectedOutputDeviceID
        )
        self.pluginManager = pluginManager ?? PluginManager()

        if self.audioEngine.applyAudioDevices(
            inputDeviceID: self.deviceManager.selectedInputDeviceID,
            outputDeviceID: self.deviceManager.selectedOutputDeviceID
        ) {
            self.deviceManager.persistSelectedDevices()
        }

        if audioEngine == nil {
            self.audioEngine.applyInputBufferFrameSize(self.deviceManager.bufferFrameSize)
        }

        setupPeakObserver()
        // Menu items enabled by transport state observe this object only, so
        // a stop that nothing else reports (the song end flag) must reach them.
        transportStateObservation = Publishers.CombineLatest3(
            self.audioEngine.$isPlaying.removeDuplicates(),
            self.audioEngine.$isRecording.removeDuplicates(),
            self.audioEngine.$hasPendingRecording.removeDuplicates()
        )
        .dropFirst()
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.objectWillChange.send() }
        self.audioEngine.onReachSongEnd = { [weak self] in
            guard let self else { return }
            self.audioEngine.stop(tracks: self.tracks)
        }

        // Add 2 initial tracks as default template
        addTrack(name: "Audio 1", mode: .stereo, isArmed: true)
        addTrack(name: "Audio 2", mode: .stereo, isArmed: false)
        startPluginDiscovery()
    }

    private func startPluginDiscovery() {
        pluginManager.discoverAvailablePlugins(
            onLog: { [weak self] message in
                self?.startupLog.append(message)
            },
            completion: { [weak self] in
                self?.isShowingStartupLog = false
                DispatchQueue.main.async {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first(where: { $0.title.contains("MyDAW") })?
                        .makeKeyAndOrderFront(nil)
                }
            }
        )
    }

    private func makeClipEditSnapshot() -> ClipEditSnapshot {
        ClipEditSnapshot(
            clipsByTrack: tracks.reduce(into: [:]) { result, track in
                result[track.id] = track.clips.map { clip in
                    ClipSnapshot(
                        id: clip.id,
                        startTime: clip.startTime,
                        sourceStartTime: clip.sourceStartTime,
                        duration: clip.duration,
                        originalDuration: clip.originalDuration,
                        gainDB: clip.gainDB,
                        fadeInDuration: clip.fadeInDuration,
                        fadeOutDuration: clip.fadeOutDuration,
                        fadeInCurve: clip.fadeInCurve,
                        fadeOutCurve: clip.fadeOutCurve,
                        isMuted: clip.isMuted,
                        fileURL: clip.fileURL
                    )
                }
            },
            selectedClipIDs: tracks.reduce(into: [:]) { result, track in
                result[track.id] = track.selectedClipIDs
            }
        )
    }

    public func beginClipEdit() {
        guard activeClipEditSnapshot == nil else { return }
        activeClipEditSnapshot = makeClipEditSnapshot()
    }

    public func endClipEdit() {
        guard let snapshot = activeClipEditSnapshot else { return }
        activeClipEditSnapshot = nil
        // A press on a handle without moving it leaves the clips unchanged;
        // don't push an undo step for it.
        guard snapshot.clipsByTrack != makeClipEditSnapshot().clipsByTrack else { return }
        undoStack.append(snapshot)
        redoStack.removeAll()
        updateHistoryAvailability()
    }

    private func recordClipEdit() {
        undoStack.append(makeClipEditSnapshot())
        redoStack.removeAll()
        updateHistoryAvailability()
    }

    private func updateHistoryAvailability() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func restoreClipEditSnapshot(_ snapshot: ClipEditSnapshot) {
        for track in tracks {
            let restoredClips = (snapshot.clipsByTrack[track.id] ?? []).map { item in
                let clip = AudioClip(id: item.id, startTime: item.startTime, fileURL: item.fileURL)
                clip.loadMetadata()
                clip.setTrim(
                    startTime: item.startTime,
                    sourceStartTime: item.sourceStartTime,
                    duration: item.duration
                )
                clip.setGainDB(item.gainDB)
                clip.setFadeInDuration(item.fadeInDuration)
                clip.setFadeOutDuration(item.fadeOutDuration)
                clip.fadeInCurve = item.fadeInCurve
                clip.fadeOutCurve = item.fadeOutCurve
                clip.isMuted = item.isMuted
                return clip
            }
            track.replaceClips(restoredClips)
            track.selectedClipIDs = snapshot.selectedClipIDs[track.id] ?? []
        }
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    public func undo() {
        guard !audioEngine.isPlaying && !audioEngine.isRecording,
              let snapshot = undoStack.popLast() else { return }
        redoStack.append(makeClipEditSnapshot())
        restoreClipEditSnapshot(snapshot)
        updateHistoryAvailability()
    }

    public func redo() {
        guard !audioEngine.isPlaying && !audioEngine.isRecording,
              let snapshot = redoStack.popLast() else { return }
        undoStack.append(makeClipEditSnapshot())
        restoreClipEditSnapshot(snapshot)
        updateHistoryAvailability()
    }

    private func setupPeakObserver() {
        MyDAWNotificationCenter.shared.addObserver(
            forName: .audioEngineUpdatedPeaks,
            object: nil,
            queue: nil
        ) { [weak self] notif in
            Task { @MainActor [weak self] in
                guard let self = self,
                      let userInfo = notif.userInfo,
                      let peaks = userInfo["peaks"] as? [Float] else { return }

                let liveChannelWaveforms = userInfo["liveChannelWaveforms"] as? [UUID: [[(min: Float, max: Float)]]] ?? [:]
                let outputPeaks = userInfo["outputPeaks"] as? [UUID: StereoPeak] ?? [:]
                let fxOutputPeaks = userInfo["fxOutputPeaks"] as? [UUID: StereoPeak] ?? [:]
                for channel in self.fxChannels {
                    let peak = fxOutputPeaks[channel.id] ?? .zero
                    channel.outputStereoPeak = channel.outputStereoPeak.falling(to: peak, by: 0.82)
                    channel.currentOutputPeak = channel.outputStereoPeak.maximum
                }

                // Update track input peak meters
                for track in self.tracks {
                    if track.isRecordArmed {
                        let ch0 = track.inputChannelIndex
                        let ch1 = ch0 + 1
                        var rawPeak: Float = 0.0
                        if ch0 < peaks.count {
                            rawPeak = peaks[ch0]
                        }
                        if track.channelMode == .stereo && ch1 < peaks.count {
                            rawPeak = max(rawPeak, peaks[ch1])
                        }
                        // Fast attack, smooth decay
                        track.currentInputPeak = max(rawPeak, track.currentInputPeak * 0.85)
                    } else {
                        track.currentInputPeak = max(0.0, track.currentInputPeak * 0.70)
                    }
                    let outputPeak = outputPeaks[track.id] ?? .zero
                    track.outputStereoPeak = track.outputStereoPeak.falling(to: outputPeak, by: 0.82)
                    track.currentOutputPeak = track.outputStereoPeak.maximum

                    // Append live waveform points if recording
                    if let channelPoints = liveChannelWaveforms[track.id], !channelPoints.isEmpty {
                        track.appendLiveChannelPeaks(channelPoints)
                    }
                }
            }
        }
    }

    public func addTrack(name: String? = nil, mode: ChannelMode = .stereo, isArmed: Bool = false) {
        let index = tracks.count + 1
        let trackName = name ?? "Audio \(index)"
        let color = defaultColors[(index - 1) % defaultColors.count]

        let newTrack = AudioTrack(
            name: trackName,
            channelMode: mode,
            inputChannelIndex: 0,
            isRecordArmed: isArmed,
            color: color
        )
        tracks.append(newTrack)
        selectedTrackId = newTrack.id
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    public func importAudioFile(_ url: URL, intoTrackId trackId: UUID) {
        guard !audioEngine.isPlaying && !audioEngine.isRecording,
              let track = tracks.first(where: { $0.id == trackId }) else { return }

        do {
            // Files at another sample rate or bit depth are converted to a
            // 24-bit WAV at the current rate as they are copied in.
            let targetSampleRate = audioEngine.hardwareSampleRate
            let managedURL = try ClipAudioProcessing.is24BitPCM(url, sampleRate: targetSampleRate)
                ? managedRecordingURL(for: url)
                : convertedRecordingURL(for: url, sampleRate: targetSampleRate)
            let clip = track.addClip(startTime: audioEngine.currentTime, fileURL: managedURL)
            clip.loadMetadata()
            selectClip(trackId: trackId, clipId: clip.id)
            audioEngine.syncTracks(tracks, fxChannels: fxChannels)
        } catch {
            presentProjectError(String(localized: "Could not read the WAV file.\n\n\(error.localizedDescription)"))
        }
    }

    public func locateClipFile(trackId: UUID, clipId: UUID) {
        guard !audioEngine.isPlaying && !audioEngine.isRecording,
              let track = tracks.first(where: { $0.id == trackId }),
              let clip = track.clips.first(where: { $0.id == clipId }) else { return }

        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Recording File")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.wav]
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }

        do {
            let file = try AVAudioFile(forReading: sourceURL)
            let sampleRate = file.fileFormat.sampleRate
            let expectedSampleRate = audioEngine.hardwareSampleRate
            guard abs(sampleRate - expectedSampleRate) <= 0.5 else {
                presentProjectError(String(localized: "This recording file cannot be used.\n\nSample rate: \(Int(sampleRate)) Hz (required: \(Int(expectedSampleRate)) Hz)"))
                return
            }

            let managedURL = try managedRecordingURL(for: sourceURL)
            let originalFileName = clip.fileURL.lastPathComponent
            for candidateTrack in tracks {
                for candidateClip in candidateTrack.clips
                    where candidateClip.fileURL.lastPathComponent == originalFileName {
                    candidateClip.replaceFile(with: managedURL)
                }
            }
            audioEngine.syncTracks(tracks, fxChannels: fxChannels)
        } catch {
            presentProjectError(String(localized: "Could not read the recording file.\n\n\(error.localizedDescription)"))
        }
    }

    public func beginMasterExportDialog() {
        guard !audioEngine.isPlaying && !audioEngine.isRecording else { return }
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Master Mix")
        panel.nameFieldStringValue = masterExportFileName ?? defaultMasterExportFileName
        panel.directoryURL = projectFolderURL ?? audioEngine.recordingsDirectory.deletingLastPathComponent()
        panel.allowedContentTypes = [.wav]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        masterExportURL = url
        masterExportFileName = url.lastPathComponent
        masterExportCompleted = false
        masterExportError = nil
        isShowingMasterExportDialog = true
    }

    /// "<project name>_Master_Mix.wav".
    private var defaultMasterExportFileName: String {
        let projectName = currentProjectURL?.deletingPathExtension().lastPathComponent
            ?? projectFolderURL?.lastPathComponent
            ?? "MyDAW"
        return "\(projectName)_Master_Mix.wav"
    }

    public func exportMasterMix(startTime: Double, endTime: Double) {
        guard !isExportingMasterMix, let url = masterExportURL else { return }
        isExportingMasterMix = true
        masterExportCompleted = false
        masterExportError = nil

        masterExportTask = Task { @MainActor in
            do {
                try await audioEngine.exportMasterMix(
                    to: url,
                    startTime: startTime,
                    endTime: endTime,
                    tracks: tracks,
                    fxChannels: fxChannels
                )
                isExportingMasterMix = false
                masterExportCompleted = true
            } catch {
                isExportingMasterMix = false
                if !Task.isCancelled {
                    masterExportError = error.localizedDescription
                }
            }
            masterExportTask = nil
        }
    }

    public func cancelMasterExport() {
        guard isExportingMasterMix else { return }
        masterExportTask?.cancel()
        isShowingMasterExportDialog = false
    }

    private func managedRecordingURL(for sourceURL: URL) throws -> URL {
        let recordingsURL = audioEngine.recordingsDirectory.standardizedFileURL
        let sourceStandardizedURL = sourceURL.standardizedFileURL
        let recordingsPath = recordingsURL.path.hasSuffix("/")
            ? recordingsURL.path
            : recordingsURL.path + "/"

        if sourceStandardizedURL.path.hasPrefix(recordingsPath) {
            return sourceStandardizedURL
        }

        try FileManager.default.createDirectory(
            at: recordingsURL,
            withIntermediateDirectories: true
        )

        let destinationURL = importDestinationURL(for: sourceURL, in: recordingsURL)
        try FileManager.default.copyItem(at: sourceStandardizedURL, to: destinationURL)
        return destinationURL
    }

    /// Writes a 24-bit WAV copy of `sourceURL` at `sampleRate` into the
    /// recordings folder and returns its URL.
    private func convertedRecordingURL(for sourceURL: URL, sampleRate: Double) throws -> URL {
        let recordingsURL = audioEngine.recordingsDirectory.standardizedFileURL
        try FileManager.default.createDirectory(at: recordingsURL, withIntermediateDirectories: true)
        let destinationURL = importDestinationURL(for: sourceURL, in: recordingsURL)
        do {
            try ClipAudioProcessing.writeConverted(from: sourceURL, to: destinationURL, sampleRate: sampleRate)
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
        return destinationURL
    }

    /// "Import_001.wav", "Import_002.wav", …
    private func importDestinationURL(for sourceURL: URL, in recordingsURL: URL) -> URL {
        RecordingFileName.nextURL(in: recordingsURL, stem: "Import")
    }

    public func insertPlugin(_ descriptor: TrackPluginDescriptor, into trackID: UUID) {
        guard !audioEngine.isPlaying && !audioEngine.isRecording else { return }
        guard let track = tracks.first(where: { $0.id == trackID }) else { return }
        track.insertPlugin(descriptor.newInstance())
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    public func removePlugin(_ pluginID: UUID, from trackID: UUID) {
        guard !audioEngine.isPlaying && !audioEngine.isRecording else { return }
        guard let track = tracks.first(where: { $0.id == trackID }) else { return }
        track.removePlugin(id: pluginID)
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    public func movePlugin(_ pluginID: UUID, before targetPluginID: UUID, on trackID: UUID) {
        guard !audioEngine.isPlaying && !audioEngine.isRecording,
              let track = tracks.first(where: { $0.id == trackID }) else { return }
        track.movePlugin(id: pluginID, before: targetPluginID)
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    public func togglePlugin(_ pluginID: UUID, on trackID: UUID) {
        guard let track = tracks.first(where: { $0.id == trackID }),
              let index = track.plugins.firstIndex(where: { $0.id == pluginID }) else { return }
        track.plugins[index].enabled.toggle()
        audioEngine.setPluginEnabled(pluginID, enabled: track.plugins[index].enabled)
    }

    public func addFXChannel() {
        let channel = FXChannel(name: "FX \(fxChannels.count + 1)")
        fxChannels.append(channel)
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    public func renameFXChannel(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let channel = fxChannels.first(where: { $0.id == id }) else { return }
        channel.name = trimmed
        // Send rows in track strips show FX names but observe only the project.
        objectWillChange.send()
    }

    public func removeFXChannel(id: UUID) {
        fxChannels.removeAll { $0.id == id }
        for track in tracks {
            track.fxSends.removeAll { $0.fxChannelID == id }
        }
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    public func setSend(trackID: UUID, fxChannelID: UUID, level: Float) {
        guard let track = tracks.first(where: { $0.id == trackID }) else { return }
        if let index = track.fxSends.firstIndex(where: { $0.fxChannelID == fxChannelID }) {
            track.fxSends[index].level = level
            track.fxSends[index].enabled = level > 0
        } else if level > 0 {
            track.fxSends.append(FXSend(fxChannelID: fxChannelID, level: level))
        }
        if audioEngine.isPlaying || audioEngine.isRecording,
           let send = track.fxSends.first(where: { $0.fxChannelID == fxChannelID }),
           let fxChannel = fxChannels.first(where: { $0.id == fxChannelID }) {
            audioEngine.updateSendLevel(track: track, send: send, fxChannel: fxChannel)
            // Whether a send is on decides which tracks an FX solo keeps.
            if tracks.contains(where: \.isSoloed) || fxChannels.contains(where: \.isSoloed) {
                audioEngine.updateMixerLevels(tracks: tracks, fxChannels: fxChannels)
            }
        } else {
            audioEngine.syncTracks(tracks, fxChannels: fxChannels)
        }
    }

    public func insertPlugin(_ descriptor: TrackPluginDescriptor, intoFX fxChannelID: UUID) {
        guard !audioEngine.isPlaying && !audioEngine.isRecording else { return }
        guard let channel = fxChannels.first(where: { $0.id == fxChannelID }) else { return }
        channel.insertPlugin(descriptor.newInstance())
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    public func removePlugin(_ pluginID: UUID, fromFX fxChannelID: UUID) {
        guard !audioEngine.isPlaying && !audioEngine.isRecording else { return }
        guard let channel = fxChannels.first(where: { $0.id == fxChannelID }) else { return }
        channel.removePlugin(id: pluginID)
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    public func movePlugin(_ pluginID: UUID, before targetPluginID: UUID, onFX fxChannelID: UUID) {
        guard !audioEngine.isPlaying && !audioEngine.isRecording,
              let channel = fxChannels.first(where: { $0.id == fxChannelID }) else { return }
        channel.movePlugin(id: pluginID, before: targetPluginID)
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    public func togglePlugin(_ pluginID: UUID, onFX fxChannelID: UUID) {
        guard let channel = fxChannels.first(where: { $0.id == fxChannelID }),
              let index = channel.plugins.firstIndex(where: { $0.id == pluginID }) else { return }
        channel.plugins[index].enabled.toggle()
        audioEngine.setPluginEnabled(pluginID, enabled: channel.plugins[index].enabled)
    }

    public func insertMasterPlugin(_ descriptor: TrackPluginDescriptor) {
        guard !audioEngine.isPlaying && !audioEngine.isRecording else { return }
        masterPlugins.append(descriptor.newInstance())
        audioEngine.syncTracks(tracks, fxChannels: fxChannels, masterPlugins: masterPlugins)
    }

    public func removeMasterPlugin(_ pluginID: UUID) {
        guard !audioEngine.isPlaying && !audioEngine.isRecording else { return }
        masterPlugins.removeAll { $0.id == pluginID }
        audioEngine.syncTracks(tracks, fxChannels: fxChannels, masterPlugins: masterPlugins)
    }

    public func moveMasterPlugin(_ pluginID: UUID, before targetPluginID: UUID) {
        guard !audioEngine.isPlaying && !audioEngine.isRecording,
              pluginID != targetPluginID,
              let sourceIndex = masterPlugins.firstIndex(where: { $0.id == pluginID }),
              let targetIndex = masterPlugins.firstIndex(where: { $0.id == targetPluginID }) else { return }
        let plugin = masterPlugins.remove(at: sourceIndex)
        let adjustedTargetIndex = targetIndex > sourceIndex ? targetIndex - 1 : targetIndex
        masterPlugins.insert(plugin, at: adjustedTargetIndex)
        audioEngine.syncTracks(tracks, fxChannels: fxChannels, masterPlugins: masterPlugins)
    }

    public func toggleMasterPlugin(_ pluginID: UUID) {
        guard let index = masterPlugins.firstIndex(where: { $0.id == pluginID }) else { return }
        masterPlugins[index].enabled.toggle()
        audioEngine.setPluginEnabled(pluginID, enabled: masterPlugins[index].enabled)
    }

    public func openPluginUI(_ pluginID: UUID, on trackID: UUID) {
        guard tracks.first(where: { $0.id == trackID })?.plugins.contains(where: { $0.id == pluginID }) == true else {
            return
        }
        audioEngine.openPluginUI(pluginID: pluginID)
    }

    public func deleteTrack(id: UUID) {
        tracks.removeAll { $0.id == id }
        if selectedTrackId == id {
            selectedTrackId = tracks.first?.id
        }
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    /// Moves a track to `index` in the track order, which the arranger and the
    /// mixer both follow. The audio graph is keyed by track, not by position,
    /// so nothing needs to be rewired.
    public func moveTrack(id: UUID, to index: Int) {
        guard let from = tracks.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(0, index), tracks.count - 1)
        guard from != to else { return }
        let track = tracks.remove(at: from)
        tracks.insert(track, at: to)
        // A time selection spans adjacent tracks, which these may no longer be.
        timeSelection = nil
    }

    /// Asks before deleting, since removing a track cannot be undone.
    public func confirmDeleteTrack(id: UUID) {
        guard let track = tracks.first(where: { $0.id == id }),
              confirmDeletion(
                  name: track.name,
                  detail: String(localized: "The track's clips, plug-ins and sends will be removed. This cannot be undone.")
              ) else { return }
        deleteTrack(id: id)
    }

    /// Asks before removing, since removing an FX channel cannot be undone.
    public func confirmRemoveFXChannel(id: UUID) {
        guard let channel = fxChannels.first(where: { $0.id == id }),
              confirmDeletion(
                  name: channel.name,
                  detail: String(localized: "The FX channel's plug-ins and every track's send to it will be removed. This cannot be undone.")
              ) else { return }
        removeFXChannel(id: id)
    }

    /// Return and Escape both cancel, so a stray key press never deletes.
    private func confirmDeletion(name: String, detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete “\(name)”?")
        alert.informativeText = detail
        alert.alertStyle = .warning
        let deleteButton = alert.addButton(withTitle: String(localized: "Delete"))
        deleteButton.hasDestructiveAction = true
        deleteButton.keyEquivalent = ""
        let cancelButton = alert.addButton(withTitle: String(localized: "Cancel"))
        cancelButton.keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }

    public func toggleRecordArm(for track: AudioTrack) {
        track.isRecordArmed.toggle()
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    /// Changing a track's channel mode leaves its files untouched: a mono
    /// track downmixes stereo clips as it plays, and a stereo track plays mono
    /// clips on both sides. Not on an armed track while recording, since the
    /// mode also sets how many input channels the recording captures.
    public func setInputRouting(for track: AudioTrack, channelMode: ChannelMode? = nil, inputChannelIndex: Int? = nil) {
        if let channelMode, !(audioEngine.isRecording && track.isRecordArmed) {
            track.channelMode = channelMode
            // Stereo pairs start on even channels (1-2, 3-4, …); an odd mono
            // input would otherwise pair with the next channel, which may not
            // exist. Mono keeps the pair's first channel.
            if channelMode == .stereo {
                let pairStart = track.inputChannelIndex - track.inputChannelIndex % 2
                let options = deviceManager.channels(for: .stereo)
                track.inputChannelIndex = options.contains { $0.channelOffset == pairStart }
                    ? pairStart
                    : (options.first?.channelOffset ?? 0)
            }
        }
        if let inputChannelIndex {
            track.inputChannelIndex = inputChannelIndex
        }
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    public func toggleInputMonitoring(for track: AudioTrack) {
        track.isInputMonitoring.toggle()
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    public func toggleMute(for track: AudioTrack) {
        track.isMuted.toggle()
        updateMixerLevelsAfterTrackControlChange()
    }

    public func toggleSolo(for track: AudioTrack) {
        track.isSoloed.toggle()
        updateMixerLevelsAfterTrackControlChange()
    }

    public func toggleMute(for channel: FXChannel) {
        channel.isMuted.toggle()
        updateMixerLevelsAfterTrackControlChange()
    }

    public func toggleSolo(for channel: FXChannel) {
        channel.isSoloed.toggle()
        updateMixerLevelsAfterTrackControlChange()
    }

    private func updateMixerLevelsAfterTrackControlChange() {
        if audioEngine.isPlaying || audioEngine.isRecording {
            audioEngine.updateMixerLevels(tracks: tracks, fxChannels: fxChannels)
        } else {
            audioEngine.syncTracks(tracks, fxChannels: fxChannels)
        }
    }

    public func selectClip(trackId: UUID, clipId: UUID) {
        for track in tracks {
            track.selectedClipId = track.id == trackId ? clipId : nil
        }
        timeSelection = nil
        selectedTrackId = trackId
    }

    /// Starts the drag preview for the clips of the current group drag.
    public func beginClipDragPreview() {
        clipDragPreview = ClipDragPreview(
            clipIDs: Set(groupDragStarts.keys),
            verticalOffset: 0,
            trackDelta: 0
        )
    }

    public func updateClipDragPreview(verticalOffset: CGFloat, trackDelta: Int) {
        guard var preview = clipDragPreview else { return }
        preview.verticalOffset = verticalOffset
        preview.trackDelta = canMoveSelectedClips(trackDelta: trackDelta) ? trackDelta : 0
        clipDragPreview = preview
    }

    public func endClipDragPreview() {
        clipDragPreview = nil
    }

    @discardableResult
    public func moveClip(
        clipId: UUID,
        from sourceTrackId: UUID,
        to destinationTrackId: UUID,
        startTime: Double
    ) -> Bool {
        guard sourceTrackId != destinationTrackId,
              let sourceTrack = tracks.first(where: { $0.id == sourceTrackId }),
              let destinationTrack = tracks.first(where: { $0.id == destinationTrackId }),
              let clip = sourceTrack.removeClipForTransfer(id: clipId) else {
            return false
        }

        clip.startTime = max(0.0, startTime)
        destinationTrack.restoreClip(clip)
        selectClip(trackId: destinationTrackId, clipId: clipId)
        return true
    }

    /// Deletes the selected time range, or else every selected clip.
    public func deleteSelectedClip() {
        guard !audioEngine.isRecording else { return }
        if timeSelection != nil {
            deleteTimeSelection()
        } else {
            deleteSelectedClips()
        }
    }

    public func splitSelectedClip() {
        guard !audioEngine.isPlaying && !audioEngine.isRecording,
              let track = tracks.first(where: { $0.selectedClipId != nil }),
              let clipId = track.selectedClipId else { return }
        splitClip(trackId: track.id, clipId: clipId)
    }

    public func splitClip(trackId: UUID, clipId: UUID) {
        guard !audioEngine.isPlaying && !audioEngine.isRecording,
              let track = tracks.first(where: { $0.id == trackId }) else { return }
        let beforeEdit = makeClipEditSnapshot()
        track.selectedClipId = clipId
        if track.splitClip(id: clipId, at: audioEngine.currentTime) {
            undoStack.append(beforeEdit)
            redoStack.removeAll()
            updateHistoryAvailability()
            audioEngine.syncTracks(tracks, fxChannels: fxChannels)
        }
    }

    @discardableResult
    public func saveProject() -> Bool {
        guard !audioEngine.isPlaying && !audioEngine.isRecording else { return false }
        guard let projectURL = currentProjectURL,
              let projectFolderURL else {
            return createNewProject()
        }

        let recordingsURL = projectFolderURL.appendingPathComponent("Recordings", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: recordingsURL, withIntermediateDirectories: true)
            audioEngine.recordingsDirectory = recordingsURL.standardizedFileURL
        } catch {
            presentProjectError(String(localized: "Could not prepare project folder: \(error.localizedDescription)"))
            return false
        }

        let document = ProjectDocument(
            pixelsPerSecond: Double(pixelsPerSecond),
            selectedTrackId: selectedTrackId,
            currentTime: audioEngine.currentTime,
            timelineScrollTime: timelineScrollTime,
            showsBeats: showsBeats,
            bpm: audioEngine.bpm,
            metronomeEnabled: audioEngine.metronomeEnabled,
            metronomeTimingOffsetMs: audioEngine.metronomeTimingOffsetMs,
            metronomeVolume: audioEngine.metronomeVolume,
            masterVolume: audioEngine.masterVolume,
            manualRecordingCompensationMs: audioEngine.manualRecordingCompensationMs,
            waveformVerticalScale: Double(waveformVerticalScale),
            trackHeightScale: Double(trackHeightScale),
            tracks: tracks.map { track in
                TrackDocument(
                    id: track.id,
                    name: track.name,
                    channelMode: track.channelMode,
                    inputChannelIndex: track.inputChannelIndex,
                    isRecordArmed: track.isRecordArmed,
                    isMuted: track.isMuted,
                    isSoloed: track.isSoloed,
                    isInputMonitoring: track.isInputMonitoring,
                    volume: track.volume,
                    pan: track.pan,
                    trackHeight: Double(track.trackHeight),
                    color: ColorDocument(color: track.color),
                    selectedClipId: track.selectedClipId,
                    clips: track.clips.map { clip in
                        ClipDocument(
                            id: clip.id,
                            startTime: clip.startTime,
                            sourceStartTime: clip.sourceStartTime,
                            duration: clip.duration,
                            originalDuration: clip.originalDuration,
                            gainDB: clip.gainDB,
                            isMuted: clip.isMuted,
                            fadeInDuration: clip.fadeInDuration,
                            fadeOutDuration: clip.fadeOutDuration,
                            fadeInCurve: clip.fadeInCurve,
                            fadeOutCurve: clip.fadeOutCurve,
                            filePath: relativePath(for: clip.fileURL, to: projectFolderURL)
                        )
                    },
                    plugins: track.plugins,
                    fxSends: track.fxSends
                )
            },
            fxChannels: fxChannels.map { FXChannelDocument(channel: $0) },
            masterPlugins: masterPlugins,
            pluginStates: audioEngine.capturePluginStates(),
            punchRange: punchRange,
            songRange: songRange,
            masterExportFileName: masterExportFileName
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(document).write(to: projectURL, options: .atomic)
            RecentProjects.shared.noteSaved(projectURL)
            return true
        } catch {
            presentProjectError(String(localized: "Could not save project: \(error.localizedDescription)"))
            return false
        }
    }

    public func saveProjectAndShowConfirmation() {
        guard saveProject() else { return }
        saveConfirmationTask?.cancel()
        saveConfirmationMessage = String(localized: "Project saved.")
        saveConfirmationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveConfirmationMessage = nil
        }
    }

    /// After an audio device or sample-rate change: asks whether to save, then
    /// relaunches MyDAW (reopening the current project) so every track path
    /// and plugin is rebuilt for the new device.
    public func promptRestartForAudioSettings() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Restart MyDAW to apply the new settings?")
        alert.informativeText = String(localized: "MyDAW needs to restart for the new audio device, sample rate or language to take effect. Save the project before restarting?")
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Save and Restart"))
        alert.addButton(withTitle: String(localized: "Restart Without Saving"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if isProjectOpen {
                guard saveProject() else { return }
            }
        case .alertSecondButtonReturn:
            break
        default:
            return
        }
        relaunch()
    }

    /// Set while relaunching: the project was already saved or discarded.
    private var skipsQuitConfirmation = false

    /// Asked for every quit (menu, ⌘Q, closing the window). Returns false
    /// when the user cancels or saving fails.
    public func confirmQuit() -> Bool {
        guard isProjectOpen, !skipsQuitConfirmation else { return true }

        let alert = NSAlert()
        alert.messageText = String(localized: "Save changes to MyDAW?")
        alert.informativeText = String(localized: "Do you want to save the project before quitting MyDAW?")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Don't Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveProject()
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    /// Starts a fresh copy of MyDAW once this process has exited, passing the
    /// current project file so it opens again, then quits.
    private func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        var arguments = [Bundle.main.bundleURL.path]
        if isProjectOpen, let projectPath = currentProjectURL?.path,
           FileManager.default.fileExists(atPath: projectPath) {
            arguments += ["--args", projectPath]
        }
        let quoted = arguments.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; open -n \(quoted.joined(separator: " "))"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        do {
            try process.run()
        } catch {
            presentProjectError(String(localized: "MyDAW could not restart itself. Please quit and reopen it manually.\n\n\(error.localizedDescription)"))
            return
        }
        skipsQuitConfirmation = true
        NSApp.terminate(nil)
    }

    public func loadProject() {
        guard !audioEngine.isPlaying && !audioEngine.isRecording else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Open MyDAW Project")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        let projectFiles = (try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension.lowercased() == "mydaw" } ?? []
        guard let url = projectFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first else {
            presentProjectError(String(localized: "This folder does not contain a .mydaw project file."))
            return
        }

        loadProject(from: url, projectFolderURL: folderURL)
    }

    /// Opens a project from the start screen's recent list.
    func openRecentProject(_ entry: RecentProject) {
        guard !audioEngine.isPlaying && !audioEngine.isRecording else { return }
        guard entry.exists else {
            presentProjectError(String(localized: "The project file could not be found:\n\(entry.path)"))
            return
        }
        loadProject(from: entry.url, projectFolderURL: entry.url.deletingLastPathComponent())
    }

    public func createNewProject() -> Bool {
        guard !audioEngine.isPlaying && !audioEngine.isRecording else { return false }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose New MyDAW Project Folder")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folderURL = panel.url else { return false }

        let projectName = folderURL.lastPathComponent.isEmpty ? "MyDAW Project" : folderURL.lastPathComponent
        let projectURL = folderURL.appendingPathComponent("\(projectName).mydaw")
        do {
            let recordingsURL = folderURL.appendingPathComponent("Recordings", isDirectory: true)
            try FileManager.default.createDirectory(at: recordingsURL, withIntermediateDirectories: true)
            currentProjectURL = projectURL
            projectFolderURL = folderURL.standardizedFileURL
            audioEngine.recordingsDirectory = recordingsURL.standardizedFileURL
            // A new project starts from its own default export name.
            masterExportFileName = nil
            isProjectOpen = true
            return saveProject()
        } catch {
            presentProjectError(String(localized: "Could not create project folder: \(error.localizedDescription)"))
            return false
        }
    }

    public func loadProject(from url: URL, projectFolderURL: URL) {
        do {
            let projectFolderURL = projectFolderURL.standardizedFileURL
            let recordingsURL = projectFolderURL.appendingPathComponent("Recordings", isDirectory: true)
            try FileManager.default.createDirectory(at: recordingsURL, withIntermediateDirectories: true)

            let document = try JSONDecoder().decode(ProjectDocument.self, from: Data(contentsOf: url))
            var restoredPluginIDs = Set<UUID>()
            func uniquePluginInstances(_ plugins: [TrackPluginDescriptor]) -> [TrackPluginDescriptor] {
                plugins.map { plugin in
                    if restoredPluginIDs.insert(plugin.id).inserted {
                        return plugin
                    }
                    return plugin.newInstance()
                }
            }
            var restoredTracks: [AudioTrack] = []
            for trackDocument in document.tracks {
                let track = AudioTrack(
                    id: trackDocument.id,
                    name: trackDocument.name,
                    channelMode: trackDocument.channelMode,
                    inputChannelIndex: trackDocument.inputChannelIndex,
                    isRecordArmed: trackDocument.isRecordArmed,
                    isMuted: trackDocument.isMuted,
                    isSoloed: trackDocument.isSoloed,
                    isInputMonitoring: trackDocument.isInputMonitoring,
                    volume: trackDocument.volume,
                    pan: trackDocument.pan,
                    trackHeight: CGFloat(trackDocument.trackHeight),
                    color: trackDocument.color.color,
                    plugins: uniquePluginInstances(trackDocument.plugins),
                    fxSends: trackDocument.fxSends
                )
                for clipDocument in trackDocument.clips {
                    let clipURL = resolveClipURL(clipDocument.filePath, relativeTo: projectFolderURL)
                    let clip = AudioClip(id: clipDocument.id, startTime: clipDocument.startTime, fileURL: clipURL)
                    clip.loadMetadata()
                    clip.setTrim(
                        startTime: clipDocument.startTime,
                        sourceStartTime: clipDocument.sourceStartTime,
                        duration: clipDocument.duration
                    )
                    clip.setGainDB(clipDocument.gainDB)
                    clip.isMuted = clipDocument.isMuted
                    clip.setFadeInDuration(clipDocument.fadeInDuration)
                    clip.setFadeOutDuration(clipDocument.fadeOutDuration)
                    clip.fadeInCurve = clipDocument.fadeInCurve
                    clip.fadeOutCurve = clipDocument.fadeOutCurve
                    track.restoreClip(clip)
                }
                track.selectedClipId = trackDocument.selectedClipId
                restoredTracks.append(track)
            }

            tracks = restoredTracks
            fxChannels = document.fxChannels.map {
                FXChannel(
                    id: $0.id,
                    name: $0.name,
                    volume: $0.volume,
                    pan: $0.pan,
                    isMuted: $0.isMuted,
                    isSoloed: $0.isSoloed,
                    plugins: uniquePluginInstances($0.plugins),
                    color: $0.color.color
                )
            }
            masterPlugins = uniquePluginInstances(document.masterPlugins)
            punchRange = document.punchRange
            songRange = document.songRange
            masterExportFileName = document.masterExportFileName
            audioEngine.setSavedPluginStates(document.pluginStates)
            let beatDuration = 60.0 / max(20.0, min(400.0, document.bpm))
            audioEngine.setPunchRange(
                startTime: punchRange.startBeat * beatDuration,
                endTime: punchRange.endBeat * beatDuration,
                enabled: punchRange.enabled
            )

            selectedTrackId = document.selectedTrackId
            showsBeats = document.showsBeats
            pixelsPerSecond = CGFloat(document.pixelsPerSecond)
            audioEngine.currentTime = max(0.0, document.currentTime)
            isRestoringScrollPosition = true
            timelineScrollTime = max(0.0, document.timelineScrollTime)
            scrollRestoreRevision += 1
            audioEngine.bpm = document.bpm
            audioEngine.metronomeEnabled = document.metronomeEnabled
            audioEngine.metronomeTimingOffsetMs = document.metronomeTimingOffsetMs
            audioEngine.metronomeVolume = document.metronomeVolume
            audioEngine.masterVolume = document.masterVolume
            audioEngine.manualRecordingCompensationMs = document.manualRecordingCompensationMs
            waveformVerticalScale = CGFloat(min(32.0, max(1.0, document.waveformVerticalScale)))
            trackHeightScale = CGFloat(min(3.0, max(0.5, document.trackHeightScale)))
            currentProjectURL = url
            self.projectFolderURL = projectFolderURL
            audioEngine.recordingsDirectory = recordingsURL
            isProjectOpen = true
            RecentProjects.shared.noteOpened(url)

            audioEngine.syncTracks(
                tracks,
                fxChannels: fxChannels,
                masterPlugins: masterPlugins
            )
            audioEngine.prepareForPluginGraphRestore()
        } catch {
            presentProjectError(String(localized: "Could not open project: \(error.localizedDescription)"))
        }
    }

    private func relativePath(for fileURL: URL, to projectFolderURL: URL) -> String {
        let standardizedFilePath = fileURL.standardizedFileURL.path
        let standardizedFolderPath = projectFolderURL.standardizedFileURL.path.hasSuffix("/")
            ? projectFolderURL.standardizedFileURL.path
            : projectFolderURL.standardizedFileURL.path + "/"
        if standardizedFilePath.hasPrefix(standardizedFolderPath) {
            return String(standardizedFilePath.dropFirst(standardizedFolderPath.count))
        }
        return standardizedFilePath
    }

    private func resolveClipURL(_ path: String, relativeTo projectFolderURL: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return projectFolderURL.appendingPathComponent(path).standardizedFileURL
    }

    // MARK: Unused recordings

    public var canMoveUnusedRecordings: Bool {
        isProjectOpen && !audioEngine.isPlaying && !audioEngine.isRecording && !audioEngine.hasPendingRecording
    }

    /// Moves the WAV files directly in the project's Recordings folder that no
    /// clip or clipboard entry uses into Recordings/Unused, then lists them.
    /// A deleted take is still in the Undo history, so it counts as unused;
    /// when a moved file was in that history, the history is cleared so Undo
    /// never brings back a clip whose file has gone.
    public func moveUnusedRecordings() {
        guard canMoveUnusedRecordings else { return }
        // Decided on the open project, so it is saved first: otherwise files
        // the last saved version still uses could be moved.
        let confirmation = NSAlert()
        confirmation.messageText = String(localized: "The project needs to be saved")
        confirmation.informativeText = String(localized: "The project will be saved before proceeding.\nThe last recording clip move cannot be undone (⌘Z).")
        confirmation.alertStyle = .informational
        confirmation.addButton(withTitle: String(localized: "Save Project and Continue"))
        let cancelButton = confirmation.addButton(withTitle: String(localized: "Cancel"))
        cancelButton.keyEquivalent = "\u{1b}"
        guard confirmation.runModal() == .alertFirstButtonReturn, saveProject() else { return }

        let fileManager = FileManager.default
        let recordingsURL = audioEngine.recordingsDirectory.standardizedFileURL
        let unusedURL = recordingsURL.appendingPathComponent("Unused", isDirectory: true)

        func key(_ url: URL) -> String {
            url.standardizedFileURL.resolvingSymlinksInPath().path
        }
        var usedPaths = Set(tracks.flatMap { $0.clips.map { key($0.fileURL) } })
        usedPaths.formUnion(clipboard.map { key($0.fileURL) })
        var historyPaths = Set<String>()
        for snapshot in undoStack + redoStack {
            for clips in snapshot.clipsByTrack.values {
                historyPaths.formUnion(clips.map { key($0.fileURL) })
            }
        }

        let candidates: [URL]
        do {
            candidates = try fileManager.contentsOfDirectory(
                at: recordingsURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            .filter { url in
                url.pathExtension.lowercased() == "wav" &&
                    (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true &&
                    !usedPaths.contains(key(url))
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } catch {
            presentProjectError(String(localized: "Could not read the Recordings folder.\n\n\(error.localizedDescription)"))
            return
        }

        var moved: [String] = []
        var failed: [String] = []
        var movedPaths = Set<String>()
        if !candidates.isEmpty {
            do {
                try fileManager.createDirectory(at: unusedURL, withIntermediateDirectories: true)
            } catch {
                presentProjectError(String(localized: "Could not create the Unused folder.\n\n\(error.localizedDescription)"))
                return
            }
        }
        for url in candidates {
            // Never overwrite an earlier file of the same name in Unused.
            var destination = unusedURL.appendingPathComponent(url.lastPathComponent)
            var suffix = 2
            while fileManager.fileExists(atPath: destination.path) {
                let base = url.deletingPathExtension().lastPathComponent
                destination = unusedURL.appendingPathComponent("\(base)_\(suffix).\(url.pathExtension)")
                suffix += 1
            }
            do {
                try fileManager.moveItem(at: url, to: destination)
                moved.append(destination.lastPathComponent)
                movedPaths.insert(key(url))
            } catch {
                failed.append(url.lastPathComponent)
            }
        }
        let clearsHistory = !movedPaths.isDisjoint(with: historyPaths)
        if clearsHistory {
            undoStack.removeAll()
            redoStack.removeAll()
            updateHistoryAvailability()
        }
        presentUnusedRecordingsResult(moved: moved, failed: failed, unusedURL: unusedURL, clearedHistory: clearsHistory)
    }

    private func presentUnusedRecordingsResult(moved: [String], failed: [String], unusedURL: URL, clearedHistory: Bool) {
        let alert = NSAlert()
        alert.alertStyle = failed.isEmpty ? .informational : .warning
        if moved.isEmpty && failed.isEmpty {
            alert.messageText = String(localized: "No unused recordings")
            alert.informativeText = String(localized: "Every WAV file in the Recordings folder is used by the project.")
        } else {
            alert.messageText = String(localized: "Moved \(moved.count) unused recordings")
            alert.informativeText = String(localized: "These files are not used by the project and were moved to:\n\(unusedURL.path)")
            var lines = moved
            if clearedHistory {
                lines += ["", String(localized: "The Undo history was cleared, since it referred to moved files.")]
            }
            if !failed.isEmpty {
                lines += ["", String(localized: "Could not be moved:")] + failed
            }
            let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
            textView.string = lines.joined(separator: "\n")
            textView.isEditable = false
            textView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            textView.textContainerInset = NSSize(width: 4, height: 4)
            let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 180))
            scrollView.documentView = textView
            scrollView.hasVerticalScroller = true
            scrollView.borderType = .bezelBorder
            alert.accessoryView = scrollView
        }
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    private func presentProjectError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "MyDAW Project")
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    // Zoom helpers
    public func zoomIn() {
        setPixelsPerSecond(pixelsPerSecond * 1.25)
    }

    public func zoomOut() {
        setPixelsPerSecond(pixelsPerSecond / 1.25)
    }

    /// Zooms horizontally while keeping the timeline position under
    /// `anchorOffset` (points from the left edge of the visible timeline) fixed.
    public func setPixelsPerSecond(_ newValue: CGFloat, anchorOffset: CGFloat) {
        let clampedValue = min(max(newValue, 20.0), 400.0)
        guard clampedValue != pixelsPerSecond else { return }

        let anchorTime = timelineScrollTime + Double(anchorOffset / pixelsPerSecond)
        pixelsPerSecond = clampedValue
        zoomRevision += 1
        timelineScrollTime = max(0.0, anchorTime - Double(anchorOffset / clampedValue))
    }

    public func setPixelsPerSecond(_ newValue: CGFloat) {
        let clampedValue = min(max(newValue, 20.0), 400.0)
        guard clampedValue != pixelsPerSecond else { return }

        let cursorOffsetPixels = max(0.0, audioEngine.currentTime - timelineScrollTime) * Double(pixelsPerSecond)
        pixelsPerSecond = clampedValue
        zoomRevision += 1
        timelineScrollTime = max(
            0.0,
            audioEngine.currentTime - cursorOffsetPixels / Double(clampedValue)
        )
    }

    public func snappedTimelineTime(_ time: Double) -> Double {
        let clampedTime = max(0.0, time)
        guard snapToGrid else { return clampedTime }
        let beatDuration = 60.0 / max(20.0, min(400.0, audioEngine.bpm))
        guard beatDuration.isFinite, beatDuration > 0.0 else { return clampedTime }
        return max(0.0, (clampedTime / beatDuration).rounded() * beatDuration)
    }
}
