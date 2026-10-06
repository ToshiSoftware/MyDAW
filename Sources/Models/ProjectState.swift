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

    /// Tracks and folder headers in display order; a folder's tracks follow
    /// its header directly. Changed only through the track and folder
    /// operations, which keep `tracks` and the tracks' folders in step.
    @Published public internal(set) var rows: [ArrangerRow] = [] {
        didSet { rowsDidChange() }
    }
    /// The tracks of `rows`, in the same order (folders left out).
    @Published public internal(set) var tracks: [AudioTrack] = []
    /// Asks the mixer to scroll a track's strip (or a folder's line) to its
    /// left edge.
    public let mixerScrollRequests = PassthroughSubject<UUID, Never>()
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
    /// Zoom and track-height scale, kept in their own object: they change on
    /// every step of a zoom or height control, and publishing them from here
    /// redrew every view observing the project — the whole mixer among them —
    /// on each step. Only the timeline's views observe it (as an environment
    /// object).
    public let timelineGeometry = TimelineGeometry()
    /// Horizontal zoom factor.
    public var pixelsPerSecond: CGFloat {
        get { timelineGeometry.pixelsPerSecond }
        set {
            guard newValue != timelineGeometry.pixelsPerSecond else { return }
            timelineGeometry.pixelsPerSecond = newValue
            scheduleWaveformRenderSync()
        }
    }
    /// The zoom and track-height scale the waveforms are drawn at. While the
    /// zoom or the track height is being changed, everything else follows at
    /// once but the waveforms already drawn are only stretched to their clip
    /// boxes; these catch up a tenth of a second after the change stops, and
    /// the waveforms are drawn again properly. (Redrawing every waveform on
    /// each step of the control was what made those changes stutter.)
    @Published public private(set) var waveformRenderPixelsPerSecond: CGFloat = 80.0
    @Published public private(set) var waveformRenderTrackHeightScale: CGFloat = 1.0
    private var waveformRenderSyncTask: Task<Void, Never>?
    /// The timeline seconds waveforms are drawn for (see `DrawWindowState`).
    public let waveformDrawWindow = DrawWindowState()
    /// Width of the visible timeline in points, kept up to date by the arranger.
    public var timelineViewportWidth: CGFloat = 1200 {
        didSet {
            if timelineViewportWidth != oldValue { refreshDrawWindow(force: true) }
        }
    }
    /// Where the timeline is scrolled to, kept in its own object: it changes
    /// with every scroll step, and publishing it from here would redraw every
    /// track header and lane each time.
    public let timelineScroll = TimelineScrollPosition()
    public var timelineScrollTime: Double {
        get { timelineScroll.time }
        set {
            guard timelineScroll.time != newValue else { return }
            timelineScroll.time = newValue
            refreshDrawWindow()
            timelineScroll.onChange?(newValue)
        }
    }
    @Published public var punchRange = PunchRangeDocument()
    @Published public var songRange = SongRangeDocument() {
        didSet { audioEngine.songEndTime = songEndTime }
    }
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
    /// Rollback recording: a normal (non-punch) recording starts playing
    /// `recordRollbackBars` bars before the playhead and records from the
    /// playhead on, so the take starts where the playhead was.
    @Published public var recordRollbackEnabled: Bool = UserDefaults.standard.bool(forKey: "MyDAW.recordRollback") {
        didSet {
            UserDefaults.standard.set(recordRollbackEnabled, forKey: "MyDAW.recordRollback")
        }
    }
    public static let recordRollbackBarsRange = 1...16
    @Published public var recordRollbackBars: Int = UserDefaults.standard.object(forKey: "MyDAW.recordRollbackBars") as? Int ?? 2 {
        didSet {
            UserDefaults.standard.set(recordRollbackBars, forKey: "MyDAW.recordRollbackBars")
        }
    }
    @Published public var pluginManager: PluginManager
    @Published public private(set) var startupLog: [String] = [String(localized: "Starting MyDAW...")]
    @Published public private(set) var isShowingStartupLog = true
    @Published public var isShowingMasterExportDialog = false
    @Published public var isExportingMasterMix = false
    @Published public var masterExportCompleted = false
    @Published public var masterExportError: String?
    /// What the running export is doing, and how far (0...1).
    @Published public private(set) var masterExportStage: MasterExportStage = .capturing
    @Published public private(set) var masterExportProgress: Double = 0.0
    /// The format chosen in the export dialog; saved with the project.
    @Published public var masterExportSettings = ExportSettings()
    /// The export file name without extension, as edited in the dialog.
    @Published public var masterExportBaseName = ""
    /// The folder the export goes to (nil: the project folder).
    @Published public private(set) var masterExportFolderURL: URL?
    @Published public private(set) var saveConfirmationMessage: String?
    @Published public private(set) var isProjectOpen = false
    /// The master export's file name as last chosen; saved with the project.
    public var masterExportFileName: String?
    /// True when the project has its own saved export format.
    private var hasSavedMasterExportSettings = false
    private var masterExportTask: Task<Void, Never>?
    private var saveConfirmationTask: Task<Void, Never>?
    @Published public private(set) var canUndo = false
    @Published public private(set) var canRedo = false
    public static let minimumPixelsPerSecond: CGFloat = 5.0
    public static let maximumPixelsPerSecond: CGFloat = 3200.0
    public static let maximumWaveformVerticalScale: CGFloat = 256.0

    @Published public var waveformVerticalScale: CGFloat = 1.0 {
        didSet {
            let clamped = min(Self.maximumWaveformVerticalScale, max(1.0, waveformVerticalScale))
            if clamped != waveformVerticalScale {
                waveformVerticalScale = clamped
            }
        }
    }
    public var trackHeightScale: CGFloat {
        get { timelineGeometry.trackHeightScale }
        set {
            let clamped = min(Self.maximumTrackHeightScale, max(Self.minimumTrackHeightScale, newValue))
            guard clamped != timelineGeometry.trackHeightScale else { return }
            timelineGeometry.trackHeightScale = clamped
            scheduleWaveformRenderSync()
        }
    }
    /// The smallest scale still shows a standard track's name and buttons.
    public static let minimumTrackHeightScale: CGFloat =
        TrackHeaderView.minimumRowHeight / AudioTrack.defaultTrackHeight
    public static let maximumTrackHeightScale: CGFloat = 3.0

    /// Live preview of a waveform-scale change: while the control moves,
    /// the waveforms already drawn are only stretched (cheap for the GPU); a
    /// tenth of a second after it stops, the real value is set and they are
    /// drawn again properly.
    public let waveformScalePreview = PreviewScale()
    private var previewCommitTask: Task<Void, Never>?
    private static let previewCommitDelay: UInt64 = 100_000_000

    /// Waveform vertical scale from a continuous control.
    public func previewWaveformVerticalScale(_ value: CGFloat) {
        let target = min(Self.maximumWaveformVerticalScale, max(1.0, value))
        waveformScalePreview.show(target: target, scale: target / waveformVerticalScale)
        schedulePreviewCommit()
    }

    private func schedulePreviewCommit() {
        previewCommitTask?.cancel()
        previewCommitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.previewCommitDelay)
            guard !Task.isCancelled else { return }
            self?.commitPreviews()
        }
    }

    /// Sets the previewed value and drops the stretching in the same pass,
    /// so the next frame shows the properly drawn result.
    private func commitPreviews() {
        if let target = waveformScalePreview.target {
            waveformVerticalScale = target
            waveformScalePreview.clear()
        }
    }

    /// Sets the all-tracks height scale from the user's controls. Any change
    /// first returns manually resized tracks to the standard height, so every
    /// track follows the scale from the same size.
    public func setTrackHeightScale(_ scale: CGFloat) {
        for track in tracks where track.trackHeight != AudioTrack.defaultTrackHeight {
            track.trackHeight = AudioTrack.defaultTrackHeight
        }
        trackHeightScale = scale
    }

    /// Set by the arranger: sets the track height scale (as
    /// `setTrackHeightScale`) while keeping the current track where it is on
    /// screen.
    public var trackHeightZoomAroundCurrentTrack: ((CGFloat) -> Void)?

    /// Track height scale from the slider: scales around the current track.
    public func zoomTrackHeightAroundCurrentTrack(_ scale: CGFloat) {
        if let zoom = trackHeightZoomAroundCurrentTrack {
            zoom(scale)
        } else {
            setTrackHeightScale(scale)
        }
    }

    @Published public var currentProjectURL: URL?
    public private(set) var projectFolderURL: URL?

    /// The open project's file name without `.mydaw`, shown in the title bar.
    public var openProjectName: String? {
        guard isProjectOpen else { return nil }
        return currentProjectURL?.deletingPathExtension().lastPathComponent
    }

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
        // Bars of 4 beats, as on the ruler.
        audioEngine.recordRollbackDuration = recordRollbackEnabled
            ? Double(recordRollbackBars) * 4.0 * beatDuration
            : 0.0
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

    let defaultColors: [Color] = [
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
        // A recording is one undo step: undo takes its takes away again
        // (their files stay in Recordings).
        self.audioEngine.onRecordingWillAddTakes = { [weak self] in
            self?.recordClipEdit()
        }
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
        // A track added after the snapshot is left as it is (adding tracks
        // is not undone), rather than emptied.
        for track in tracks where snapshot.clipsByTrack[track.id] != nil {
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
            // Edits never reach a track hidden in a closed folder.
            track.selectedClipIDs = isTrackVisible(track) ? snapshot.selectedClipIDs[track.id] ?? [] : []
        }
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    public func undo() {
        // Not until the takes are finalized: the snapshot has no take yet.
        guard !audioEngine.isPlaying && !audioEngine.isRecordingLocked,
              let snapshot = undoStack.popLast() else { return }
        redoStack.append(makeClipEditSnapshot())
        restoreClipEditSnapshot(snapshot)
        updateHistoryAvailability()
    }

    public func redo() {
        guard !audioEngine.isPlaying && !audioEngine.isRecordingLocked,
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
                    let peak = channel.outputStereoPeak.falling(to: fxOutputPeaks[channel.id] ?? .zero, by: 0.82)
                    // Assigning an unchanged value would still redraw the strip.
                    if peak != channel.outputStereoPeak {
                        channel.outputStereoPeak = peak
                        channel.currentOutputPeak = peak.maximum
                    }
                }

                // Update track input peak meters
                for track in self.tracks {
                    let inputPeak: Float
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
                        inputPeak = max(rawPeak, track.currentInputPeak * 0.85)
                    } else {
                        inputPeak = max(0.0, track.currentInputPeak * 0.70)
                    }
                    track.meter.update(
                        inputPeak: inputPeak,
                        outputPeak: track.outputStereoPeak.falling(to: outputPeaks[track.id] ?? .zero, by: 0.82)
                    )

                    // Append live waveform points if recording
                    if let channelPoints = liveChannelWaveforms[track.id], !channelPoints.isEmpty {
                        track.appendLiveChannelPeaks(channelPoints)
                    }
                }
            }
        }
    }

    public func addTrack(name: String? = nil, mode: ChannelMode = .stereo, isArmed: Bool = false) {
        insertNewTrack(name: name, mode: mode, isArmed: isArmed, at: newTrackPlace())
    }

    /// Adds a track at `place.index` in the rows, inside `place.folder`, and
    /// makes it the current track.
    func insertNewTrack(
        name: String? = nil,
        mode: ChannelMode = .stereo,
        isArmed: Bool = false,
        at place: (index: Int, folder: TrackFolder?)
    ) {
        let index = tracks.count + 1
        let trackName = name ?? "Audio \(index)"

        let newTrack = AudioTrack(
            name: trackName,
            channelMode: mode,
            inputChannelIndex: 0,
            isRecordArmed: isArmed,
            color: place.folder?.color ?? defaultColors[(index - 1) % defaultColors.count]
        )
        newTrack.folderID = place.folder?.id
        if let folder = place.folder, !folder.isOpen {
            // The new track becomes the current one, so it is shown.
            folder.isOpen = true
        }
        rows.insert(.track(newTrack), at: place.index)
        applyFolderStates()
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
            // One undo step, so undo takes the imported clip away again.
            recordClipEdit()
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

    public enum MasterExportStage {
        case capturing, converting
    }

    public func beginMasterExportDialog() {
        guard !audioEngine.isPlaying && !audioEngine.isRecording else { return }
        let savedName = masterExportFileName ?? defaultMasterExportBaseName
        let savedExtension = (savedName as NSString).pathExtension.lowercased()
        masterExportBaseName = ExportSettings.FileFormat(rawValue: savedExtension) != nil
            ? (savedName as NSString).deletingPathExtension
            : savedName
        if !hasSavedMasterExportSettings,
           ExportSettings.sampleRates.contains(audioEngine.hardwareSampleRate) {
            // First export of this project: the rate it is recorded at.
            masterExportSettings.sampleRate = audioEngine.hardwareSampleRate
        }
        masterExportSettings.normalize()
        if let folder = masterExportFolderURL,
           !FileManager.default.fileExists(atPath: folder.path) {
            masterExportFolderURL = nil
        }
        masterExportCompleted = false
        masterExportError = nil
        masterExportProgress = 0.0
        isShowingMasterExportDialog = true
    }

    /// The folder the export goes to.
    public var masterExportFolder: URL {
        masterExportFolderURL ?? projectFolderURL ?? audioEngine.recordingsDirectory.deletingLastPathComponent()
    }

    public func chooseMasterExportFolder() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Export Folder")
        panel.prompt = String(localized: "Choose")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = masterExportFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        masterExportFolderURL = url.standardizedFileURL
        masterExportCompleted = false
        masterExportError = nil
    }

    /// "<project name>_Master_Mix".
    private var defaultMasterExportBaseName: String {
        let projectName = currentProjectURL?.deletingPathExtension().lastPathComponent
            ?? projectFolderURL?.lastPathComponent
            ?? "MyDAW"
        return "\(projectName)_Master_Mix"
    }

    public func exportMasterMix(startTime: Double, endTime: Double) {
        guard !isExportingMasterMix else { return }
        var settings = masterExportSettings
        settings.normalize()
        masterExportSettings = settings

        var name = masterExportBaseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let typedExtension = (name as NSString).pathExtension.lowercased()
        if ExportSettings.FileFormat(rawValue: typedExtension) != nil {
            name = (name as NSString).deletingPathExtension
        }
        guard !name.isEmpty, !name.hasPrefix("."),
              name.rangeOfCharacter(from: CharacterSet(charactersIn: "/:")) == nil else {
            masterExportError = String(localized: "The name cannot be empty, start with “.”, or contain “/” or “:”.")
            return
        }
        masterExportBaseName = name
        let fileName = "\(name).\(settings.format.fileExtension)"
        let url = masterExportFolder.appendingPathComponent(fileName)

        if FileManager.default.fileExists(atPath: url.path) {
            let replace = NSAlert()
            replace.messageText = String(localized: "\(fileName) already exists. Do you want to replace it?")
            replace.alertStyle = .warning
            replace.addButton(withTitle: String(localized: "Replace"))
            let keepButton = replace.addButton(withTitle: String(localized: "Cancel"))
            keepButton.keyEquivalent = "\u{1b}"
            guard replace.runModal() == .alertFirstButtonReturn else { return }
        }

        masterExportFileName = fileName
        hasSavedMasterExportSettings = true
        isExportingMasterMix = true
        masterExportCompleted = false
        masterExportError = nil
        masterExportStage = .capturing
        masterExportProgress = 0.0

        // The master is captured in real time into a float file, then
        // converted to the chosen format.
        let captureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MyDAW-export-\(UUID().uuidString).caf")
        masterExportTask = Task { @MainActor in
            var isWritingOutput = false
            defer {
                try? FileManager.default.removeItem(at: captureURL)
                masterExportTask = nil
            }
            do {
                try await audioEngine.exportMasterMix(
                    to: captureURL,
                    startTime: startTime,
                    endTime: endTime,
                    tracks: tracks,
                    fxChannels: fxChannels,
                    progress: { fraction in
                        self.masterExportProgress = fraction
                    }
                )
                try Task.checkCancellation()
                masterExportStage = .converting
                masterExportProgress = 0.0
                isWritingOutput = true
                let conversion = Task.detached(priority: .userInitiated) {
                    try ExportEncoder.encode(source: captureURL, to: url, settings: settings) { fraction in
                        Task { @MainActor in
                            guard self.masterExportStage == .converting else { return }
                            self.masterExportProgress = fraction
                        }
                    }
                }
                try await withTaskCancellationHandler {
                    try await conversion.value
                } onCancel: {
                    conversion.cancel()
                }
                isExportingMasterMix = false
                masterExportCompleted = true
            } catch {
                isExportingMasterMix = false
                // A partly written file is not kept.
                if isWritingOutput {
                    try? FileManager.default.removeItem(at: url)
                }
                if !Task.isCancelled && !(error is CancellationError) {
                    masterExportError = error.localizedDescription
                }
            }
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
        // One past the highest default-named channel, so a name freed by a
        // removal is not given out again next to a channel that kept it.
        // Capped so a renamed "FX 9223372036854775807" cannot overflow.
        let number = min(fxChannels.compactMap { channel -> Int? in
            guard channel.name.hasPrefix("FX ") else { return nil }
            return Int(channel.name.dropFirst(3))
        }.max() ?? 0, 999_999) + 1
        let channel = FXChannel(name: "FX \(number)")
        // The FX channels share one colour, set from the line before them in
        // the mixer.
        if let color = fxChannels.first?.color {
            channel.color = color
        }
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
        // Sends are always wired, so a level change is only a volume.
        if audioEngine.updateSendLevel(track: track, fxChannelID: fxChannelID) {
            // Whether a send is on decides which tracks an FX solo keeps.
            if tracks.contains(where: \.effectiveSoloed) || fxChannels.contains(where: \.isSoloed) {
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
        // Not a track being recorded: its take is still being written.
        guard !(audioEngine.isRecordingLocked && tracks.first(where: { $0.id == id })?.isRecordArmed == true) else { return }
        rows.removeAll { $0.id == id }
        if selectedTrackId == id {
            selectedTrackId = tracks.first?.id
        }
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    /// Asks before deleting, since removing a track cannot be undone.
    public func confirmDeleteTrack(id: UUID) {
        guard let track = tracks.first(where: { $0.id == id }),
              !(audioEngine.isRecordingLocked && track.isRecordArmed),
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
    func confirmDeletion(name: String, detail: String) -> Bool {
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
        // What is recorded is fixed for the whole take (also the R key).
        guard !audioEngine.isRecordingLocked else { return }
        track.isRecordArmed.toggle()
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    /// Changing a track's channel mode leaves its files untouched: a mono
    /// track downmixes stereo clips as it plays, and a stereo track plays mono
    /// clips on both sides. Not on an armed track while recording, since the
    /// mode also sets how many input channels the recording captures.
    public func setInputRouting(for track: AudioTrack, channelMode: ChannelMode? = nil, inputChannelIndex: Int? = nil) {
        if let channelMode, !(audioEngine.isRecordingLocked && track.isRecordArmed) {
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
        if let inputChannelIndex, !(audioEngine.isRecordingLocked && track.isRecordArmed) {
            track.inputChannelIndex = inputChannelIndex
        }
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    public func toggleInputMonitoring(for track: AudioTrack) {
        track.isInputMonitoring.toggle()
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    public func toggleMute(for track: AudioTrack) {
        // Held on by its folder's M, which is turned off there.
        guard !track.isMutedByFolder else { return }
        track.isMuted.toggle()
        updateMixerLevelsAfterTrackControlChange()
    }

    public func toggleSolo(for track: AudioTrack) {
        guard !track.isSoloedByFolder else { return }
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

    func updateMixerLevelsAfterTrackControlChange() {
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
        guard !audioEngine.isPlaying && !audioEngine.isRecordingLocked else { return false }
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
                    folderID: track.folderID,
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
            folders: rows.enumerated().compactMap { position, row in
                row.folder.map { TrackFolderDocument(folder: $0, position: position) }
            },
            fxChannels: fxChannels.map { FXChannelDocument(channel: $0) },
            masterPlugins: masterPlugins,
            pluginStates: audioEngine.capturePluginStates(),
            punchRange: punchRange,
            songRange: songRange,
            masterExportFileName: masterExportFileName,
            masterExportSettings: hasSavedMasterExportSettings ? masterExportSettings : nil,
            masterExportFolderPath: masterExportFolderURL.map { folder in
                folder.standardizedFileURL.path == projectFolderURL.standardizedFileURL.path
                    ? "."
                    : relativePath(for: folder, to: projectFolderURL)
            }
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
        showSaveConfirmation()
    }

    private func showSaveConfirmation() {
        saveConfirmationTask?.cancel()
        saveConfirmationMessage = String(localized: "Project saved.")
        saveConfirmationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveConfirmationMessage = nil
        }
    }

    /// Saves the project under a new name in the same folder, so it keeps
    /// using that folder's Recordings. Asks only for the name; the folder
    /// cannot be changed.
    public func saveProjectAs() {
        guard isProjectOpen, !audioEngine.isPlaying, !audioEngine.isRecordingLocked,
              let oldURL = currentProjectURL else { return }
        let folderURL = oldURL.deletingLastPathComponent()

        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        nameField.stringValue = oldURL.deletingPathExtension().lastPathComponent
        let alert = NSAlert()
        alert.messageText = String(localized: "Save Project As")
        alert.informativeText = String(localized: "Enter a new project name. The project is saved in the same folder:\n\(folderURL.path)")
        alert.accessoryView = nameField
        alert.addButton(withTitle: String(localized: "Save"))
        let cancelButton = alert.addButton(withTitle: String(localized: "Cancel"))
        cancelButton.keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = nameField
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".mydaw") {
            name = String(name.dropLast(".mydaw".count))
        }
        guard !name.isEmpty, !name.hasPrefix("."),
              name.rangeOfCharacter(from: CharacterSet(charactersIn: "/:")) == nil else {
            presentProjectError(String(localized: "The name cannot be empty, start with “.”, or contain “/” or “:”."))
            return
        }

        let newURL = folderURL.appendingPathComponent("\(name).mydaw")
        if newURL.standardizedFileURL.path != oldURL.standardizedFileURL.path,
           FileManager.default.fileExists(atPath: newURL.path) {
            let replace = NSAlert()
            replace.messageText = String(localized: "\(newURL.lastPathComponent) already exists. Do you want to replace it?")
            replace.informativeText = String(localized: "The other project is replaced. Its recordings stay in the Recordings folder.")
            replace.alertStyle = .warning
            replace.addButton(withTitle: String(localized: "Replace"))
            let keepButton = replace.addButton(withTitle: String(localized: "Cancel"))
            keepButton.keyEquivalent = "\u{1b}"
            guard replace.runModal() == .alertFirstButtonReturn else { return }
        }

        currentProjectURL = newURL
        if saveProject() {
            showSaveConfirmation()
        } else {
            currentProjectURL = oldURL
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
        guard !audioEngine.isPlaying && !audioEngine.isRecordingLocked else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Open MyDAW Project")
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [Self.projectFileType]
        panel.directoryURL = projectPanelStartDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }

        loadProject(from: url, projectFolderURL: url.deletingLastPathComponent())
    }

    /// Opens a project from the start screen's recent list.
    func openRecentProject(_ entry: RecentProject) {
        guard !audioEngine.isPlaying && !audioEngine.isRecordingLocked else { return }
        guard entry.exists else {
            presentProjectError(String(localized: "The project file could not be found:\n\(entry.path)"))
            return
        }
        loadProject(from: entry.url, projectFolderURL: entry.url.deletingLastPathComponent())
    }

    /// Opens a .mydaw file double-clicked in the Finder (or dropped on the
    /// Dock icon). An open project is offered for saving first.
    func openProjectFile(_ url: URL) {
        NSApp.activate(ignoringOtherApps: true)
        let url = url.standardizedFileURL
        if isProjectOpen, currentProjectURL?.standardizedFileURL.path == url.path { return }
        guard !audioEngine.isPlaying && !audioEngine.isRecordingLocked else {
            presentProjectError(String(localized: "Stop playback and recording before opening another project."))
            return
        }
        if isProjectOpen {
            let alert = NSAlert()
            alert.messageText = String(localized: "Save the current project before opening \(url.lastPathComponent)?")
            alert.alertStyle = .warning
            alert.addButton(withTitle: String(localized: "Save"))
            alert.addButton(withTitle: String(localized: "Don't Save"))
            let cancelButton = alert.addButton(withTitle: String(localized: "Cancel"))
            cancelButton.keyEquivalent = "\u{1b}"
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                guard saveProject() else { return }
            case .alertSecondButtonReturn:
                break
            default:
                return
            }
        }
        loadProject(from: url, projectFolderURL: url.deletingLastPathComponent())
    }

    /// The .mydaw file type, so the panels show and accept project files only.
    private static let projectFileType = UTType(filenameExtension: "mydaw", conformingTo: .data) ?? .data

    /// Where the New and Open panels start: the folder holding the last
    /// project's folder, so a new project gets a folder of its own beside it
    /// rather than sharing the last one's Recordings.
    private var projectPanelStartDirectory: URL? {
        guard let lastProjectURL = currentProjectURL ?? RecentProjects.shared.entries.first?.url else { return nil }
        return lastProjectURL.deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Asks for the new project's file name and folder; the .mydaw file and
    /// its Recordings folder are created side by side in that folder.
    public func createNewProject() -> Bool {
        guard !audioEngine.isPlaying && !audioEngine.isRecordingLocked else { return false }
        // Open the panel expanded, so its New Folder button shows at once.
        UserDefaults.standard.set(true, forKey: "NSNavPanelExpandedStateForSaveMode")
        UserDefaults.standard.set(true, forKey: "NSNavPanelExpandedStateForSaveMode2")
        let panel = NSSavePanel()
        panel.title = String(localized: "New MyDAW Project")
        panel.message = String(localized: "The project file and its Recordings folder are created in the chosen folder.")
        panel.prompt = String(localized: "Create")
        panel.nameFieldStringValue = String(localized: "MyDAW Project")
        panel.allowedContentTypes = [Self.projectFileType]
        panel.canCreateDirectories = true
        panel.directoryURL = projectPanelStartDirectory
        guard panel.runModal() == .OK, let chosenURL = panel.url else { return false }

        let projectURL = chosenURL.pathExtension.lowercased() == "mydaw"
            ? chosenURL
            : chosenURL.appendingPathExtension("mydaw")
        let folderURL = projectURL.deletingLastPathComponent()
        do {
            let recordingsURL = folderURL.appendingPathComponent("Recordings", isDirectory: true)
            try FileManager.default.createDirectory(at: recordingsURL, withIntermediateDirectories: true)
            currentProjectURL = projectURL
            projectFolderURL = folderURL.standardizedFileURL
            audioEngine.recordingsDirectory = recordingsURL.standardizedFileURL
            // A new project starts from its own default export name.
            masterExportFileName = nil
            masterExportSettings = ExportSettings()
            hasSavedMasterExportSettings = false
            masterExportFolderURL = nil
            isProjectOpen = true
            return saveProject()
        } catch {
            presentProjectError(String(localized: "Could not create the Recordings folder: \(error.localizedDescription)"))
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
                track.folderID = trackDocument.folderID
                restoredTracks.append(track)
            }

            // Folders go back to their places among the tracks; each place is
            // counted with the folders before it already in.
            var restoredRows = restoredTracks.map { ArrangerRow.track($0) }
            // A folder whose ID is already taken (an edited file) is left out:
            // rows must have unique IDs.
            var usedIDs = Set(restoredTracks.map(\.id))
            for folderDocument in document.folders.sorted(by: { $0.position < $1.position })
            where usedIDs.insert(folderDocument.id).inserted {
                restoredRows.insert(
                    .folder(folderDocument.makeFolder()),
                    at: min(max(0, folderDocument.position), restoredRows.count)
                )
            }
            rows = restoredRows
            applyFolderStates()
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
            masterExportSettings = document.masterExportSettings ?? ExportSettings()
            hasSavedMasterExportSettings = document.masterExportSettings != nil
            masterExportFolderURL = document.masterExportFolderPath.map {
                $0 == "." ? projectFolderURL : resolveClipURL($0, relativeTo: projectFolderURL)
            }
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
            waveformVerticalScale = CGFloat(min(Self.maximumWaveformVerticalScale, max(1.0, document.waveformVerticalScale)))
            trackHeightScale = CGFloat(document.trackHeightScale)
            // An opened project is drawn at its zoom at once, not stretched.
            syncWaveformRender()
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
    /// Other .mydaw files in the same folder share that Recordings folder, so
    /// the files their clips use are kept too.
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
        let otherProjectCount: Int
        do {
            let otherPaths = try clipPathsOfOtherProjects()
            otherProjectCount = otherPaths.projectCount
            usedPaths.formUnion(otherPaths.paths.map { key($0) })
        } catch let error as OtherProjectReadError {
            presentProjectError(String(localized: "Could not read the project \(error.fileName) in the same folder, so no files were moved.\n\n\(error.reason)"))
            return
        } catch {
            presentProjectError(String(localized: "Could not read the project folder.\n\n\(error.localizedDescription)"))
            return
        }
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
        presentUnusedRecordingsResult(
            moved: moved,
            failed: failed,
            unusedURL: unusedURL,
            clearedHistory: clearsHistory,
            otherProjectCount: otherProjectCount
        )
    }

    private struct OtherProjectReadError: Error {
        let fileName: String
        let reason: String
    }

    /// The clip files used by the other .mydaw files in this project's folder.
    private func clipPathsOfOtherProjects() throws -> (paths: [URL], projectCount: Int) {
        guard let projectFolderURL else { return ([], 0) }
        let currentPath = currentProjectURL?.standardizedFileURL.path
        let projectFiles = try FileManager.default.contentsOfDirectory(
            at: projectFolderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "mydaw" && $0.standardizedFileURL.path != currentPath }

        var paths: [URL] = []
        for url in projectFiles {
            do {
                let document = try JSONDecoder().decode(ProjectDocument.self, from: Data(contentsOf: url))
                for track in document.tracks {
                    paths += track.clips.map { resolveClipURL($0.filePath, relativeTo: projectFolderURL) }
                }
            } catch {
                throw OtherProjectReadError(fileName: url.lastPathComponent, reason: error.localizedDescription)
            }
        }
        return (paths, projectFiles.count)
    }

    private func presentUnusedRecordingsResult(
        moved: [String],
        failed: [String],
        unusedURL: URL,
        clearedHistory: Bool,
        otherProjectCount: Int
    ) {
        let alert = NSAlert()
        alert.alertStyle = failed.isEmpty ? .informational : .warning
        if moved.isEmpty && failed.isEmpty {
            alert.messageText = String(localized: "No unused recordings")
            alert.informativeText = otherProjectCount > 0
                ? String(localized: "Every WAV file in the Recordings folder is used by this project or by the other projects in the same folder (\(otherProjectCount)).")
                : String(localized: "Every WAV file in the Recordings folder is used by the project.")
        } else {
            alert.messageText = String(localized: "Moved \(moved.count) unused recordings")
            alert.informativeText = String(localized: "These files are not used by the project and were moved to:\n\(unusedURL.path)")
            var lines = moved
            if otherProjectCount > 0 {
                lines += ["", String(localized: "Files used by the other projects in the same folder (\(otherProjectCount)) were left in place.")]
            }
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

    private func scheduleWaveformRenderSync() {
        waveformRenderSyncTask?.cancel()
        waveformRenderSyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.previewCommitDelay)
            guard !Task.isCancelled else { return }
            self?.syncWaveformRender()
        }
    }

    /// Draws the waveforms at the current zoom and track height again.
    func syncWaveformRender() {
        waveformRenderSyncTask?.cancel()
        waveformRenderSyncTask = nil
        if waveformRenderPixelsPerSecond != pixelsPerSecond {
            waveformRenderPixelsPerSecond = pixelsPerSecond
        }
        if waveformRenderTrackHeightScale != trackHeightScale {
            waveformRenderTrackHeightScale = trackHeightScale
        }
        refreshDrawWindow(force: true)
    }

    /// Keeps `waveformDrawWindow` around the visible range (measured
    /// at the waveforms' zoom); with `force` it is centred again at once.
    func refreshDrawWindow(force: Bool = false) {
        let visible = Double(max(1.0, timelineViewportWidth) / max(0.001, waveformRenderPixelsPerSecond))
        let start = timelineScrollTime
        let end = start + visible
        let current = waveformDrawWindow.range
        let margin = visible * 0.5
        if !force && start - margin >= current.lowerBound && end + margin <= current.upperBound { return }
        waveformDrawWindow.set((start - 2.0 * visible)...(end + 2.0 * visible))
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
        let clampedValue = min(max(newValue, Self.minimumPixelsPerSecond), Self.maximumPixelsPerSecond)
        guard clampedValue != pixelsPerSecond else { return }

        let anchorTime = timelineScrollTime + Double(anchorOffset / pixelsPerSecond)
        pixelsPerSecond = clampedValue
        setScrollTimeAfterZoom(max(0.0, anchorTime - Double(anchorOffset / clampedValue)))
    }

    /// After a zoom the tracks must scroll even when the scroll time stays
    /// the same: the same time is now a different offset in points.
    private func setScrollTimeAfterZoom(_ time: Double) {
        if timelineScrollTime != time {
            timelineScrollTime = time
        } else {
            refreshDrawWindow()
            timelineScroll.onChange?(time)
        }
    }

    public func setPixelsPerSecond(_ newValue: CGFloat) {
        let clampedValue = min(max(newValue, Self.minimumPixelsPerSecond), Self.maximumPixelsPerSecond)
        guard clampedValue != pixelsPerSecond else { return }

        let cursorOffsetPixels = max(0.0, audioEngine.currentTime - timelineScrollTime) * Double(pixelsPerSecond)
        pixelsPerSecond = clampedValue
        setScrollTimeAfterZoom(max(
            0.0,
            audioEngine.currentTime - cursorOffsetPixels / Double(clampedValue)
        ))
    }

    public func snappedTimelineTime(_ time: Double) -> Double {
        let clampedTime = max(0.0, time)
        guard snapToGrid else { return clampedTime }
        let beatDuration = 60.0 / max(20.0, min(400.0, audioEngine.bpm))
        guard beatDuration.isFinite, beatDuration > 0.0 else { return clampedTime }
        return max(0.0, (clampedTime / beatDuration).rounded() * beatDuration)
    }
}

/// The timeline's scroll position in seconds (see `timelineScroll`).
@MainActor
public final class TimelineScrollPosition: ObservableObject {
    @Published public var time: Double = 0.0
    /// Where the tracks' scroll view really is (points), reported on every
    /// scroll step. The ruler is placed by it, so the ruler and the tracks
    /// stay together even while a zoom has the tracks' scroll clamped short
    /// of `time` for a moment. Nil until the scroll view reports.
    @Published public var trackOffset: CGFloat?

    /// Set by the arranger: scrolls the tracks to follow a change at once.
    public var onChange: ((Double) -> Void)?
}

/// A view-only stretch shown while a scale control moves (see
/// `ProjectState.waveformScalePreview`). Only the stretching views observe it.
@MainActor
public final class PreviewScale: ObservableObject {
    /// Previewed value over the current one.
    @Published public private(set) var scale: CGFloat = 1.0
    /// The value to set when the control stops; nil when not previewing.
    public private(set) var target: CGFloat?
    /// Never previews: for views outside the arranger.
    public static let none = PreviewScale()

    func show(target: CGFloat, scale: CGFloat) {
        self.target = target
        if scale != self.scale { self.scale = scale }
    }

    func clear() {
        target = nil
        if scale != 1.0 { scale = 1.0 }
    }
}

/// Zoom and track-height scale (see `ProjectState.timelineGeometry`).
@MainActor
public final class TimelineGeometry: ObservableObject {
    @Published public internal(set) var pixelsPerSecond: CGFloat = 80.0
    @Published public internal(set) var trackHeightScale: CGFloat = 1.0
}

/// The timeline seconds waveforms are drawn for: the visible range and two
/// screens either side (see `ProjectState.refreshDrawWindow`). It moves only
/// when the view nears its edge or the waveforms' zoom changes, so scrolling
/// rarely redraws the waveforms, and a redraw draws a few screens, not the
/// whole song. Clips outside it are not built at all.
@MainActor
public final class DrawWindowState: ObservableObject {
    @Published public private(set) var range: ClosedRange<Double> =
        -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude
    /// Draws everything: for waveforms outside the arranger.
    public static let unbounded = DrawWindowState()

    func set(_ window: ClosedRange<Double>) {
        if window != range { range = window }
    }
}
