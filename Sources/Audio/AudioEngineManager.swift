import Foundation
import AVFoundation
import AppKit
import CoreAudioKit

public enum MyDAWNotificationCenter {
    public static let shared = Foundation.NotificationCenter()
}

public struct TrackCaptureConfig: @unchecked Sendable {
    public let trackId: UUID
    public let isArmed: Bool
    public let channelOffset: Int
    public let isStereo: Bool
}

@MainActor
public final class AudioEngineManager: NSObject, ObservableObject, NSWindowDelegate {
    public let engine = AVAudioEngine()
    /// Processing load and dropouts for the status bar.
    public let loadMonitor = AudioLoadMonitor()

    @Published public var isPlaying: Bool = false
    @Published public var isRecording: Bool = false
    @Published public private(set) var isPunchRecording: Bool = false
    @Published public private(set) var hasPendingRecording: Bool = false
    @Published public private(set) var isStartingPlayback: Bool = false
    /// The playhead in seconds, kept in its own object: it changes 60 times
    /// a second while playing, and publishing it from the engine redrew
    /// every view observing the engine (arranger, mixer, transport) each time.
    public let transportClock = TransportClock()
    public var currentTime: Double {
        get { transportClock.time }
        set { if transportClock.time != newValue { transportClock.time = newValue } }
    }
    @Published public var bpm: Double = 120.0 {
        didSet {
            if isPlaying || isRecording {
                startMetronome()
            }
        }
    }
    @Published public var metronomeEnabled: Bool = false {
        didSet {
            if metronomeEnabled && (isPlaying || isRecording) {
                startMetronome()
            } else if !metronomeEnabled {
                stopMetronome()
            }
        }
    }
    @Published public var metronomeTimingOffsetMs: Double = 0.0 {
        didSet {
            guard metronomeTimingOffsetMs.isFinite else {
                metronomeTimingOffsetMs = 0.0
                return
            }
            let clamped = min(500.0, max(-500.0, metronomeTimingOffsetMs))
            if clamped != metronomeTimingOffsetMs {
                metronomeTimingOffsetMs = clamped
            }
            if isPlaying || isRecording {
                startMetronome()
            }
        }
    }
    @Published public var metronomeVolume: Double = 1.0 {
        didSet {
            guard metronomeVolume.isFinite else {
                metronomeVolume = 1.0
                return
            }
            let clamped = min(1.0, max(0.0, metronomeVolume))
            if clamped != metronomeVolume {
                metronomeVolume = clamped
            }
            clickMixerNode?.outputVolume = Float(metronomeVolume)
        }
    }

    /// The actual sample rate the hardware is running at (read from AVAudioEngine inputNode).
    /// This is what is used for recording and playback to avoid pitch shift.
    @Published public var hardwareSampleRate: Double = 44100.0

    /// UI display/preference only — the real rate is always hardwareSampleRate.
    @Published public var sampleRate: Double = 44100.0

    /// The master fader, kept in its own object: publishing it from the
    /// engine redrew every view observing the engine on each step of a drag.
    public let masterVolumeState = MasterVolumeState()
    public var masterVolume: Float {
        get { masterVolumeState.value }
        set {
            guard newValue != masterVolumeState.value else { return }
            masterVolumeState.value = newValue
            masterOutputNode?.outputVolume = newValue
        }
    }
    /// Master output level; its own object for the same reason as
    /// `transportClock` (30 Hz updates while audio plays).
    public let masterMeter = TrackMeter()
    public private(set) var masterPeak: Float = 0.0
    public var masterStereoPeak: StereoPeak { masterMeter.outputPeak }
    @Published public var recordingsDirectory: URL
    @Published public var inputHardwareChannels: Int = 2
    @Published public var isAudioInputActive: Bool = false
    @Published public var inputBufferFrameSize: Int = 1024
    @Published public private(set) var estimatedRecordingLatencyMs: Double = 0.0
    @Published public private(set) var inputDeviceLatencyFrames: UInt32 = 0
    @Published public private(set) var outputDeviceLatencyFrames: UInt32 = 0
    @Published public private(set) var inputSafetyOffsetFrames: UInt32 = 0
    @Published public private(set) var outputSafetyOffsetFrames: UInt32 = 0
    @Published public var manualRecordingCompensationMs: Double = 0.0 {
        didSet {
            guard manualRecordingCompensationMs.isFinite else {
                manualRecordingCompensationMs = 0.0
                return
            }
            let clamped = min(5000.0, max(-5000.0, manualRecordingCompensationMs))
            if clamped != manualRecordingCompensationMs {
                manualRecordingCompensationMs = clamped
            }
        }
    }
    @Published public private(set) var selectedInputDeviceID: AudioDeviceID = 0
    @Published public private(set) var selectedOutputDeviceID: AudioDeviceID = 0
    @Published public private(set) var unavailablePluginIDs: Set<UUID> = []
    /// macOS default input/output found before MyDAW replaced them.
    private var originalDefaultDevices: (input: AudioDeviceID, output: AudioDeviceID)?

    /// Each track's clips play through one renderer (see `TrackRenderer`)
    /// into the track's output mixer.
    private var trackRenderers: [UUID: TrackRenderer] = [:]
    // Last node of each track's insert chain; fans out to the main mixer and
    // to a send to every FX channel, so sends carry the post-insert signal.
    private var trackChainTails: [UUID: AVAudioNode] = [:]
    /// The FX channels each track's splitter feeds, in fan-out order.
    private var trackSendFXIDs: [UUID: [UUID]] = [:]
    private var trackSplitterNodes: [UUID: AVAudioMixerNode] = [:]
    // AVAudioMixing pan only acts on a connection into a mixer, so pan gets
    // its own mixer stage after the inserts (pan into an AU input is ignored).
    private var trackPanNodes: [UUID: AVAudioMixerNode] = [:]
    private var trackPanValues: [UUID: Float] = [:]
    private var fxPanNodes: [UUID: AVAudioMixerNode] = [:]
    private var pendingSplitterRewires: [UUID: AVAudioFormat] = [:]
    /// Whether each track's direct (dry) path into the main mixer is heard;
    /// off while an FX solo keeps only the track's sends.
    private var trackDryAudible: [UUID: Bool] = [:]
    /// Delay compensation for FX channel latency (see
    /// `updateLatencyCompensation`): each track's dry path is delayed by
    /// `fxCompensationLatency`, the largest FX channel latency, and each FX
    /// return by that minus its own latency. Clip pre-roll adds it back.
    private var trackDryDelayNodes: [UUID: AVAudioUnitEffect] = [:]
    private var fxReturnDelayNodes: [UUID: AVAudioUnitEffect] = [:]
    private var fxCompensationLatency: Double = 0.0
    /// The largest track pre-roll (own inserts + FX compensation). The
    /// transport starts at least this far ahead, so every renderer can play
    /// its track this much early and no audio after the start is lost.
    private var transportPreRoll: Double = 0.0
    private var syncedTracks: [AudioTrack] = []
    /// Plug-ins whose latency changes are listened to, retained until the
    /// listener is removed.
    private var latencyListenedUnits: [ObjectIdentifier: AVAudioUnit] = [:]
    private var trackOutputNodes: [UUID: AVAudioMixerNode] = [:]
    /// First node after each track's output mixer; downmixes mono tracks.
    private var trackDownmixNodes: [UUID: AVAudioUnitEffect] = [:]
    private var trackPluginNodes: [UUID: [AVAudioNode]] = [:]
    private var trackPluginLatencies: [UUID: Double] = [:]
    private var fxInputNodes: [UUID: AVAudioMixerNode] = [:]
    // Last stage of each FX chain; feeds the main mixer and carries the meter tap.
    private var fxOutputNodes: [UUID: AVAudioMixerNode] = [:]
    private var fxPluginNodes: [UUID: [AVAudioNode]] = [:]
    private var fxGraphSignatures: [UUID: [UUID]] = [:]
    /// Every track sends to every FX channel, at volume 0 when its send is
    /// off, so moving a send only changes a volume. Wiring a send on demand
    /// meant changing the graph of a running engine, where connects are only
    /// queued: a raised send stayed silent until some later engine stop, and
    /// detaching it again at -inf froze the app.
    private struct SendKey: Hashable {
        let trackID: UUID
        let fxChannelID: UUID
    }
    private var sendGainNodes: [SendKey: AVAudioMixerNode] = [:]
    /// Gain mixers of removed sends, still in their track's splitter fan-out.
    /// Detaching a fan-out destination leaves the splitter pointing at it and
    /// AVAudioEngine then throws on any query of the splitter's outputs, so
    /// they stay attached until connectTrackChainTail rewires the fan-out.
    private var retiredSendGains: [UUID: [AVAudioMixerNode]] = [:]
    private var pluginAudioUnits: [UUID: AVAudioUnit] = [:]
    private var vst3Instances: [UUID: VST3NativeInstance] = [:]
    private var syncedFXChannels: [FXChannel] = []
    private var pluginWindows: [UUID: NSWindow] = [:]
    private var pluginWindowFrames: [UUID: NSRect] = [:]
    private var pluginViewControllers: [UUID: NSViewController] = [:]
    private var pluginViewSizeObservers: [UUID: [Any]] = [:]
    private weak var mainApplicationWindow: NSWindow?
    private let masterChannelID = UUID()
    private var masterOutputNode: AVAudioMixerNode?
    // Final stage before the device: after master volume and master plug-ins,
    // so the MASTER meter shows what is actually output.
    private var masterMeterNode: AVAudioMixerNode?
    private var masterMeterOutput: AVAudioNode { masterMeterNode ?? engine.outputNode }
    private var masterPluginNodes: [AVAudioNode] = []
    private var masterPluginSignature: [UUID] = []
    private var masterPluginGraphGeneration = 0
    private var isMasterPluginGraphBuilding = false
    private var pendingMasterPluginSync: [TrackPluginDescriptor]?
    private var configuredMasterPlugins: [TrackPluginDescriptor] = []

    private var masterPluginIDs: Set<UUID> = []
    private var pluginDescriptors: [UUID: TrackPluginDescriptor] = [:]
    private var savedPluginStates: [UUID: Data] = [:]
    private var pluginStateRestoreTasks: [UUID: Task<Void, Never>] = [:]
    private var restoredPluginStateIDs: Set<UUID> = []
    private var pluginUIRequests: Set<UUID> = []
    private var pendingPluginUIRequests: Set<UUID> = []
    private var hasWarmedUpAudioGraph = false
    private let pluginUIRequestQueue = DispatchQueue(
        label: "MyDAW.plugin-ui-request",
        qos: .userInitiated
    )
    private var pluginGraphGenerations: [UUID: Int] = [:]
    private var pluginGraphSignatures: [UUID: [UUID]] = [:]
    private var fxPluginGraphGenerations: [UUID: Int] = [:]

    public func isPluginUnavailable(_ pluginID: UUID) -> Bool {
        unavailablePluginIDs.contains(pluginID)
    }

    private func safeDisconnectNodeOutput(_ node: AVAudioNode) {
        guard node !== engine.outputNode else { return }
        guard engine.attachedNodes.contains(node) else { return }
        engine.disconnectNodeOutput(node)
    }

    private func safeDisconnectNodeInput(_ node: AVAudioNode) {
        guard node !== engine.mainMixerNode && node !== engine.outputNode else { return }
        guard engine.attachedNodes.contains(node) else { return }
        engine.disconnectNodeInput(node)
    }

    private func safeDetach(_ node: AVAudioNode) {
        guard engine.attachedNodes.contains(node) else { return }
        engine.detach(node)
    }

    private func markPluginUnavailable(_ pluginID: UUID) {
        unavailablePluginIDs.insert(pluginID)
    }

    // Active disk writers during recording
    private var activeWriters: [UUID: AudioDiskWriter] = [:]
    private var activeClips: [UUID: AudioClip] = [:]
    /// Called right before a recording adds its takes to the tracks, so the
    /// project can keep the clips as they were for undo.
    public var onRecordingWillAddTakes: (@MainActor () -> Void)?

    /// True while `clipID` is a take being recorded: from the record start
    /// (also before a punch-in) until its file is finalized after the stop.
    /// The lanes draw such a take growing with the playhead.
    public func isRecordingTake(_ clipID: UUID) -> Bool {
        (isRecording || hasPendingRecording) && activeClips.values.contains { $0.id == clipID }
    }

    /// While recording, and until the takes are finalized after the stop,
    /// what is recorded must not change: the R buttons, the armed tracks'
    /// input channels and the takes themselves are locked.
    public var isRecordingLocked: Bool {
        isRecording || hasPendingRecording
    }

    // Thread-safe capture configuration passed to real-time audio thread
    private let captureLock = NSLock()
    private var captureConfigs: [TrackCaptureConfig] = []
    private var writersSnapshot: [UUID: AudioDiskWriter] = [:]
    private var recordingActiveState: Bool = false
    // A punch take is recorded as the whole pass and trimmed to the punch
    // range on stop, leaving handles for later trim/crossfade adjustment.
    private struct PunchTrim {
        let fileTimelineStart: Double
        let punchIn: Double
        let punchOut: Double
    }
    private var recordingPunchTrim: PunchTrim?
    /// The punch range of the take being recorded, kept until its file is
    /// finalized after the stop (the lanes draw only the part inside it).
    private var recordingTakePunchTrim: PunchTrim?
    public var recordingTakePunchIn: Double? { recordingTakePunchTrim?.punchIn }
    public var recordingTakePunchOut: Double? { recordingTakePunchTrim?.punchOut }
    /// Rollback recording: a recording without a punch range starts playing
    /// this many seconds before the playhead and records from the playhead
    /// on (a punch-in at the playhead with no punch-out). 0 = off.
    public var recordRollbackDuration: Double = 0.0
    /// True while such a pass runs; the punch range is then the rollback's.
    private var isRollbackPass = false
    private static let punchCrossfadeDuration = 0.01
    private let recordingTimingLock = NSLock()
    private var recordingTimelineStart: Double = 0.0
    private var recordingTransportStartHostTime: UInt64?
    private var punchInTime: Double?
    private var punchOutTime: Double?
    private var punchArmedTrackIDs: Set<UUID> = []
    // Armed tracks whose existing clips are silenced because they are
    // recording right now (whole take, or only inside the punch range).
    private var recordingMutedTrackIDs: Set<UUID> = []

    private struct InputMonitorConfig: Equatable {
        let channelOffset: Int
        let isStereo: Bool
    }
    private var inputCaptureFormat: AVAudioFormat?
    private var inputMonitorNodes: [UUID: AVAudioUnitEffect] = [:]
    private var desiredInputMonitors: [UUID: InputMonitorConfig] = [:]
    private var appliedInputMonitors: [UUID: InputMonitorConfig] = [:]
    private var inputMonitorApplyTask: Task<Void, Never>?
    private var quietRewireGeneration = 0
    private var isWaitingForQuietRewire = false
    /// The FX input each send's gain mixer is currently connected to.
    private var wiredSendTargets: [SendKey: AVAudioMixerNode] = [:]
    private var punchPlaybackState: Int = 0
    private var pendingRecordingClipStartTime: Double?
    private var hasLoggedFirstRecordingInput = false

    // Realtime channel peak levels written by audio thread, read by 60Hz UI timer
    private let peakLock = NSLock()
    private var rawChannelPeaks: [Float] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
    private var masterOutputPeak: StereoPeak = .zero
    /// Track meters, kept by each track's dry delay unit as it renders.
    /// Taps on the track splitters stopped for good at times (all tracks at
    /// once, after a plug-in was inserted on one of them) while the tracks
    /// kept sounding, and reinstalling the tap did not bring them back.
    private var trackMeters: [UUID: RenderPeakMeter] = [:]
    private var fxOutputPeaks: [UUID: StereoPeak] = [:]
    private var liveWaveformPeaksBuffer: [UUID: [[(min: Float, max: Float)]]] = [:]
    // Track meter health (checkTrackMeters). The render cycle counts
    // advance even on silence; the master tap count is written under peakLock.
    private var masterTapCallbackCount = 0
    private var trackMeterWatch: [UUID: (cycles: Int, since: TimeInterval)] = [:]
    private var trackMeterStallsLogged: Set<UUID> = []
    private var lastMasterTapCount = 0
    private var lastMasterTapAdvance: TimeInterval = 0
    private var wasEngineRunning = false
    private var meterTrackNames: [UUID: String] = [:]
    /// Recent engine and graph events, written to the log on a recovery.
    private var graphEventHistory: [String] = []

    // Timers
    private var playheadTimer: Timer?
    private var playheadStartTime: Date?
    private var playheadStartHostTime: UInt64?
    private var playheadStartOffset: Double = 0.0
    /// Bumped whenever the playhead timer starts or stops. A tick queued
    /// before that must not write the playhead: after a seek it would add
    /// the old run's elapsed time to the new position.
    private var playheadTimerGeneration = 0

    /// Song end flag in seconds (nil: none). Playback or recording that
    /// crosses it stops; one started at or after it runs on.
    public var songEndTime: Double?
    /// Called when the playhead crosses `songEndTime`; the owner stops the
    /// transport, since only it knows the current tracks.
    public var onReachSongEnd: (() -> Void)?
    private var hasReachedSongEnd = false
    private var isStoppingAtSongEnd = false

    private var meterTimer: Timer?
    private var clickNode: AVAudioPlayerNode?
    private var clickMixerNode: AVAudioMixerNode?
    private var clickBuffer: AVAudioPCMBuffer?
    private var accentClickBuffer: AVAudioPCMBuffer?
    private var engineWarmupNode: AVAudioPlayerNode?
    private var engineWarmupBuffer: AVAudioPCMBuffer?
    private var metronomeBeat: Int = 0
    private var metronomeNextSampleTime: AVAudioFramePosition = 0
    private var metronomeIntervalFrames: AVAudioFramePosition = 0
    private var metronomeGeneration = 0
    private var playbackRetryTask: Task<Void, Never>?
    private var startPlaybackTask: Task<Void, Never>?
    private var lastPlaybackReadinessDiagnostic: String?
    private var recordingFinalizationTask: Task<Void, Never>?

    private var masterPluginLatency: Double {
        masterPluginNodes
            .compactMap { ($0 as? AVAudioUnit)?.auAudioUnit.latency }
            .filter { $0.isFinite && $0 > 0.0 }
            .reduce(0.0, +)
    }

    public init(inputDeviceID: AudioDeviceID = 0, outputDeviceID: AudioDeviceID = 0) {
        self.recordingsDirectory = Self.resolveRecordingsDirectory()
        super.init()
        if inputDeviceID != 0 || outputDeviceID != 0 {
            bindIODevice(inputDeviceID: inputDeviceID, outputDeviceID: outputDeviceID)
        }
        setupEngine()
        startMeterTimer()
        loadMonitor.start(engine: engine)
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.noteGraphEvent("AVAudioEngineConfigurationChange") }
        }
        // プラグインウィンドウは .floating レベルを使用するため、
        // メインウィンドウのアクティブ化に応じて orderFront する処理は不要になった。
    }

    private static func resolveRecordingsDirectory() -> URL {
        let fm = FileManager.default

        if let savedPath = UserDefaults.standard.string(forKey: "MyDAW.recordingsDirectory") {
            let savedURL = URL(fileURLWithPath: savedPath)
            var isSavedDirectory: ObjCBool = false
            if fm.fileExists(atPath: savedURL.path, isDirectory: &isSavedDirectory), isSavedDirectory.boolValue {
                return savedURL
            }
        }

        // 1. Check relative to app bundle inside project (e.g. MyDAW.app is at <project>/build/MyDAW.app)
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        let bundleParent = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let projectRecordings = bundleParent.appendingPathComponent("Recordings")
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: projectRecordings.path, isDirectory: &isDir), isDir.boolValue {
            return projectRecordings
        }

        // 2. Check current directory
        let cwdRecordings = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Recordings")
        if cwdRecordings.path != "/Recordings" {
            if (try? fm.createDirectory(at: cwdRecordings, withIntermediateDirectories: true)) != nil {
                return cwdRecordings
            }
        }

        // 3. User Music Directory fallback (~/Music/MyDAW/Recordings)
        let music = fm.urls(for: .musicDirectory, in: .userDomainMask).first ?? fm.homeDirectoryForCurrentUser
        let userRecordings = music.appendingPathComponent("MyDAW/Recordings")
        try? fm.createDirectory(at: userRecordings, withIntermediateDirectories: true)
        return userRecordings
    }

    public func revealRecordingsFolder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: recordingsDirectory.path)
    }

    public func chooseRecordingsDirectory() -> Bool {
        guard !isPlaying && !isRecording else { return false }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Recordings Folder")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = recordingsDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return setRecordingsDirectory(url)
    }

    @discardableResult
    public func setRecordingsDirectory(_ url: URL) -> Bool {
        guard !isPlaying && !isRecording else { return false }
        let standardizedURL = url.standardizedFileURL
        do {
            try FileManager.default.createDirectory(at: standardizedURL, withIntermediateDirectories: true)
            recordingsDirectory = standardizedURL
            UserDefaults.standard.set(standardizedURL.path, forKey: "MyDAW.recordingsDirectory")
            return true
        } catch {
            print("Failed to set recordings directory: \(error)")
            return false
        }
    }

    // MARK: - Engine Initialization

    private func setupEngine() {
        noteGraphEvent("setupEngine")
        let mixer = engine.mainMixerNode
        mixer.outputVolume = 1.0

        let inputNode = engine.inputNode
        let inputOutputFormat = inputNode.outputFormat(forBus: 0)
        let inputBusFormat = inputNode.inputFormat(forBus: 0)
        let inputFormat = inputBusFormat.channelCount >= inputOutputFormat.channelCount
            ? inputBusFormat
            : inputOutputFormat
        let hwChannels = max(1, Int(inputFormat.channelCount))
        self.inputHardwareChannels = hwChannels

        // CRITICAL FIX: Always use the actual hardware sample rate.
        // This prevents pitch shift caused by recording at 44100 Hz while the WAV header says 48000 Hz.
        // An input device with no channels (a Mac without a microphone and
        // no interface) gives a format with no channels and no rate; the
        // engine raises an exception when such a format is tapped or
        // connected, so input is then left out.
        let hasInput = inputFormat.channelCount > 0 && inputFormat.sampleRate > 0
        let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let hwSampleRate = hasInput ? inputFormat.sampleRate : (outputRate > 0 ? outputRate : 44100.0)
        self.hardwareSampleRate = hwSampleRate
        self.sampleRate = hwSampleRate

        let masterNode = AVAudioMixerNode()
        engine.attach(masterNode)
        masterOutputNode = masterNode
        if let masterFormat = AVAudioFormat(standardFormatWithSampleRate: hwSampleRate, channels: 2) {
            let meterNode: AVAudioMixerNode
            if let existing = masterMeterNode {
                meterNode = existing
                meterNode.removeTap(onBus: 0)
                engine.disconnectNodeInput(meterNode)
                engine.disconnectNodeOutput(meterNode)
            } else {
                meterNode = AVAudioMixerNode()
                engine.attach(meterNode)
                masterMeterNode = meterNode
            }
            engine.disconnectNodeOutput(mixer)
            engine.connect(mixer, to: masterNode, format: masterFormat)
            engine.connect(masterNode, to: meterNode, format: masterFormat)
            engine.connect(meterNode, to: engine.outputNode, format: masterFormat)
            masterNode.outputVolume = masterVolume

            mixer.removeTap(onBus: 0)
            meterNode.installTap(onBus: 0, bufferSize: 512, format: masterFormat) { [weak self] buffer, _ in
                let peak = StereoPeak(buffer: buffer)
                self?.peakLock.withLock {
                    self?.masterOutputPeak = (self?.masterOutputPeak ?? .zero).merged(with: peak)
                    self?.masterTapCallbackCount &+= 1
                }
            }
        }

        let clickFormat = AVAudioFormat(
            standardFormatWithSampleRate: hwSampleRate,
            channels: 2
        )
          if clickNode == nil,
              let clickFormat,
           let buffer = Self.makeClickBuffer(format: clickFormat, frequency: 1200.0, amplitude: 0.22),
           let accentBuffer = Self.makeClickBuffer(format: clickFormat, frequency: 1800.0, amplitude: 0.42) {
            let node = AVAudioPlayerNode()
                        let clickMixer = AVAudioMixerNode()
            engine.attach(node)
                        engine.attach(clickMixer)
                        engine.connect(node, to: clickMixer, format: clickFormat)
                        engine.connect(clickMixer, to: mixer, format: clickFormat)
            clickNode = node
                        clickMixerNode = clickMixer
            clickBuffer = buffer
            accentClickBuffer = accentBuffer
                        clickMixer.outputVolume = Float(metronomeVolume)
        }

        inputCaptureFormat = hasInput ? inputFormat : nil
        connectInputMonitors()

        // Install tap BEFORE engine.start()
        inputNode.removeTap(onBus: 0)
        if hasInput {
            inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(inputBufferFrameSize), format: inputFormat) { [weak self] (buffer, time) in
                self?.processInputAudioBuffer(buffer: buffer, time: time)
            }
        }

        raiseMaximumFramesPerSlice()
        do {
            try engine.start()
            self.isAudioInputActive = true
            updateHardwareLatencyInfo()
            updateEstimatedRecordingLatency()
            warmUpAudioRenderPath(format: clickFormat)
                print(
                    "AVAudioEngine started. Input format: \(inputFormat). " +
                        "Output format: \(inputOutputFormat). Input bus format: \(inputBusFormat). " +
                        "Hardware SR: \(hwSampleRate) Hz"
                )
        } catch {
            print("Failed to start AVAudioEngine: \(error)")
            self.isAudioInputActive = false
        }
    }

    private func warmUpAudioRenderPath(format: AVAudioFormat?) {
        guard let format else { return }

        if engineWarmupNode == nil {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            engineWarmupNode = node
        }

        guard let node = engineWarmupNode,
              let buffer = Self.makeSilentBuffer(format: format, duration: 0.15) else {
            return
        }
        engineWarmupBuffer = buffer
        hasWarmedUpAudioGraph = false
        node.stop()
        node.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            Task { @MainActor [weak self] in
                self?.hasWarmedUpAudioGraph = true
                self?.schedulePendingPluginUIRequests()
            }
        }
        node.play()
    }

    private func reconfigureEngine() {
        engine.stop()
        // Re-install tap and re-read hardware sample rate
        setupEngine()
    }

    public func applyInputBufferFrameSize(_ frameCount: Int) {
        inputBufferFrameSize = max(128, min(4096, frameCount))
        guard engine.isRunning else { return }
        engine.stop()
        setupEngine()
    }

    public func setPunchRange(startTime: Double?, endTime: Double?, enabled: Bool) {
        // A rollback pass keeps its own punch-in until it stops.
        guard !isRollbackPass else { return }
        punchInTime = enabled ? startTime : nil
        punchOutTime = enabled ? endTime : nil
    }

    /// Primes the hardware render path before restoring an asynchronous AU graph.
    /// Some Audio Units assume that the host has already prepared its output
    /// route, even though AVAudioEngine reports itself as running.
    public func prepareForPluginGraphRestore() {
        guard !isMasterPluginGraphBuilding else { return }
        if !engine.isRunning {
            engine.prepare()
            do {
                try engine.start()
            } catch {
                print("Failed to start audio engine before plugin restore: \(error)")
            }
        }
    }

    public func setSavedPluginStates(_ states: [PluginStateDocument]) {
        savedPluginStates = states.reduce(into: [:]) { result, state in
            result[state.pluginID] = state.stateData
        }
        restoredPluginStateIDs.removeAll()
    }

    public func capturePluginStates() -> [PluginStateDocument] {
        let auStates: [PluginStateDocument] = pluginAudioUnits.compactMap { entry in
            let (pluginID, audioUnit) = entry
            guard !(audioUnit.auAudioUnit is VST3AudioUnit),
                  let state = audioUnit.auAudioUnit.fullStateForDocument else { return nil }
            guard PropertyListSerialization.propertyList(
                state,
                isValidFor: .binary
            ) else {
                print("Skipped non-property-list state for plugin \(pluginID)")
                return nil
            }
            do {
                let data = try PropertyListSerialization.data(
                    fromPropertyList: state,
                    format: .binary,
                    options: 0
                )
                return PluginStateDocument(pluginID: pluginID, stateData: data)
            } catch {
                print("Failed to serialize state for plugin \(pluginID): \(error)")
                return nil
            }
        }

        let vst3States: [PluginStateDocument] = vst3Instances.compactMap { entry in
            let (pluginID, instance) = entry
            guard let stateData = instance.captureState() else { return nil }
            return PluginStateDocument(
                pluginID: pluginID,
                stateData: stateData,
                format: "vst3-state"
            )
        }
        return auStates + vst3States
    }

    /// Gives each copied plug-in (the values) the current state of the one it
    /// was copied from (the keys); it is restored when the copy is built.
    public func copyPluginStates(_ copies: [UUID: UUID]) {
        for (sourceID, copyID) in copies {
            if let data = currentStateData(for: sourceID) {
                savedPluginStates[copyID] = data
            }
        }
    }

    /// A plug-in's state as `capturePluginStates` stores it, or the saved
    /// one when it has no live instance.
    private func currentStateData(for pluginID: UUID) -> Data? {
        if let instance = vst3Instances[pluginID] {
            return instance.captureState() ?? savedPluginStates[pluginID]
        }
        if let audioUnit = pluginAudioUnits[pluginID],
           !(audioUnit.auAudioUnit is VST3AudioUnit),
           let state = audioUnit.auAudioUnit.fullStateForDocument,
           PropertyListSerialization.propertyList(state, isValidFor: .binary),
           let data = try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0) {
            return data
        }
        return savedPluginStates[pluginID]
    }

    private func syncVST3Instances(for descriptors: [TrackPluginDescriptor]) {
        // Instances are kept alive regardless of `enabled` (matching the AU
        // path, which never tears down an AVAudioUnit on bypass). Destroying
        // the instance on disable would drop unsaved plugin state and orphan
        // any open editor window.
        let vst3Descriptors = descriptors.filter { $0.kind == .vst3 }
        let requiredIDs = Set(vst3Descriptors.map(\.id))
        for (pluginID, instance) in vst3Instances where !requiredIDs.contains(pluginID) {
            _ = instance
            vst3Instances.removeValue(forKey: pluginID)
        }

        for descriptor in vst3Descriptors where vst3Instances[descriptor.id] == nil {
            guard let instance = VST3NativeInstance(
                descriptor: descriptor,
                sampleRate: hardwareSampleRate,
                maxFrames: inputBufferFrameSize
            ) else {
                markPluginUnavailable(descriptor.id)
                print("Failed to create VST3 instance: \(descriptor.name)")
                continue
            }
            unavailablePluginIDs.remove(descriptor.id)
            vst3Instances[descriptor.id] = instance
            if let stateData = savedPluginStates[descriptor.id] {
                if instance.restoreState(stateData) {
                    print("Restored VST3 state for plugin \(descriptor.id)")
                } else {
                    print("Failed to restore VST3 state for plugin \(descriptor.id)")
                }
            }
        }
    }

    private func restoreSavedState(for pluginID: UUID, audioUnit: AVAudioUnit) {
        guard !(audioUnit.auAudioUnit is VST3AudioUnit),
              let data = savedPluginStates[pluginID] else { return }
        guard !restoredPluginStateIDs.contains(pluginID) else { return }
        pluginStateRestoreTasks[pluginID]?.cancel()
        pluginStateRestoreTasks[pluginID] = Task { @MainActor [weak self] in
            // Let the running engine render before applying a document state.
            // This avoids racing AU initialization with state restoration.
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let self,
                  !Task.isCancelled,
                  let currentAudioUnit = self.pluginAudioUnits[pluginID],
                  currentAudioUnit === audioUnit else { return }

            if !self.engine.isRunning && !self.isMasterPluginGraphBuilding {
                try? self.engine.start()
            }
            if !audioUnit.auAudioUnit.renderResourcesAllocated {
                try? audioUnit.auAudioUnit.allocateRenderResources()
            }

            let state: [String: Any]? = await Task.detached(priority: .userInitiated) {
                guard let propertyList = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                ) as? [String: Any] else {
                    return nil
                }
                return propertyList
            }.value

            guard let state, !Task.isCancelled else { return }
            print("Restoring saved state for plugin \(pluginID)")
            audioUnit.auAudioUnit.fullStateForDocument = state
            self.restoredPluginStateIDs.insert(pluginID)
            print("Restored saved state for plugin \(pluginID)")
            self.pluginStateRestoreTasks.removeValue(forKey: pluginID)
        }
    }

    private func replacePluginAudioUnit(_ audioUnit: AVAudioUnit, for pluginID: UUID) {
        // A hidden AU window (see windowShouldClose) is dropped with the old
        // unit's view but not shown again.
        let existingWindow = pluginWindows[pluginID]
        let hadPluginWindow = existingWindow?.isVisible == true
        let previousFrame = existingWindow?.frame
        pluginViewControllers.removeValue(forKey: pluginID)
        if existingWindow != nil {
            closePluginWindow(pluginID: pluginID)
        }
        pluginAudioUnits[pluginID] = audioUnit
        if hadPluginWindow {
            if let previousFrame {
                pluginWindowFrames[pluginID] = previousFrame
            }
            openPluginUI(pluginID: pluginID)
        }
    }

    private func retryPendingPluginUIRequest(for pluginID: UUID) {
        guard pendingPluginUIRequests.contains(pluginID) else { return }

        // Wait for the newly attached AU to pass through a render cycle before
        // requesting its view controller.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self,
                  self.pendingPluginUIRequests.remove(pluginID) != nil else { return }
            self.openPluginUI(pluginID: pluginID)
        }
    }

    public func commitBPM(_ value: Double) {
        bpm = max(20.0, min(400.0, value))
    }

    public func applyAudioDevices(
        inputDeviceID: AudioDeviceID,
        outputDeviceID: AudioDeviceID,
        sampleRate: Double? = nil
    ) -> Bool {
        guard !isPlaying && !isRecording else { return false }
        engine.stop()

        var applied = true
        if let sampleRate,
           sampleRate.isFinite,
           sampleRate > 0.0 {
            let deviceIDs = Set([inputDeviceID, outputDeviceID]).filter { $0 != 0 }
            for deviceID in deviceIDs {
                var value = Float64(sampleRate)
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyNominalSampleRate,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                let status = AudioObjectSetPropertyData(
                    deviceID,
                    &address,
                    0,
                    nil,
                    UInt32(MemoryLayout<Float64>.size),
                    &value
                )
                applied = applied && status == noErr
            }
        }

        // Only switch the defaults when the device pair actually changes; the
        // running engine keeps its old devices until MyDAW restarts.
        let devicesChanged = inputDeviceID != selectedInputDeviceID ||
            outputDeviceID != selectedOutputDeviceID
        if devicesChanged && !bindIODevice(inputDeviceID: inputDeviceID, outputDeviceID: outputDeviceID) {
            applied = false
        }
        guard applied else {
            setupEngine()
            return false
        }
        selectedInputDeviceID = inputDeviceID
        selectedOutputDeviceID = outputDeviceID
        setupEngine()
        return true
    }

    /// Points the engine at the given devices by making them the macOS
    /// default input and output. With input in use, AVAudioEngine ignores a
    /// device set on its I/O unit (a private aggregate included) and always
    /// runs on an aggregate of the system default input and output,
    /// so the defaults are the only handle that works. The defaults found at
    /// launch are put back by `shutdown()`. Call before the engine first
    /// starts; a change while running takes effect after a restart.
    @discardableResult
    private func bindIODevice(inputDeviceID: AudioDeviceID, outputDeviceID: AudioDeviceID) -> Bool {
        if originalDefaultDevices == nil {
            originalDefaultDevices = (
                Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice),
                Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
            )
        }
        var succeeded = true
        if inputDeviceID != 0 {
            succeeded = Self.setDefaultDevice(kAudioHardwarePropertyDefaultInputDevice, to: inputDeviceID) && succeeded
        }
        if outputDeviceID != 0 {
            succeeded = Self.setDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice, to: outputDeviceID) && succeeded
        }
        guard succeeded else { return false }
        selectedInputDeviceID = inputDeviceID
        selectedOutputDeviceID = outputDeviceID
        return true
    }

    /// Puts back the macOS default devices MyDAW replaced at launch.
    private func restoreOriginalDefaultDevices() {
        guard let original = originalDefaultDevices else { return }
        if original.input != 0 {
            Self.setDefaultDevice(kAudioHardwarePropertyDefaultInputDevice, to: original.input)
        }
        if original.output != 0 {
            Self.setDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice, to: original.output)
        }
        originalDefaultDevices = nil
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return deviceID
    }

    @discardableResult
    private static func setDefaultDevice(_ selector: AudioObjectPropertySelector, to deviceID: AudioDeviceID) -> Bool {
        var value = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &value
        )
        if status != noErr {
            print("Failed to set default audio device \(deviceID): \(status)")
        }
        return status == noErr
    }

    private func updateEstimatedRecordingLatency() {
        let inputLatency = max(0.0, engine.inputNode.presentationLatency)
        let outputLatency = max(0.0, engine.outputNode.presentationLatency)
        let bufferLatency = Double(inputBufferFrameSize) / max(1.0, hardwareSampleRate)
        estimatedRecordingLatencyMs = (inputLatency + outputLatency + bufferLatency) * 1000.0
    }

    private func updateHardwareLatencyInfo() {
        inputDeviceLatencyFrames = readDeviceFrameProperty(
            kAudioDevicePropertyLatency,
            deviceID: selectedInputDeviceID,
            scope: kAudioDevicePropertyScopeInput
        )
        outputDeviceLatencyFrames = readDeviceFrameProperty(
            kAudioDevicePropertyLatency,
            deviceID: selectedOutputDeviceID,
            scope: kAudioDevicePropertyScopeOutput
        )
        inputSafetyOffsetFrames = readDeviceFrameProperty(
            kAudioDevicePropertySafetyOffset,
            deviceID: selectedInputDeviceID,
            scope: kAudioDevicePropertyScopeInput
        )
        outputSafetyOffsetFrames = readDeviceFrameProperty(
            kAudioDevicePropertySafetyOffset,
            deviceID: selectedOutputDeviceID,
            scope: kAudioDevicePropertyScopeOutput
        )
    }

    private func readDeviceFrameProperty(
        _ selector: AudioObjectPropertySelector,
        deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> UInt32 {
        guard deviceID != 0 else { return 0 }
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &value
        )
        return status == noErr ? value : 0
    }

    public func applyAutomaticTimingCompensation() {
        updateEstimatedRecordingLatency()
        manualRecordingCompensationMs = 0.0
        metronomeTimingOffsetMs = 0.0
    }

    private var recordingLatencyCompensation: Double {
        let totalMilliseconds = estimatedRecordingLatencyMs + manualRecordingCompensationMs
        guard totalMilliseconds.isFinite else { return 0.0 }
        return min(5.0, max(-5.0, totalMilliseconds / 1000.0))
    }

    private var recordingPlacementCompensation: Double {
        recordingLatencyCompensation + masterPluginLatency
    }

    private static func makeClickBuffer(
        format: AVAudioFormat,
        frequency: Double,
        amplitude: Double
    ) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(format.sampleRate * 0.045)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = frameCount
        for frame in 0..<Int(frameCount) {
            let progress = Double(frame) / Double(frameCount)
            let time = Double(frame) / format.sampleRate
            let envelope = 1.0 - progress
            let value = Float(sin(time * .pi * 2.0 * frequency) * envelope * amplitude)
            for channel in 0..<Int(format.channelCount) {
                channels[channel][frame] = value
            }
        }
        return buffer
    }

    private static func makeSilentBuffer(
        format: AVAudioFormat,
        duration: Double
    ) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(max(1.0, format.sampleRate * duration))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = frameCount
        for channel in 0..<Int(format.channelCount) {
            channels[channel].initialize(repeating: 0.0, count: Int(frameCount))
        }
        return buffer
    }

    private func startMetronome(at sharedStartTime: AVAudioTime? = nil) {
        stopMetronome()
        guard metronomeEnabled,
              let clickNode,
              let clickBuffer,
              let accentClickBuffer else { return }

        let interval = 60.0 / max(20.0, min(400.0, bpm))
        // With the transport starting, its start time and position are given.
        // Switched on (or re-armed) while it runs, the clicks start at the
        // next moment a player can start without losing its opening, at the
        // position the transport clock has then: the on-screen playhead lags.
        let transportStartTime: AVAudioTime
        let startPosition: Double
        if let sharedStartTime {
            transportStartTime = sharedStartTime
            startPosition = currentTime
        } else {
            let hostTime = earliestPlayerStartHostTime()
            transportStartTime = AVAudioTime(hostTime: hostTime)
            startPosition = transportPosition(atHostTime: hostTime) ?? currentTime
        }
        let beatPosition = startPosition / interval
        let nearestBeat = round(beatPosition)
        let isOnBeat = abs(beatPosition - nearestBeat) < 0.0001
        let nextBeatPosition = isOnBeat ? nearestBeat : ceil(beatPosition)
        let timingOffset = metronomeTimingOffsetMs / 1000.0
        let delay = max(0.0, (nextBeatPosition * interval) - startPosition + timingOffset)
        metronomeBeat = Int(nextBeatPosition) % 4
        metronomeGeneration += 1
        let generation = metronomeGeneration

        let beatCount = 256
        for beatIndex in 0..<beatCount {
            let buffer = ((metronomeBeat + beatIndex) % 4 == 0) ? accentClickBuffer : clickBuffer
            let offset = delay + Double(beatIndex) * interval
            let hostTime = transportStartTime.hostTime + AudioConvertNanosToHostTime(
                UInt64(max(0.0, offset) * 1_000_000_000.0)
            )
            let clickTime = AVAudioTime(hostTime: hostTime)
            if beatIndex == beatCount - 1 {
                clickNode.scheduleBuffer(buffer, at: clickTime, options: []) { [weak self] in
                    Task<Void, Never> { @MainActor [weak self] in
                        guard let self,
                              generation == self.metronomeGeneration,
                              self.isPlaying || self.isRecording else { return }
                        self.startMetronome()
                    }
                }
            } else {
                clickNode.scheduleBuffer(buffer, at: clickTime, options: [])
            }
        }
        clickNode.play(at: transportStartTime)
    }

    private func stopMetronome() {
        metronomeGeneration += 1
        clickNode?.stop()
    }

    // MARK: - Real-time Input Processing (Audio Thread)

    private func processInputAudioBuffer(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        if frameLength == 0 { return }

        let format = buffer.format
        let hwChannels = Int(format.channelCount)

        // 1. Compute peak level for each hardware channel
        var currentBufferPeaks = [Float](repeating: 0.0, count: max(hwChannels, 8))
        for ch in 0..<hwChannels {
            let samples = channelData[ch]
            var peak: Float = 0.0
            for i in 0..<frameLength {
                let absVal = abs(samples[i])
                if absVal > peak { peak = absVal }
            }
            currentBufferPeaks[ch] = peak
        }

        // Store peaks for UI meter timer
        peakLock.lock()
        for ch in 0..<min(hwChannels, rawChannelPeaks.count) {
            rawChannelPeaks[ch] = max(rawChannelPeaks[ch], currentBufferPeaks[ch])
        }
        peakLock.unlock()

        // 2. Check if recording is active
        captureLock.lock()
        let isRec = self.recordingActiveState
        let configs = self.captureConfigs
        let writers = self.writersSnapshot
        captureLock.unlock()

        guard isRec, !configs.isEmpty else { return }

        // Timeline position of this buffer's first sample. Input taps
        // deliver ~100 ms buffers, so the first one usually starts before the
        // transport did; it must be trimmed to the start sample, not written
        // whole, or the take lands late by that pre-roll. Punch takes record
        // the whole pass too; they are trimmed to the punch range on stop.
        let (bufferStartPosition, timelineStart): (Double?, Double) = recordingTimingLock.withLock {
            guard let transportHostTime = recordingTransportStartHostTime,
                  time.isHostTimeValid else { return (nil, recordingTimelineStart) }
            let deltaNanos = time.hostTime >= transportHostTime
                ? Double(AudioConvertHostTimeToNanos(time.hostTime - transportHostTime))
                : -Double(AudioConvertHostTimeToNanos(transportHostTime - time.hostTime))
            return (recordingTimelineStart + deltaNanos / 1_000_000_000.0, recordingTimelineStart)
        }
        var inputFrameOffset = 0
        var capturedFrameLength = frameLength
        if let bufferStartPosition {
            let sampleRate = format.sampleRate
            let skip = Int(((timelineStart - bufferStartPosition) * sampleRate).rounded())
            inputFrameOffset = min(frameLength, max(0, skip))
            capturedFrameLength = frameLength - inputFrameOffset
            guard capturedFrameLength > 0 else { return }
        }

        var firstInputLog: String?
        recordingTimingLock.lock()
        if !hasLoggedFirstRecordingInput {
            hasLoggedFirstRecordingInput = true
            let hostDeltaMs: Double
            if let transportHostTime = recordingTransportStartHostTime,
               time.isHostTimeValid {
                let deltaNanos: Int64
                if time.hostTime >= transportHostTime {
                    deltaNanos = Int64(AudioConvertHostTimeToNanos(time.hostTime - transportHostTime))
                } else {
                    deltaNanos = -Int64(AudioConvertHostTimeToNanos(transportHostTime - time.hostTime))
                }
                hostDeltaMs = Double(deltaNanos) / 1_000_000.0
            } else {
                hostDeltaMs = .nan
            }
            firstInputLog = String(
                format: "[Timing] first input buffer: hostDelta=%.3f ms, sampleTime=%@, frames=%d, sampleRate=%.1f",
                hostDeltaMs,
                time.isSampleTimeValid ? String(format: "%.0f", time.sampleTime) : "invalid",
                frameLength,
                format.sampleRate
            )
        }
        recordingTimingLock.unlock()
        if let firstInputLog {
            Task { @MainActor in
                print(firstInputLog)
            }
        }

        // Process armed tracks
        for cfg in configs where cfg.isArmed {
            guard let writer = writers[cfg.trackId] else { continue }

            let chOffset = cfg.channelOffset
            let ch0 = (chOffset < hwChannels) ? chOffset : 0
            let ch1 = (chOffset + 1 < hwChannels) ? (chOffset + 1) : ch0
            let outChannels: AVAudioChannelCount = cfg.isStereo ? 2 : 1

            guard let subFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: format.sampleRate,
                channels: outChannels,
                interleaved: false
            ),
            let trackBuffer = AVAudioPCMBuffer(
                pcmFormat: subFormat,
                frameCapacity: AVAudioFrameCount(capturedFrameLength)
            ) else {
                continue
            }
            trackBuffer.frameLength = AVAudioFrameCount(capturedFrameLength)
            guard let trackData = trackBuffer.floatChannelData else { continue }

            trackData[0].update(
                from: channelData[ch0].advanced(by: inputFrameOffset),
                count: capturedFrameLength
            )
            if cfg.isStereo {
                trackData[1].update(
                    from: channelData[ch1].advanced(by: inputFrameOffset),
                    count: capturedFrameLength
                )
            }

            // Stream directly to disk writer
            writer.write(buffer: trackBuffer)

            // Calculate peak for live waveform
            peakLock.lock()
            if self.liveWaveformPeaksBuffer[cfg.trackId] == nil {
                self.liveWaveformPeaksBuffer[cfg.trackId] = Array(
                    repeating: [],
                    count: Int(outChannels)
                )
            }
            // WaveformCache uses 512 samples per point. Keep live waveform
            // width in sync with the number of captured samples in this buffer.
            let livePointCount = max(1, (capturedFrameLength + 511) / 512)
            for channel in 0..<Int(outChannels) {
                let sourceChannel = channel == 0 ? ch0 : ch1
                let peakVal = currentBufferPeaks[sourceChannel]
                for _ in 0..<livePointCount {
                    self.liveWaveformPeaksBuffer[cfg.trackId]?[channel].append(
                        (min: -peakVal, max: peakVal)
                    )
                }
            }
            peakLock.unlock()
        }
    }

    // MARK: - 60Hz UI Meter & Waveform Timer (MainActor)

    private func startMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }

                self.updatePunchRecordingState()

                let (peaks, livePeaks): ([Float], [UUID: [[(min: Float, max: Float)]]]) = self.peakLock.withLock {
                    let p = self.rawChannelPeaks
                    self.rawChannelPeaks = [Float](repeating: 0.0, count: self.rawChannelPeaks.count)
                    let lp = self.liveWaveformPeaksBuffer
                    self.liveWaveformPeaksBuffer.removeAll(keepingCapacity: true)
                    return (p, lp)
                }

                if let recordingStartTime = self.recordingTimingLock.withLock({
                    let value = self.pendingRecordingClipStartTime
                    self.pendingRecordingClipStartTime = nil
                    return value
                }) {
                    print(
                        String(
                            format: "[Timing] clip position: timelineStart=%.6f, clipStart=%.6f, compensation=%.3f ms",
                            self.recordingTimelineStart,
                            recordingStartTime,
                            self.recordingPlacementCompensation * 1000.0
                        )
                    )
                    for clip in self.activeClips.values {
                        clip.startTime = max(0.0, recordingStartTime)
                    }
                }

                // Update Master Peak from the main mixer output.
                let outputMasterPeak = self.peakLock.withLock {
                    let peak = self.masterOutputPeak
                    self.masterOutputPeak = .zero
                    return peak
                }
                self.masterMeter.update(
                    inputPeak: 0,
                    outputPeak: self.masterStereoPeak.falling(to: outputMasterPeak, by: 0.82)
                )
                let decayedPeak = max(self.masterPeak * 0.85, outputMasterPeak.maximum)
                self.masterPeak = decayedPeak < 1e-5 ? 0 : decayedPeak

                var outputPeaks: [UUID: StereoPeak] = [:]
                var meterCycles: [UUID: Int] = [:]
                for (trackID, meter) in self.trackMeters {
                    let reading = meter.take()
                    outputPeaks[trackID] = reading.peak
                    meterCycles[trackID] = reading.cycles
                }

                let fxPeaks = self.peakLock.withLock {
                    let values = self.fxOutputPeaks
                    self.fxOutputPeaks.removeAll(keepingCapacity: true)
                    return values
                }
                self.checkTrackMeters(cycles: meterCycles)

                // Notify ProjectState to update track input meters
                MyDAWNotificationCenter.shared.post(
                    name: .audioEngineUpdatedPeaks,
                    object: nil,
                    userInfo: [
                        "peaks": peaks,
                        "liveChannelWaveforms": livePeaks,
                        "outputPeaks": outputPeaks,
                        "fxOutputPeaks": fxPeaks
                    ]
                )
            }
        }
    }

    // MARK: - Meter tap watchdog

    /// Track meters stopped at times (all tracks at once, sound still
    /// playing, master and FX meters fine) while they were taps on the track
    /// splitters. They now come from the dry delay units, which render
    /// whenever the track sounds. While the engine renders — the master tap
    /// keeps advancing — every track's unit must render too, silent or not;
    /// one that stays idle for a second is logged once per playback.
    private func checkTrackMeters(cycles: [UUID: Int]) {
        let now = ProcessInfo.processInfo.systemUptime
        let running = engine.isRunning
        if running != wasEngineRunning {
            wasEngineRunning = running
            noteGraphEvent(running ? "engine running" : "engine stopped")
        }
        let masterCount = peakLock.withLock { masterTapCallbackCount }
        if masterCount != lastMasterTapCount {
            lastMasterTapCount = masterCount
            lastMasterTapAdvance = now
        }
        guard isPlaying || isRecording else {
            trackMeterWatch.removeAll()
            trackMeterStallsLogged.removeAll()
            return
        }
        guard running, now - lastMasterTapAdvance < 0.5 else {
            // The engine itself is not rendering: nothing to judge.
            trackMeterWatch.removeAll()
            return
        }
        var stalled: [UUID] = []
        for (trackID, count) in cycles {
            if let watch = trackMeterWatch[trackID], watch.cycles == count {
                if now - watch.since >= 1.0, !trackMeterStallsLogged.contains(trackID) {
                    stalled.append(trackID)
                }
            } else {
                trackMeterWatch[trackID] = (count, now)
            }
        }
        guard !stalled.isEmpty else { return }
        trackMeterStallsLogged.formUnion(stalled)
        writeMeterRecoveryLog(stalled: stalled, cycles: cycles, masterCount: masterCount, now: now)
    }

    private func trackLabel(_ trackID: UUID) -> String {
        "\(meterTrackNames[trackID] ?? "?") [\(trackID.uuidString.prefix(8))]"
    }

    private static let graphEventTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    private func noteGraphEvent(_ text: String) {
        graphEventHistory.append("\(Self.graphEventTimeFormatter.string(from: Date()))  \(text)")
        if graphEventHistory.count > 60 {
            graphEventHistory.removeFirst(graphEventHistory.count - 60)
        }
    }

    /// Appends the state at a recovery to ~/Library/Logs/MyDAW/MeterRecovery.log.
    private func writeMeterRecoveryLog(stalled: [UUID], cycles: [UUID: Int], masterCount: Int, now: TimeInterval) {
        func describe(_ format: AVAudioFormat) -> String {
            "\(Int(format.sampleRate)) Hz \(format.channelCount) ch"
        }
        var lines: [String] = []
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        lines.append("=== \(ISO8601DateFormatter().string(from: Date()))  MyDAW \(version)")
        lines.append("Track meters stalled (dry delay units not rendering): \(stalled.count) of \(trackMeters.count) tracks")
        lines.append("engine running \(engine.isRunning), playing \(isPlaying), recording \(isRecording), hardware \(Int(hardwareSampleRate)) Hz, master tap calls \(masterCount), pending splitter rewires \(pendingSplitterRewires.count)")
        for trackID in trackSplitterNodes.keys.sorted(by: { trackLabel($0) < trackLabel($1) }) {
            guard let splitter = trackSplitterNodes[trackID] else { continue }
            let since = trackMeterWatch[trackID].map { String(format: "%.2f s", now - $0.since) } ?? "-"
            lines.append("  \(stalled.contains(trackID) ? "STALLED" : "ok     ") \(trackLabel(trackID)): render cycles \(cycles[trackID] ?? 0), unchanged for \(since), splitter in \(describe(splitter.inputFormat(forBus: 0))) / out \(describe(splitter.outputFormat(forBus: 0))), attached \(splitter.engine != nil)")
        }
        lines.append("Recent events:")
        lines += graphEventHistory.map { "  " + $0 }
        lines.append("")
        let text = lines.joined(separator: "\n") + "\n"
        print(text)

        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MyDAW", isDirectory: true)
        let url = folder.appendingPathComponent("MeterRecovery.log")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let data = text.data(using: .utf8) else { return }
        // Kept under about 1 MB: past that, the older half is dropped.
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 1_000_000,
           let old = try? Data(contentsOf: url) {
            var kept = old.suffix(500_000)
            // Start at a whole entry.
            if let start = kept.range(of: Data("\n=== ".utf8)) {
                kept = kept[(start.lowerBound + 1)...]
            }
            try? Data(kept).write(to: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: - Track Synchronization

    public func syncTracks(_ tracks: [AudioTrack]) {
        syncFXChannels([])
        syncTracks(tracks, fxChannels: [])
    }

    public func syncTracks(_ tracks: [AudioTrack], fxChannels: [FXChannel]) {
        syncedFXChannels = fxChannels
        syncedTracks = tracks
        meterTrackNames = Dictionary(tracks.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        noteGraphEvent("syncTracks (\(tracks.count) tracks, \(fxChannels.count) FX)")
        let allPlugins = tracks.flatMap(\.plugins) + fxChannels.flatMap(\.plugins) + configuredMasterPlugins
        let activePluginIDs = Set(allPlugins.map(\.id))
        let removedPluginIDs = Set(pluginDescriptors.keys).subtracting(activePluginIDs)
        for pluginID in removedPluginIDs {
            closePluginWindow(pluginID: pluginID)
            pluginViewControllers.removeValue(forKey: pluginID)
            pluginUIRequests.remove(pluginID)
            pendingPluginUIRequests.remove(pluginID)
        }
        unavailablePluginIDs.subtract(removedPluginIDs)
        pluginDescriptors = allPlugins
            .reduce(into: [:]) { descriptors, plugin in
                descriptors[plugin.id] = plugin
            }
        syncVST3Instances(for: allPlugins)
        syncMasterPlugins(configuredMasterPlugins)
        syncFXChannels(fxChannels)
        // Sends stay wired between syncs; only new or retargeted ones are
        // connected below. Rewiring every send on each sync (as this once
        // did) makes AVAudioEngine throw "required condition is false:
        // mixingDest" while input monitoring feeds the live input through
        // those sends.
        wiredSendTargets = wiredSendTargets.filter { _, target in
            fxInputNodes.values.contains { $0 === target }
        }
        let currentTrackIDs = Set(tracks.map { $0.id })
        let currentFXIDs = Set(fxChannels.map(\.id))
        for (key, gainNode) in sendGainNodes
        where !currentTrackIDs.contains(key.trackID) || !currentFXIDs.contains(key.fxChannelID) {
            engine.disconnectNodeOutput(gainNode)
            gainNode.outputVolume = 0
            retiredSendGains[key.trackID, default: []].append(gainNode)
            sendGainNodes.removeValue(forKey: key)
            wiredSendTargets.removeValue(forKey: key)
        }

        for (id, renderer) in trackRenderers where !currentTrackIDs.contains(id) {
            renderer.unregister()
            engine.disconnectNodeOutput(renderer.node)
            engine.detach(renderer.node)
            trackRenderers.removeValue(forKey: id)
            if let outputNode = trackOutputNodes.removeValue(forKey: id) {
                engine.disconnectNodeOutput(outputNode)
                engine.detach(outputNode)
            }
            if let downmixNode = trackDownmixNodes.removeValue(forKey: id) {
                engine.disconnectNodeOutput(downmixNode)
                engine.detach(downmixNode)
            }
            trackPluginLatencies.removeValue(forKey: id)
            trackChainTails.removeValue(forKey: id)
            trackSendFXIDs.removeValue(forKey: id)
            trackMeters.removeValue(forKey: id)
            trackMeterWatch.removeValue(forKey: id)
            trackMeterStallsLogged.remove(id)
            if let splitter = trackSplitterNodes.removeValue(forKey: id) {
                engine.disconnectNodeOutput(splitter)
                engine.detach(splitter)
            }
            for gainNode in retiredSendGains.removeValue(forKey: id) ?? [] {
                safeDetach(gainNode)
            }
            if let panNode = trackPanNodes.removeValue(forKey: id) {
                engine.disconnectNodeOutput(panNode)
                engine.detach(panNode)
            }
            trackPanValues.removeValue(forKey: id)
            trackDryAudible.removeValue(forKey: id)
            if let dryDelay = trackDryDelayNodes.removeValue(forKey: id) {
                engine.disconnectNodeOutput(dryDelay)
                engine.detach(dryDelay)
            }
        }

        for (id, nodes) in trackPluginNodes where !currentTrackIDs.contains(id) {
            for pluginNode in nodes {
                engine.disconnectNodeOutput(pluginNode)
                engine.detach(pluginNode)
            }
            trackPluginNodes.removeValue(forKey: id)
            pluginGraphSignatures.removeValue(forKey: id)
        }

        let currentPluginIDs = Set(tracks.flatMap { $0.plugins.map(\.id) })
        let currentFXPluginIDs = Set(fxChannels.flatMap { $0.plugins.map(\.id) })
        pluginAudioUnits = pluginAudioUnits.filter {
            currentPluginIDs.contains($0.key) ||
                currentFXPluginIDs.contains($0.key) ||
                masterPluginIDs.contains($0.key)
        }

        let audible = audibility(tracks: tracks, fxChannels: fxChannels)

        for track in tracks {
            guard let format = AVAudioFormat(
                standardFormatWithSampleRate: hardwareSampleRate,
                channels: 2
            ) else {
                continue
            }

            let outputNode: AVAudioMixerNode
            if let existing = trackOutputNodes[track.id] {
                outputNode = existing
            } else {
                outputNode = AVAudioMixerNode()
                engine.attach(outputNode)
                trackOutputNodes[track.id] = outputNode
            }
            // A renderer works at one sample rate; a new rate gets a new one.
            if let existing = trackRenderers[track.id], existing.sampleRate != hardwareSampleRate {
                existing.unregister()
                engine.disconnectNodeOutput(existing.node)
                engine.detach(existing.node)
                trackRenderers.removeValue(forKey: track.id)
            }
            if trackRenderers[track.id] == nil {
                let renderer = TrackRenderer(sampleRate: hardwareSampleRate)
                engine.attach(renderer.node)
                engine.connect(renderer.node, to: outputNode, fromBus: 0, toBus: 0, format: format)
                trackRenderers[track.id] = renderer
            }
            // The inserts start after the downmix, so a mono track is mono
            // through its whole chain, sends and meters included.
            let downmixNode: AVAudioUnitEffect
            if let existing = trackDownmixNodes[track.id] {
                // Follow a sample-rate change, as the rest of the chain does.
                if existing.inputFormat(forBus: 0) != format && !isPlaying && !isRecording {
                    connectReformatting(outputNode, to: existing, format: format)
                }
                downmixNode = existing
            } else {
                _ = MonoDownmixAudioUnit.registration
                downmixNode = AVAudioUnitEffect(audioComponentDescription: MonoDownmixAudioUnit.componentDescription)
                engine.attach(downmixNode)
                trackDownmixNodes[track.id] = downmixNode
                engine.connect(outputNode, to: downmixNode, format: format)
            }
            (downmixNode.auAudioUnit as? MonoDownmixAudioUnit)?.isMono = track.channelMode == .mono
            let chainHead: AVAudioNode = downmixNode
            // VST3 descriptors are persisted and shown in the mixer, but are
            // bypassed until their native processing host is connected.
            let auPlugins = track.plugins.filter { isChainPlugin($0) }
            let desiredSignature = auPlugins.map(\.id)
            let existingSignature = pluginGraphSignatures[track.id]
            let graphNeedsRebuild = existingSignature != desiredSignature

            if graphNeedsRebuild {
                let previousNodes = trackPluginNodes[track.id] ?? []
                let reusableNodes = auPlugins.compactMap { pluginAudioUnits[$0.id] }
                let canReuseNodes = reusableNodes.count == auPlugins.count &&
                    Set(reusableNodes.map { node in
                        pluginAudioUnits.first(where: { $0.value === node })?.key
                    }.compactMap { $0 }) == Set(desiredSignature)

                if canReuseNodes {
                    let reusableSet = Set(reusableNodes.map { ObjectIdentifier($0) })
                    for pluginNode in previousNodes {
                        safeDisconnectNodeOutput(pluginNode)
                        safeDisconnectNodeInput(pluginNode)
                        // Removed plug-ins must be detached to be released.
                        if !reusableSet.contains(ObjectIdentifier(pluginNode)) {
                            safeDetach(pluginNode)
                        }
                    }
                    safeDisconnectNodeOutput(chainHead)
                    trackPluginNodes[track.id] = reusableNodes
                    reconnectPluginChain(
                        from: chainHead,
                        through: reusableNodes,
                        to: engine.mainMixerNode,
                        format: format
                    )
                    connectTrackChainTail(track.id, from: reusableNodes.last ?? chainHead, format: format)
                    for plugin in auPlugins {
                        if let au = pluginAudioUnits[plugin.id] {
                            setAUBypass(au, bypassed: !plugin.enabled)
                            AudioUnitReset(au.audioUnit, kAudioUnitScope_Global, 0)
                        }
                    }
                    updateLatencyCompensation()
                    pluginGraphSignatures[track.id] = desiredSignature
                } else {
                    for pluginNode in previousNodes {
                        safeDisconnectNodeOutput(pluginNode)
                        safeDisconnectNodeInput(pluginNode)
                        safeDetach(pluginNode)
                    }
                    trackPluginNodes[track.id] = []
                    updateLatencyCompensation()
                    pluginGraphGenerations[track.id, default: 0] += 1
                    let graphGeneration = pluginGraphGenerations[track.id] ?? 0
                    pluginGraphSignatures[track.id] = desiredSignature

                    connectTrackChainTail(track.id, from: chainHead, format: format)
                    if !auPlugins.isEmpty {
                        // The chain is incomplete until installAudioUnits
                        // reaches its end; nothing may re-fan-out the old tail
                        // meanwhile or it would bypass the new inserts.
                        trackChainTails[track.id] = nil
                        installAudioUnits(
                            auPlugins,
                            for: track.id,
                            previousNode: chainHead,
                            format: format,
                            index: 0,
                            generation: graphGeneration
                        )
                    }
                }
            } else {
                for plugin in auPlugins {
                    if let au = pluginAudioUnits[plugin.id] {
                        setAUBypass(au, bypassed: !plugin.enabled)
                    }
                }
                updateLatencyCompensation()
            }

            var sendFXIDs: [UUID] = []
            for channel in fxChannels where fxInputNodes[channel.id] != nil {
                let gainNode = sendGainNode(SendKey(trackID: track.id, fxChannelID: channel.id))
                setMixerVolume(gainNode, sendLevel(of: track, to: channel.id))
                sendFXIDs.append(channel.id)
            }
            trackSendFXIDs[track.id] = sendFXIDs
            if let tail = trackChainTails[track.id] {
                connectTrackChainTail(track.id, from: tail, format: format)
            }

            let effectiveVolume = effectiveTrackVolume(for: track, audible: audible)
            setMixerVolume(outputNode, effectiveVolume)
            setTrackPan(track.id, track.pan)

            trackRenderers[track.id]?.setPlan(TrackPlaybackPlan.make(for: track))
        }

        for track in tracks {
            setTrackDryAudible(track.id, audible.dryTracks.contains(track.id))
        }
        for channel in fxChannels {
            setFXAudible(channel.id, audible.fxChannels.contains(channel.id))
        }

        desiredInputMonitors = tracks.reduce(into: [:]) { result, track in
            guard track.isInputMonitoring, track.isRecordArmed else { return }
            result[track.id] = InputMonitorConfig(
                channelOffset: track.inputChannelIndex,
                isStereo: track.channelMode == .stereo
            )
        }
        // While a stop is still waiting for effect tails to fade, leave the
        // rewiring to that wait instead of cutting the tails now.
        if isWaitingForQuietRewire {
            applyDeferredRewiresWhenQuiet()
        } else {
            applyInputMonitoringIfNeeded()
        }

        let newConfigs = tracks.map { track in
            TrackCaptureConfig(
                trackId: track.id,
                isArmed: track.isRecordArmed,
                channelOffset: track.inputChannelIndex,
                isStereo: track.channelMode == .stereo
            )
        }

        captureLock.withLock {
            self.captureConfigs = newConfigs
        }
    }

    /// During playback the renderers re-read the blocks ahead with the new
    /// clips, so nothing needs restarting.
    public func syncAfterClipEdit(_ tracks: [AudioTrack], fxChannels: [FXChannel] = []) {
        syncTracks(tracks, fxChannels: fxChannels)
    }

    public func updateMixerLevels(
        tracks: [AudioTrack],
        fxChannels: [FXChannel]
    ) {
        let audible = audibility(tracks: tracks, fxChannels: fxChannels)
        for track in tracks {
            let level = effectiveTrackVolume(for: track, audible: audible)
            trackOutputNodes[track.id].map { setMixerVolume($0, level) }
            setTrackDryAudible(track.id, audible.dryTracks.contains(track.id))
            setTrackPan(track.id, track.pan)
            trackRenderers[track.id]?.setMuted(recordingMutedTrackIDs.contains(track.id))

            for (key, gainNode) in sendGainNodes where key.trackID == track.id {
                setMixerVolume(gainNode, sendLevel(of: track, to: key.fxChannelID))
            }
        }

        for channel in fxChannels {
            fxInputNodes[channel.id].map { setMixerVolume($0, channel.volume) }
            fxPanNodes[channel.id]?.pan = channel.pan
            setFXAudible(channel.id, audible.fxChannels.contains(channel.id))
        }
    }

    /// The clip's `isMuted` is already set; its track's renderer takes the
    /// new plan (a muted clip also stops masking the clips under it).
    public func setClipMuted(_ clipID: UUID, muted: Bool) {
        guard let track = syncedTracks.first(where: { $0.clips.contains { $0.id == clipID } }) else { return }
        trackRenderers[track.id]?.setPlan(TrackPlaybackPlan.make(for: track))
    }

    private func sendLevel(of track: AudioTrack, to fxChannelID: UUID) -> Float {
        guard let send = track.fxSends.first(where: { $0.fxChannelID == fxChannelID }), send.enabled else { return 0.0 }
        return send.level
    }

    private func sendGainNode(_ key: SendKey) -> AVAudioMixerNode {
        if let existing = sendGainNodes[key] { return existing }
        let gainNode = AVAudioMixerNode()
        gainNode.outputVolume = 0.0
        engine.attach(gainNode)
        sendGainNodes[key] = gainNode
        return gainNode
    }

    /// Sets a send's level on its always-wired gain mixer. Returns false when
    /// the track's sends are not built yet, so the caller can sync instead.
    @discardableResult
    public func updateSendLevel(track: AudioTrack, fxChannelID: UUID) -> Bool {
        guard let gainNode = sendGainNodes[SendKey(trackID: track.id, fxChannelID: fxChannelID)] else { return false }
        setMixerVolume(gainNode, sendLevel(of: track, to: fxChannelID))
        return true
    }

    public func syncTracks(
        _ tracks: [AudioTrack],
        fxChannels: [FXChannel],
        masterPlugins: [TrackPluginDescriptor]
    ) {
        configuredMasterPlugins = masterPlugins
        syncTracks(tracks, fxChannels: fxChannels)
    }

    public func syncMasterPlugins(_ plugins: [TrackPluginDescriptor]) {
        let signature = plugins.map(\.id)
        if isMasterPluginGraphBuilding {
            if signature == masterPluginSignature {
                // The in-flight build is already targeting this signature.
                // Just update bypass states on any already instantiated units.
                for plugin in plugins {
                    if let au = pluginAudioUnits[plugin.id] {
                        setAUBypass(au, bypassed: !plugin.enabled)
                    }
                }
                return
            }
            // Signature actually changed while building: invalidate and restart.
            pendingMasterPluginSync = nil
            isMasterPluginGraphBuilding = false
            masterPluginGraphGeneration += 1
            syncMasterPlugins(plugins)
            return
        }

        configuredMasterPlugins = plugins
        masterPluginIDs = Set(plugins.map(\.id))
        for plugin in plugins {
            pluginDescriptors[plugin.id] = plugin
        }
        guard let masterOutputNode,
              let format = AVAudioFormat(standardFormatWithSampleRate: hardwareSampleRate, channels: 2) else { return }

        let auPlugins = plugins.filter { isChainPlugin($0) }

        // If signature matches, just update bypass states
        if signature == masterPluginSignature {
            for plugin in plugins {
                if let au = pluginAudioUnits[plugin.id] {
                    setAUBypass(au, bypassed: !plugin.enabled)
                }
            }
            return
        }

        if plugins.isEmpty {
            let wasEngineRunning = engine.isRunning
            if wasEngineRunning {
                engine.stop()
            }
            for pluginID in masterPluginSignature {
                pluginUIRequests.remove(pluginID)
                pendingPluginUIRequests.remove(pluginID)
                pluginStateRestoreTasks[pluginID]?.cancel()
                pluginStateRestoreTasks.removeValue(forKey: pluginID)
                pluginAudioUnits.removeValue(forKey: pluginID)
                vst3Instances.removeValue(forKey: pluginID)?.removeEditor()
                pluginWindows[pluginID]?.close()
                pluginWindows.removeValue(forKey: pluginID)
            }
            for node in masterPluginNodes {
                safeDisconnectNodeOutput(node)
                safeDisconnectNodeInput(node)
                safeDetach(node)
            }
            masterPluginNodes.removeAll()
            isMasterPluginGraphBuilding = false
            pendingMasterPluginSync = nil
            masterPluginSignature = []
            playbackRetryTask?.cancel()
            playbackRetryTask = nil
            reconnectPluginChain(
                from: masterOutputNode,
                through: [],
                to: masterMeterOutput,
                format: format
            )
            if wasEngineRunning {
                try? engine.start()
            }
            return
        }

        let reusableMasterNodes = auPlugins.compactMap { pluginAudioUnits[$0.id] }
        let canReuseMasterNodes = reusableMasterNodes.count == auPlugins.count

        let removedPluginIDs = Set(masterPluginSignature).subtracting(signature)
        for pluginID in removedPluginIDs {
            pluginUIRequests.remove(pluginID)
            pendingPluginUIRequests.remove(pluginID)
            pluginStateRestoreTasks[pluginID]?.cancel()
            pluginStateRestoreTasks.removeValue(forKey: pluginID)
            pluginAudioUnits.removeValue(forKey: pluginID)
            vst3Instances.removeValue(forKey: pluginID)?.removeEditor()
            pluginWindows[pluginID]?.close()
            pluginWindows.removeValue(forKey: pluginID)
        }

        if canReuseMasterNodes {
            let wasEngineRunning = engine.isRunning
            if wasEngineRunning {
                engine.stop()
            }
            let reusableSet = Set(reusableMasterNodes.map { ObjectIdentifier($0) })
            for node in masterPluginNodes where !reusableSet.contains(ObjectIdentifier(node)) {
                safeDisconnectNodeOutput(node)
                safeDisconnectNodeInput(node)
                safeDetach(node)
            }
            for node in reusableMasterNodes {
                safeDisconnectNodeOutput(node)
                safeDisconnectNodeInput(node)
            }
            masterPluginNodes = reusableMasterNodes
            reconnectPluginChain(
                from: masterOutputNode,
                through: reusableMasterNodes,
                to: masterMeterOutput,
                format: format
            )
            for plugin in plugins {
                if let au = pluginAudioUnits[plugin.id] {
                    setAUBypass(au, bypassed: !plugin.enabled)
                }
            }
            masterPluginSignature = signature
            isMasterPluginGraphBuilding = false
            if wasEngineRunning {
                try? engine.start()
            }
            return
        }

        playbackRetryTask?.cancel()
        playbackRetryTask = nil
        isMasterPluginGraphBuilding = true
        masterPluginSignature = signature
        masterPluginGraphGeneration += 1
        let graphGeneration = masterPluginGraphGeneration
        let wasEngineRunning = engine.isRunning
        if wasEngineRunning {
            engine.stop()
        }
        let currentDesiredIDs = Set(auPlugins.map(\.id))
        for node in masterPluginNodes {
            safeDisconnectNodeOutput(node)
            safeDisconnectNodeInput(node)
            if let pluginID = pluginAudioUnits.first(where: { $0.value === node })?.key,
               !currentDesiredIDs.contains(pluginID) {
                safeDetach(node)
            }
        }
        masterPluginNodes.removeAll()
        if auPlugins.isEmpty {
            connectMasterOutput(from: masterOutputNode, format: format)
            if wasEngineRunning {
                try? engine.start()
            }
            finishMasterPluginGraphBuild()
        } else {
            installMasterAudioUnits(
                auPlugins,
                previousNode: masterOutputNode,
                format: format,
                index: 0,
                generation: graphGeneration,
                resumeEngine: wasEngineRunning
            )
        }
    }

    // VST3s run inside VST3AudioUnit wrappers in the same chains as the AUs,
    // so they are processed in insert order on the render thread.
    private func isChainPlugin(_ plugin: TrackPluginDescriptor) -> Bool {
        switch plugin.kind {
        case .au: return true
        case .vst3: return vst3Instances[plugin.id] != nil
        }
    }

    private func chainComponentDescription(for plugin: TrackPluginDescriptor) -> AudioComponentDescription {
        guard plugin.kind == .vst3 else { return plugin.audioComponentDescription }
        _ = VST3AudioUnit.registration
        return VST3AudioUnit.componentDescription
    }

    private func finishMasterPluginGraphBuild() {
        isMasterPluginGraphBuilding = false
        guard let pendingPlugins = pendingMasterPluginSync else { return }
        pendingMasterPluginSync = nil
        guard pendingPlugins.map(\.id) != masterPluginSignature else { return }
        syncMasterPlugins(pendingPlugins)
    }

    @discardableResult
    public func setPluginEnabled(_ pluginID: UUID, enabled: Bool) -> Bool {
        if var descriptor = pluginDescriptors[pluginID] {
            descriptor.enabled = enabled
            pluginDescriptors[pluginID] = descriptor
        }
        configuredMasterPlugins = configuredMasterPlugins.map { descriptor in
            guard descriptor.id == pluginID else { return descriptor }
            var updated = descriptor
            updated.enabled = enabled
            return updated
        }
        if let au = pluginAudioUnits[pluginID] {
            setAUBypass(au, bypassed: !enabled)
        }
        // A bypassed plug-in still counts its latency (bypass keeps the
        // delay), so toggling it never moves the compensation.

        return pluginAudioUnits[pluginID] != nil || vst3Instances[pluginID] != nil
    }

    private func setAUBypass(_ audioUnit: AVAudioUnit, bypassed: Bool) {
        audioUnit.auAudioUnit.shouldBypassEffect = bypassed
        (audioUnit as? AVAudioUnitEffect)?.bypass = bypassed

        var bypassVal: UInt32 = bypassed ? 1 : 0
        AudioUnitSetProperty(
            audioUnit.audioUnit,
            kAudioUnitProperty_BypassEffect,
            kAudioUnitScope_Global,
            0,
            &bypassVal,
            UInt32(MemoryLayout<UInt32>.size)
        )
    }

    private func connectMasterOutput(from node: AVAudioNode, format: AVAudioFormat) {
        let destination = masterMeterOutput
        if destination !== engine.outputNode {
            safeDisconnectNodeInput(destination)
        }
        safeDisconnectNodeOutput(node)
        connectReformatting(node, to: destination, format: format)
    }

    // An AU whose render resources are allocated refuses a bus format change
    // (-10865 from setFormat, raised as an uncaught exception by connect).
    // That happens when a chain first wired before the device's real format
    // was known is rewired with the real one, and engine.stop() does not
    // release those resources. Release them first so the engine can
    // reinitialize the unit with the new format.
    // A mixer ramps volume changes, but an input bus that is not rendering
    // (a stopped clip player) does not advance the ramp: when it next plays,
    // its first buffer comes out at the old volume. That leaked muted/soloed
    // tracks for one buffer at their first clip. Resetting the mixer after a
    // change completes the ramp immediately.
    private func setMixerVolume(_ mixer: AVAudioMixerNode, _ volume: Float) {
        guard mixer.outputVolume != volume else { return }
        mixer.outputVolume = volume
        mixer.auAudioUnit.reset()
    }

    // A plug-in that cannot take the chain format (a mono-only "(m)" variant
    // on the stereo chain) makes connect raise an uncaught exception from
    // setFormat. Asking the busses first returns that refusal as an error, so
    // such a plug-in is left out of the chain as unavailable instead.
    private nonisolated func acceptsChainFormat(_ audioUnit: AVAudioUnit, format: AVAudioFormat, name: String) -> Bool {
        let unit = audioUnit.auAudioUnit
        do {
            for busses in [unit.inputBusses, unit.outputBusses] where busses.count > 0 {
                // A unit may report the chain format as its default and still
                // refuse it, so a unit without render resources is always asked.
                let current = busses[0].format
                if !unit.renderResourcesAllocated
                    || current.sampleRate != format.sampleRate
                    || current.channelCount != format.channelCount {
                    try busses[0].setFormat(format)
                }
            }
            return true
        } catch {
            print("Plug-in \(name) does not support \(format.channelCount) ch at \(format.sampleRate) Hz: \(error)")
            return false
        }
    }

    private func connectReformatting(_ source: AVAudioNode, to destination: AVAudioNode, format: AVAudioFormat) {
        let needsRelease: (AVAudioNode) -> AUAudioUnit? = { node in
            guard let unit = (node as? AVAudioUnit)?.auAudioUnit, unit.renderResourcesAllocated else { return nil }
            let differs: (AUAudioUnitBusArray) -> Bool = { busses in
                guard busses.count > 0 else { return false }
                let current = busses[0].format
                return current.sampleRate != format.sampleRate || current.channelCount != format.channelCount
            }
            return differs(unit.inputBusses) || differs(unit.outputBusses) ? unit : nil
        }
        let units = [needsRelease(source), needsRelease(destination)].compactMap { $0 }
        let restart = !units.isEmpty && engine.isRunning
        if restart {
            noteGraphEvent("connectReformatting restarts the engine")
            engine.stop()
        }
        units.forEach { $0.deallocateRenderResources() }
        let accepted = [source, destination].allSatisfy { node in
            guard let audioUnit = node as? AVAudioUnit else { return true }
            // Not AVAudioUnit.name: it splits the component name at ": " and
            // raises an uncaught exception for a name without a vendor part.
            let name = audioUnit.auAudioUnit.audioUnitName ?? "Audio Unit"
            return acceptsChainFormat(audioUnit, format: format, name: name)
        }
        if accepted {
            engine.connect(source, to: destination, format: format)
        }
        if restart {
            try? engine.start()
        }
    }

    private func reconnectPluginChain(
        from source: AVAudioNode,
        through pluginNodes: [AVAudioNode],
        to destination: AVAudioNode,
        format: AVAudioFormat
    ) {
        safeDisconnectNodeOutput(source)
        for pluginNode in pluginNodes {
            safeDisconnectNodeOutput(pluginNode)
            safeDisconnectNodeInput(pluginNode)
        }
        if destination !== engine.mainMixerNode && destination !== engine.outputNode {
            safeDisconnectNodeInput(destination)
        }

        var previousNode = source
        for pluginNode in pluginNodes {
            connectReformatting(previousNode, to: pluginNode, format: format)
            previousNode = pluginNode
        }
        connectReformatting(previousNode, to: destination, format: format)
    }

    private func installMasterAudioUnits(
        _ plugins: [TrackPluginDescriptor],
        previousNode: AVAudioNode,
        format: AVAudioFormat,
        index: Int,
        generation: Int,
        resumeEngine: Bool = false
    ) {
        guard index < plugins.count else { return }
        let plugin = plugins[index]

        // Reuse existing AU instance if already instantiated
        if let existingAU = pluginAudioUnits[plugin.id] {
            if !masterPluginNodes.contains(where: { $0 === existingAU }) {
                masterPluginNodes.append(existingAU)
            }
            if !engine.attachedNodes.contains(existingAU) {
                engine.attach(existingAU)
            }
            safeDisconnectNodeOutput(previousNode)
            safeDisconnectNodeInput(existingAU)
            connectReformatting(previousNode, to: existingAU, format: format)
            setAUBypass(existingAU, bypassed: !plugin.enabled)

            if index + 1 < plugins.count {
                installMasterAudioUnits(
                    plugins,
                    previousNode: existingAU,
                    format: format,
                    index: index + 1,
                    generation: generation,
                    resumeEngine: resumeEngine
                )
            } else {
                connectMasterOutput(from: existingAU, format: format)
                if resumeEngine && !engine.isRunning {
                    try? engine.start()
                }
                finishMasterPluginGraphBuild()
            }
            return
        }

        // New plugin instantiation:
        let isVST3 = plugin.kind == .vst3
        if isVST3 {
            _ = VST3AudioUnit.registration
        }
        let componentDescription = isVST3 ? VST3AudioUnit.componentDescription : plugin.audioComponentDescription
        let pluginName = plugin.name
        let pluginID = plugin.id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            AVAudioUnit.instantiate(with: componentDescription, options: []) { instantiatedUnit, error in
                guard let self else { return }
                DispatchQueue.main.async {
                    guard self.masterPluginGraphGeneration == generation else {
                        return
                    }
                    var audioUnit = instantiatedUnit
                    if isVST3 {
                        if let wrapper = audioUnit?.auAudioUnit as? VST3AudioUnit,
                           let instance = self.vst3Instances[pluginID] {
                            wrapper.attach(instance)
                        } else {
                            audioUnit = nil
                        }
                    }
                    audioUnit = audioUnit.flatMap {
                        self.acceptsChainFormat($0, format: format, name: pluginName) ? $0 : nil
                    }
                    guard let audioUnit else {
                        self.markPluginUnavailable(pluginID)
                        if let error {
                            print("Failed to create master AU \(pluginName): \(error)")
                        } else {
                            print("Failed to create master AU \(pluginName): unknown error")
                        }
                        if index + 1 < plugins.count {
                            self.installMasterAudioUnits(
                                plugins,
                                previousNode: previousNode,
                                format: format,
                                index: index + 1,
                                generation: generation,
                                resumeEngine: resumeEngine
                            )
                        } else {
                            self.connectMasterOutput(from: previousNode, format: format)
                            if !self.engine.isRunning {
                                try? self.engine.start()
                            }
                            self.finishMasterPluginGraphBuild()
                        }
                        return
                    }

                    if self.engine.isRunning {
                        self.engine.stop()
                    }
                    self.safeDisconnectNodeOutput(previousNode)
                    if !self.engine.attachedNodes.contains(audioUnit) {
                        self.engine.attach(audioUnit)
                    }
                    self.safeDisconnectNodeInput(audioUnit)
                    self.unavailablePluginIDs.remove(pluginID)
                    self.connectReformatting(previousNode, to: audioUnit, format: format)
                    self.setAUBypass(audioUnit, bypassed: !plugin.enabled)
                    self.restoreSavedState(for: pluginID, audioUnit: audioUnit)
                    self.masterPluginNodes.append(audioUnit)
                    self.replacePluginAudioUnit(audioUnit, for: pluginID)
                    self.retryPendingPluginUIRequest(for: pluginID)
                    if index + 1 < plugins.count {
                        self.installMasterAudioUnits(
                            plugins,
                            previousNode: audioUnit,
                            format: format,
                            index: index + 1,
                            generation: generation,
                            resumeEngine: resumeEngine
                        )
                    } else {
                        self.connectMasterOutput(from: audioUnit, format: format)
                        if !self.engine.isRunning {
                            try? self.engine.start()
                        }
                        self.finishMasterPluginGraphBuild()
                    }
                }
            }
        }
    }

    /// Tracks and FX channels heard under the current mute and solo.
    /// Soloing a track keeps the FX channels it sends to. Soloing an FX
    /// channel plays only its return: the tracks that send to it keep feeding
    /// their sends (`tracks`) but their dry sound is off (`dryTracks`).
    private struct Audibility {
        var tracks: Set<UUID> = []
        var dryTracks: Set<UUID> = []
        var fxChannels: Set<UUID> = []
    }

    private func audibility(tracks: [AudioTrack], fxChannels: [FXChannel]) -> Audibility {
        let soloedFX = Set(fxChannels.filter(\.isSoloed).map(\.id))
        let soloActive = !soloedFX.isEmpty || tracks.contains { $0.effectiveSoloed }
        let sendsTo: (AudioTrack, UUID) -> Bool = { track, fxID in
            track.fxSends.contains { $0.fxChannelID == fxID && $0.enabled && $0.level > 0 }
        }
        var result = Audibility()
        for track in tracks where !track.effectiveMuted {
            if !soloActive || track.effectiveSoloed {
                result.tracks.insert(track.id)
                result.dryTracks.insert(track.id)
            } else if soloedFX.contains(where: { sendsTo(track, $0) }) {
                result.tracks.insert(track.id)
            }
        }
        for channel in fxChannels where !channel.isMuted {
            if !soloActive || channel.isSoloed ||
                tracks.contains(where: { $0.effectiveSoloed && !$0.effectiveMuted && sendsTo($0, channel.id) }) {
                result.fxChannels.insert(channel.id)
            }
        }
        return result
    }

    private func effectiveTrackVolume(for track: AudioTrack, audible: Audibility) -> Float {
        audible.tracks.contains(track.id) ? track.volume : 0.0
    }

    // MARK: - Latency compensation

    /// Recomputes plug-in latencies and sets the compensation: each track's
    /// pre-roll is its own inserts' latency plus D, the largest FX channel
    /// latency; its dry path is delayed by D and each FX return by D minus its
    /// own latency, so dry and wet line up with the timeline. Bypassed
    /// plug-ins count (bypass keeps their delay), and so does every FX
    /// channel, fed or not, so mute, solo and bypass never move it.
    /// A change during playback moves the renderers' timelines to match.
    private func updateLatencyCompensation() {
        func latency(of nodes: [AVAudioNode]) -> Double {
            nodes.compactMap { ($0 as? AVAudioUnit)?.auAudioUnit.latency }
                .filter { $0.isFinite && $0 > 0.0 }
                .reduce(0.0, +)
        }
        var trackLatencies: [UUID: Double] = [:]
        for (trackID, nodes) in trackPluginNodes {
            trackLatencies[trackID] = latency(of: nodes)
        }
        var fxLatencies: [UUID: Double] = [:]
        for channelID in fxReturnDelayNodes.keys {
            fxLatencies[channelID] = latency(of: fxPluginNodes[channelID] ?? [])
        }
        let compensation = fxLatencies.values.max() ?? 0.0

        let frames: (Double) -> Int = { [hardwareSampleRate] seconds in
            Int((max(0.0, seconds) * hardwareSampleRate).rounded())
        }
        for node in trackDryDelayNodes.values {
            (node.auAudioUnit as? DelayCompensationAudioUnit)?.delayFrames = frames(compensation)
        }
        for (channelID, node) in fxReturnDelayNodes {
            (node.auAudioUnit as? DelayCompensationAudioUnit)?.delayFrames =
                frames(compensation - (fxLatencies[channelID] ?? 0.0))
        }
        listenForLatencyChanges()

        let tolerance = 0.5 / max(1.0, hardwareSampleRate)
        let trackChanged = Set(trackLatencies.keys).union(trackPluginLatencies.keys).contains {
            abs((trackLatencies[$0] ?? 0.0) - (trackPluginLatencies[$0] ?? 0.0)) > tolerance
        }
        let compensationChanged = abs(compensation - fxCompensationLatency) > tolerance
        trackPluginLatencies = trackLatencies
        fxCompensationLatency = compensation
        transportPreRoll = compensation + (trackLatencies.values.max() ?? 0.0)
        guard trackChanged || compensationChanged else { return }
        print(String(
            format: "[Latency] FX compensation D=%.2f ms; FX: %@; tracks: %@",
            compensation * 1000.0,
            fxLatencies.values.map { String(format: "%.2f", $0 * 1000.0) }.joined(separator: ", "),
            trackLatencies.values.map { String(format: "%.2f", $0 * 1000.0) }.joined(separator: ", ")
        ))
        if isPlaying {
            updateRendererAnchors()
        }
    }

    /// Keeps a latency listener on every track and FX plug-in, so a plug-in
    /// that changes its latency (a look-ahead setting, say) is compensated.
    private func listenForLatencyChanges() {
        let units = (trackPluginNodes.values.flatMap { $0 } + fxPluginNodes.values.flatMap { $0 })
            .compactMap { $0 as? AVAudioUnit }
        let current = Dictionary(units.map { (ObjectIdentifier($0), $0) }, uniquingKeysWith: { first, _ in first })
        let context = Unmanaged.passUnretained(self).toOpaque()
        for (id, unit) in latencyListenedUnits where current[id] == nil {
            AudioUnitRemovePropertyListenerWithUserData(
                unit.audioUnit, kAudioUnitProperty_Latency, pluginLatencyListener, context
            )
        }
        for (id, unit) in current where latencyListenedUnits[id] == nil {
            AudioUnitAddPropertyListener(unit.audioUnit, kAudioUnitProperty_Latency, pluginLatencyListener, context)
        }
        latencyListenedUnits = current
    }

    private func removeLatencyListeners() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        for unit in latencyListenedUnits.values {
            AudioUnitRemovePropertyListenerWithUserData(
                unit.audioUnit, kAudioUnitProperty_Latency, pluginLatencyListener, context
            )
        }
        latencyListenedUnits.removeAll()
    }

    fileprivate func pluginLatencyDidChange() {
        updateLatencyCompensation()
    }

    /// Mutes the track's dry path only (in its delay unit, before the main
    /// mixer), leaving the sends fed.
    private func setTrackDryAudible(_ trackID: UUID, _ isAudible: Bool) {
        trackDryAudible[trackID] = isAudible
        applyTrackDryMute(trackID)
    }

    private func applyTrackDryMute(_ trackID: UUID) {
        let unit = trackDryDelayNodes[trackID]?.auAudioUnit as? DelayCompensationAudioUnit
        unit?.isMuted = !(trackDryAudible[trackID] ?? true)
    }

    private func makeDelayCompensationNode() -> AVAudioUnitEffect {
        _ = DelayCompensationAudioUnit.registration
        let node = AVAudioUnitEffect(audioComponentDescription: DelayCompensationAudioUnit.componentDescription)
        engine.attach(node)
        return node
    }

    /// Silences an FX channel at its output, after the plug-ins, so muting
    /// cuts its reverb or delay tail at once.
    private func setFXAudible(_ channelID: UUID, _ isAudible: Bool) {
        fxOutputNodes[channelID].map { setMixerVolume($0, isAudible ? 1.0 : 0.0) }
    }

    // Fan-out to main mixer + sends happens only from a per-track mixer, so
    // every plug-in keeps exactly one downstream connection (as before sends
    // were post-insert). Rewiring is skipped when nothing changed, to avoid
    // touching a running graph on every sync.
    private func setTrackPan(_ trackID: UUID, _ pan: Float) {
        trackPanValues[trackID] = pan
        trackRenderers[trackID]?.node.pan = 0
        trackOutputNodes[trackID]?.pan = 0
        trackPanNodes[trackID]?.pan = pan
    }

    private func connectTrackChainTail(_ trackID: UUID, from tail: AVAudioNode, format: AVAudioFormat) {
        trackChainTails[trackID] = tail
        let splitter: AVAudioMixerNode
        if let existing = trackSplitterNodes[trackID] {
            splitter = existing
        } else {
            splitter = AVAudioMixerNode()
            engine.attach(splitter)
            trackSplitterNodes[trackID] = splitter
        }
        let panNode: AVAudioMixerNode
        if let existing = trackPanNodes[trackID] {
            panNode = existing
        } else {
            panNode = AVAudioMixerNode()
            engine.attach(panNode)
            trackPanNodes[trackID] = panNode
        }

        // A stale format (e.g. wired before the device's real sample rate was
        // known) would leave a hidden resampling stage in the path, so the
        // format is part of "up to date", not just the topology.
        let panTargets = engine.outputConnectionPoints(for: panNode, outputBus: 0)
        if panTargets.count != 1 || panTargets.first?.node !== splitter ||
            splitter.inputFormat(forBus: 0) != format {
            safeDisconnectNodeOutput(panNode)
            safeDisconnectNodeInput(splitter)
            engine.connect(panNode, to: splitter, format: format)
        }
        panNode.pan = trackPanValues[trackID] ?? 0
        let tailTargets = engine.outputConnectionPoints(for: tail, outputBus: 0)
        if tailTargets.count != 1 || tailTargets.first?.node !== panNode ||
            panNode.inputFormat(forBus: 0) != format {
            safeDisconnectNodeOutput(tail)
            safeDisconnectNodeInput(panNode)
            connectReformatting(tail, to: panNode, format: format)
        }

        // The dry path reaches the main mixer through the delay unit.
        let dryDelay: AVAudioUnitEffect
        if let existing = trackDryDelayNodes[trackID] {
            dryDelay = existing
        } else {
            dryDelay = makeDelayCompensationNode()
            trackDryDelayNodes[trackID] = dryDelay
            // Metered here: after inserts, fader and pan — what the track sends on.
            let meter = RenderPeakMeter()
            (dryDelay.auAudioUnit as? DelayCompensationAudioUnit)?.meter = meter
            trackMeters[trackID] = meter
            applyTrackDryMute(trackID)
        }
        defer { updateLatencyCompensation() }

        let sends: [(key: SendKey, gain: AVAudioMixerNode, fxInput: AVAudioMixerNode)] =
            (trackSendFXIDs[trackID] ?? []).compactMap { fxID in
                let key = SendKey(trackID: trackID, fxChannelID: fxID)
                guard let gain = sendGainNodes[key], let fxInput = fxInputNodes[fxID] else { return nil }
                return (key, gain, fxInput)
            }
        let sendGains = sends.map(\.gain)
        let sendsReachFX = sends.allSatisfy { send in
            wiredSendTargets[send.key] === send.fxInput &&
                engine.outputConnectionPoints(for: send.gain, outputBus: 0).contains { $0.node === send.fxInput }
        }
        let currentTargets = engine.outputConnectionPoints(for: splitter, outputBus: 0).compactMap(\.node)
        let desiredTargets: [AVAudioNode] = [dryDelay] + sendGains
        let dryReachesMain = engine.outputConnectionPoints(for: dryDelay, outputBus: 0)
            .contains { $0.node === engine.mainMixerNode }
        let isUpToDate = currentTargets.count == desiredTargets.count &&
            desiredTargets.allSatisfy { desired in currentTargets.contains { $0 === desired } } &&
            splitter.outputFormat(forBus: 0) == format &&
            dryReachesMain &&
            sendsReachFX &&
            dryDelay.outputFormat(forBus: 0) == format
        guard !isUpToDate else {
            // The fan-out matches the live sends, so no removed one is in it.
            detachRetiredSendGains(of: trackID)
            return
        }

        // A one-to-many connect made while the engine runs ignores the
        // requested format (a new mixer stays at its 44.1 kHz default, adding
        // a hidden resampler) and can throw, so fan-out is rewired only with
        // the engine stopped. During transport it waits for stop().
        if isPlaying || isRecording {
            pendingSplitterRewires[trackID] = format
            noteGraphEvent("splitter rewire deferred: \(trackLabel(trackID))")
            return
        }
        noteGraphEvent("splitter rewire: \(trackLabel(trackID)), \(Int(format.sampleRate)) Hz \(format.channelCount) ch, engine running \(engine.isRunning)")
        let wasRunning = engine.isRunning
        if wasRunning {
            engine.stop()
        }
        safeDisconnectNodeOutput(splitter)
        if dryDelay.auAudioUnit.renderResourcesAllocated && dryDelay.outputFormat(forBus: 0) != format {
            // An AU with allocated resources refuses a format change.
            dryDelay.auAudioUnit.deallocateRenderResources()
        }
        if !dryReachesMain || dryDelay.outputFormat(forBus: 0) != format {
            safeDisconnectNodeOutput(dryDelay)
            engine.connect(
                dryDelay,
                to: engine.mainMixerNode,
                fromBus: 0,
                toBus: engine.mainMixerNode.nextAvailableInputBus,
                format: format
            )
        }
        // Send → FX input connects need the stopped engine too: queued
        // connects into one mixer all take the same input bus.
        for send in sends {
            let reachesFX = engine.outputConnectionPoints(for: send.gain, outputBus: 0)
                .contains { $0.node === send.fxInput }
            guard !reachesFX || wiredSendTargets[send.key] !== send.fxInput else { continue }
            safeDisconnectNodeOutput(send.gain)
            engine.connect(send.gain, to: send.fxInput, fromBus: 0, toBus: send.fxInput.nextAvailableInputBus, format: format)
            wiredSendTargets[send.key] = send.fxInput
        }
        var points = [AVAudioConnectionPoint(node: dryDelay, bus: 0)]
        for gainNode in sendGains {
            safeDisconnectNodeInput(gainNode)
            points.append(AVAudioConnectionPoint(node: gainNode, bus: 0))
        }
        engine.connect(splitter, to: points, fromBus: 0, format: format)
        detachRetiredSendGains(of: trackID)
        if wasRunning {
            try? engine.start()
        }
    }

    private func detachRetiredSendGains(of trackID: UUID) {
        for gainNode in retiredSendGains.removeValue(forKey: trackID) ?? [] {
            safeDisconnectNodeInput(gainNode)
            safeDetach(gainNode)
        }
    }

    private func syncFXChannels(_ fxChannels: [FXChannel]) {
        let currentIDs = Set(fxChannels.map(\.id))
        for (id, node) in fxInputNodes where !currentIDs.contains(id) {
            engine.disconnectNodeInput(node)
            engine.disconnectNodeOutput(node)
            engine.detach(node)
            fxInputNodes.removeValue(forKey: id)
            if let output = fxOutputNodes.removeValue(forKey: id) {
                output.removeTap(onBus: 0)
                engine.disconnectNodeInput(output)
                engine.disconnectNodeOutput(output)
                engine.detach(output)
            }
            if let panNode = fxPanNodes.removeValue(forKey: id) {
                engine.disconnectNodeInput(panNode)
                engine.disconnectNodeOutput(panNode)
                engine.detach(panNode)
            }
            if let returnDelay = fxReturnDelayNodes.removeValue(forKey: id) {
                engine.disconnectNodeInput(returnDelay)
                engine.disconnectNodeOutput(returnDelay)
                engine.detach(returnDelay)
            }
            // A removed plug-in left attached stays alive with its threads.
            for pluginNode in fxPluginNodes.removeValue(forKey: id) ?? [] {
                safeDisconnectNodeOutput(pluginNode)
                safeDisconnectNodeInput(pluginNode)
                safeDetach(pluginNode)
            }
            fxGraphSignatures.removeValue(forKey: id)
            fxPluginGraphGenerations.removeValue(forKey: id)
        }

        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: hardwareSampleRate,
            channels: 2
        ) else { return }

        for channel in fxChannels {
            let input: AVAudioMixerNode
            if let existing = fxInputNodes[channel.id] {
                input = existing
            } else {
                input = AVAudioMixerNode()
                engine.attach(input)
                fxInputNodes[channel.id] = input
            }

            setMixerVolume(input, channel.volume)
            let fxOutput = fxOutputNode(for: channel.id, format: format)
            fxPanNodes[channel.id]?.pan = channel.pan
            let plugins = channel.plugins.filter { isChainPlugin($0) }
            let signature = plugins.map(\.id)
            if fxGraphSignatures[channel.id] == signature {
                for plugin in plugins {
                    if let au = pluginAudioUnits[plugin.id] {
                        setAUBypass(au, bypassed: !plugin.enabled)
                    }
                }
                continue
            }
            fxPluginGraphGenerations[channel.id, default: 0] += 1
            let generation = fxPluginGraphGenerations[channel.id] ?? 0
            fxGraphSignatures[channel.id] = signature

            let previousNodes = fxPluginNodes[channel.id] ?? []
            let reusableNodes = plugins.compactMap { pluginAudioUnits[$0.id] }
            let canReuseNodes = reusableNodes.count == plugins.count &&
                Set(reusableNodes.map { node in
                    pluginAudioUnits.first(where: { $0.value === node })?.key
                }.compactMap { $0 }) == Set(plugins.map(\.id))
            if canReuseNodes {
                let reusableSet = Set(reusableNodes.map { ObjectIdentifier($0) })
                for node in previousNodes {
                    safeDisconnectNodeOutput(node)
                    safeDisconnectNodeInput(node)
                    // A removed plug-in left attached stays alive, and its
                    // threads crash in the plug-in's static destructors at exit.
                    if !reusableSet.contains(ObjectIdentifier(node)) {
                        safeDetach(node)
                    }
                }
                fxPluginNodes[channel.id] = reusableNodes
                reconnectPluginChain(
                    from: input,
                    through: reusableNodes,
                    to: fxPanNodes[channel.id] ?? fxOutput,
                    format: format
                )
                for plugin in plugins {
                    if let au = pluginAudioUnits[plugin.id] {
                        setAUBypass(au, bypassed: !plugin.enabled)
                        AudioUnitReset(au.audioUnit, kAudioUnitScope_Global, 0)
                    }
                }
                continue
            }

            for node in previousNodes {
                engine.disconnectNodeOutput(node)
                engine.detach(node)
            }
            fxPluginNodes[channel.id] = []

            engine.disconnectNodeOutput(input)
            if plugins.isEmpty {
                connectFXOutput(channelID: channel.id, from: input, format: format)
            }
            installFXAudioUnits(
                plugins,
                channelID: channel.id,
                previousNode: input,
                format: format,
                index: 0,
                generation: generation
            )
        }
        connectFXOutputsToMainMixer(format: format)
    }

    private func fxOutputsMissingMainMixer() -> [AVAudioMixerNode] {
        fxOutputNodes.values.filter { output in
            !engine.outputConnectionPoints(for: output, outputBus: 0)
                .contains { $0.node === engine.mainMixerNode }
        }
    }

    // A connect to the main mixer made while the engine runs is only queued
    // until the next stop, and every queued connect targets the same "next
    // available" bus, so a later one silently replaces an earlier one. That
    // left an FX channel's output unconnected: the channel was never rendered
    // and all sends to it were silent. So FX outputs are connected with the
    // engine stopped, and re-checked on every sync; during transport this
    // waits for stop().
    private func connectFXOutputsToMainMixer(format: AVAudioFormat) {
        let missing = fxOutputsMissingMainMixer()
        guard !missing.isEmpty, !isPlaying, !isRecording else { return }
        noteGraphEvent("connectFXOutputsToMainMixer (\(missing.count))")
        let wasRunning = engine.isRunning
        if wasRunning {
            engine.stop()
        }
        for output in missing {
            engine.connect(
                output,
                to: engine.mainMixerNode,
                fromBus: 0,
                toBus: engine.mainMixerNode.nextAvailableInputBus,
                format: format
            )
        }
        if wasRunning {
            try? engine.start()
        }
    }

    private func connectFXOutput(
        channelID: UUID,
        from node: AVAudioNode,
        format: AVAudioFormat
    ) {
        safeDisconnectNodeOutput(node)
        let fxOutput = fxOutputNode(for: channelID, format: format)
        let destination = fxPanNodes[channelID] ?? fxOutput
        safeDisconnectNodeInput(destination)
        connectReformatting(node, to: destination, format: format)
        updateLatencyCompensation()
    }

    private func fxOutputNode(for channelID: UUID, format: AVAudioFormat) -> AVAudioMixerNode {
        if let existing = fxOutputNodes[channelID] {
            return existing
        }
        // Connected to the main mixer by connectFXOutputsToMainMixer(), with
        // the engine stopped.
        let output = AVAudioMixerNode()
        engine.attach(output)
        let panNode = AVAudioMixerNode()
        engine.attach(panNode)
        // Pan → return delay → output (fader meter and mute stay after it).
        let returnDelay = makeDelayCompensationNode()
        fxReturnDelayNodes[channelID] = returnDelay
        engine.connect(panNode, to: returnDelay, format: format)
        engine.connect(returnDelay, to: output, format: format)
        fxPanNodes[channelID] = panNode
        output.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in
            let peak = StereoPeak(buffer: buffer)
            self?.peakLock.withLock {
                let previous = self?.fxOutputPeaks[channelID] ?? .zero
                self?.fxOutputPeaks[channelID] = previous.merged(with: peak)
            }
        }
        fxOutputNodes[channelID] = output
        return output
    }

    private func installFXAudioUnits(
        _ plugins: [TrackPluginDescriptor],
        channelID: UUID,
        previousNode: AVAudioNode,
        format: AVAudioFormat,
        index: Int,
        generation: Int,
        resumeEngine: Bool = true
    ) {
        guard index < plugins.count else {
            connectFXOutput(channelID: channelID, from: previousNode, format: format)
            if resumeEngine && !engine.isRunning {
                try? engine.start()
            }
            return
        }
        let plugin = plugins[index]

        if let existingAU = pluginAudioUnits[plugin.id] {
            if !fxPluginNodes[channelID, default: []].contains(where: { $0 === existingAU }) {
                fxPluginNodes[channelID, default: []].append(existingAU)
            }
            if !engine.attachedNodes.contains(existingAU) {
                engine.attach(existingAU)
            }
            safeDisconnectNodeOutput(previousNode)
            safeDisconnectNodeInput(existingAU)
            connectReformatting(previousNode, to: existingAU, format: format)
            setAUBypass(existingAU, bypassed: !plugin.enabled)
            restoreSavedState(for: plugin.id, audioUnit: existingAU)

            if index + 1 < plugins.count {
                installFXAudioUnits(
                    plugins,
                    channelID: channelID,
                    previousNode: existingAU,
                    format: format,
                    index: index + 1,
                    generation: generation,
                    resumeEngine: resumeEngine
                )
            } else {
                connectFXOutput(channelID: channelID, from: existingAU, format: format)
                if resumeEngine && !engine.isRunning {
                    try? engine.start()
                }
            }
            return
        }

        let vst3Instance = plugin.kind == .vst3 ? vst3Instances[plugin.id] : nil
        AVAudioUnit.instantiate(
            with: chainComponentDescription(for: plugin),
            options: [],
            completionHandler: { [weak self] audioUnit, _ in
                if let vst3Instance {
                    (audioUnit?.auAudioUnit as? VST3AudioUnit)?.attach(vst3Instance)
                }
                guard let self else { return }
                let audioUnit = audioUnit.flatMap {
                    self.acceptsChainFormat($0, format: format, name: plugin.name) ? $0 : nil
                }
                guard let audioUnit else {
                    DispatchQueue.main.async {
                        // The channel may be gone or rebuilt by now; going on
                        // would wire its detached input to a new output.
                        guard self.fxPluginGraphGenerations[channelID] == generation else { return }
                        self.markPluginUnavailable(plugin.id)
                        self.installFXAudioUnits(
                            plugins,
                            channelID: channelID,
                            previousNode: previousNode,
                            format: format,
                            index: index + 1,
                            generation: generation,
                            resumeEngine: resumeEngine
                        )
                    }
                    return
                }
                DispatchQueue.main.async {
                    guard self.fxPluginGraphGenerations[channelID] == generation else {
                        return
                    }
                    let wasEngineRunning = self.engine.isRunning || resumeEngine
                    if self.engine.isRunning {
                        self.engine.stop()
                    }
                    self.safeDisconnectNodeOutput(previousNode)
                    if !self.engine.attachedNodes.contains(audioUnit) {
                        self.engine.attach(audioUnit)
                    }
                    self.unavailablePluginIDs.remove(plugin.id)
                    self.safeDisconnectNodeInput(audioUnit)
                    self.connectReformatting(previousNode, to: audioUnit, format: format)
                    self.setAUBypass(audioUnit, bypassed: !plugin.enabled)
                    self.restoreSavedState(for: plugin.id, audioUnit: audioUnit)
                    self.fxPluginNodes[channelID, default: []].append(audioUnit)
                    self.replacePluginAudioUnit(audioUnit, for: plugin.id)
                    self.retryPendingPluginUIRequest(for: plugin.id)
                    if index + 1 < plugins.count {
                        self.installFXAudioUnits(
                            plugins,
                            channelID: channelID,
                            previousNode: audioUnit,
                            format: format,
                            index: index + 1,
                            generation: generation,
                            resumeEngine: wasEngineRunning
                        )
                    } else {
                        self.connectFXOutput(channelID: channelID, from: audioUnit, format: format)
                        if wasEngineRunning && !self.engine.isRunning {
                            try? self.engine.start()
                        }
                    }
                }
            }
        )
    }

    private func isPluginGraphReady(
        for tracks: [AudioTrack],
        fxChannels: [FXChannel]
    ) -> Bool {
        guard !isMasterPluginGraphBuilding else { return false }

        for track in tracks {
            let requiredPluginIDs = track.plugins
                .filter { isChainPlugin($0) }
                .map(\.id)
            guard requiredPluginIDs.allSatisfy({
                pluginAudioUnits[$0] != nil || unavailablePluginIDs.contains($0)
            }) else { return false }
            let availablePluginCount = requiredPluginIDs.filter {
                !unavailablePluginIDs.contains($0)
            }.count
            guard (trackPluginNodes[track.id]?.count ?? 0) == availablePluginCount else {
                return false
            }
            let vstIDs = track.plugins
                .filter { $0.enabled && $0.kind == .vst3 }
                .map(\.id)
            guard vstIDs.allSatisfy({ vst3Instances[$0] != nil || unavailablePluginIDs.contains($0) }) else {
                return false
            }
        }

        for channel in fxChannels {
            let requiredPluginIDs = channel.plugins
                .filter { isChainPlugin($0) }
                .map(\.id)
            guard requiredPluginIDs.allSatisfy({
                pluginAudioUnits[$0] != nil || unavailablePluginIDs.contains($0)
            }) else { return false }
            let availablePluginCount = requiredPluginIDs.filter {
                !unavailablePluginIDs.contains($0)
            }.count
            guard (fxPluginNodes[channel.id]?.count ?? 0) == availablePluginCount else {
                return false
            }
        }

        let masterAUPlugins = configuredMasterPlugins.filter { isChainPlugin($0) }
        guard masterAUPlugins.allSatisfy({
            pluginAudioUnits[$0.id] != nil || unavailablePluginIDs.contains($0.id)
        }) else { return false }
        let availableMasterAUCount = masterAUPlugins.filter {
            !unavailablePluginIDs.contains($0.id)
        }.count
        let availableMasterNodes = masterAUPlugins.compactMap { pluginAudioUnits[$0.id] }
        guard availableMasterNodes.count == availableMasterAUCount else { return false }
        guard masterPluginNodes.count == availableMasterAUCount else { return false }

        // The master path remains connected directly to the output while its
        // AU is being instantiated. Do not block the first render on a master
        // plug-in: the running engine is what allows some AUs to finish their
        // host-side initialization. The completed AU is inserted asynchronously.
        return true
    }

    private func installAudioUnits(
        _ plugins: [TrackPluginDescriptor],
        for trackID: UUID,
        previousNode: AVAudioNode,
        format: AVAudioFormat,
        index: Int,
        generation: Int,
        resumeEngine: Bool = true
    ) {
        guard index < plugins.count else {
            connectTrackChainTail(trackID, from: previousNode, format: format)
            if resumeEngine && !engine.isRunning {
                try? engine.start()
            }
            return
        }

        let plugin = plugins[index]
        guard isChainPlugin(plugin) else {
            installAudioUnits(
                plugins,
                for: trackID,
                previousNode: previousNode,
                format: format,
                index: index + 1,
                generation: generation,
                resumeEngine: resumeEngine
            )
            return
        }

        if let existingAU = pluginAudioUnits[plugin.id] {
            if !trackPluginNodes[trackID, default: []].contains(where: { $0 === existingAU }) {
                trackPluginNodes[trackID, default: []].append(existingAU)
            }
            if !engine.attachedNodes.contains(existingAU) {
                engine.attach(existingAU)
            }
            safeDisconnectNodeOutput(previousNode)
            safeDisconnectNodeInput(existingAU)
            connectReformatting(previousNode, to: existingAU, format: format)
            setAUBypass(existingAU, bypassed: !plugin.enabled)
            restoreSavedState(for: plugin.id, audioUnit: existingAU)
            updateLatencyCompensation()

            if index + 1 < plugins.count {
                installAudioUnits(
                    plugins,
                    for: trackID,
                    previousNode: existingAU,
                    format: format,
                    index: index + 1,
                    generation: generation,
                    resumeEngine: resumeEngine
                )
            } else {
                connectTrackChainTail(trackID, from: existingAU, format: format)
                if resumeEngine && !engine.isRunning {
                    try? engine.start()
                }
            }
            return
        }

        let componentDescription = chainComponentDescription(for: plugin)
        let vst3Instance = plugin.kind == .vst3 ? vst3Instances[plugin.id] : nil
        let pluginName = plugin.name
        let pluginID = plugin.id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            AVAudioUnit.instantiate(
                with: componentDescription,
                options: [],
                completionHandler: { audioUnit, error in
                    if let vst3Instance {
                        (audioUnit?.auAudioUnit as? VST3AudioUnit)?.attach(vst3Instance)
                    }
                    guard let self else { return }
                    DispatchQueue.main.async {
                        guard self.trackRenderers[trackID] != nil,
                              self.pluginGraphGenerations[trackID] == generation else {
                            return
                        }
                        let audioUnit = audioUnit.flatMap {
                            self.acceptsChainFormat($0, format: format, name: pluginName) ? $0 : nil
                        }
                        guard let audioUnit else {
                            self.markPluginUnavailable(pluginID)
                            if let error {
                                print("Failed to insert AU effect \(pluginName): \(error)")
                            }
                            self.installAudioUnits(
                                plugins,
                                for: trackID,
                                previousNode: previousNode,
                                format: format,
                                index: index + 1,
                                generation: generation,
                                resumeEngine: resumeEngine
                            )
                            return
                        }

                        let wasEngineRunning = self.engine.isRunning || resumeEngine
                        if self.engine.isRunning {
                            self.engine.stop()
                        }
                        self.safeDisconnectNodeOutput(previousNode)
                        if !self.engine.attachedNodes.contains(audioUnit) {
                            self.engine.attach(audioUnit)
                        }
                        self.unavailablePluginIDs.remove(pluginID)
                        self.safeDisconnectNodeInput(audioUnit)
                        self.connectReformatting(previousNode, to: audioUnit, format: format)
                        self.setAUBypass(audioUnit, bypassed: !plugin.enabled)
                        self.restoreSavedState(for: pluginID, audioUnit: audioUnit)
                        self.trackPluginNodes[trackID, default: []].append(audioUnit)
                        self.replacePluginAudioUnit(audioUnit, for: pluginID)
                        self.updateLatencyCompensation()
                        self.retryPendingPluginUIRequest(for: pluginID)
                        if index + 1 < plugins.count {
                            self.installAudioUnits(
                                plugins,
                                for: trackID,
                                previousNode: audioUnit,
                                format: format,
                                index: index + 1,
                                generation: generation,
                                resumeEngine: wasEngineRunning
                            )
                        } else {
                            self.connectTrackChainTail(trackID, from: audioUnit, format: format)
                            if wasEngineRunning && !self.engine.isRunning {
                                try? self.engine.start()
                            }
                        }
                    }
                }
            )
        }
    }

    public func openPluginUI(pluginID: UUID) {
        if pluginDescriptors[pluginID]?.kind == .vst3 {
            openVST3PluginUI(pluginID: pluginID)
            return
        }

        guard let audioUnit = pluginAudioUnits[pluginID] else {
            print("Plugin UI requested before AU was ready: \(pluginID)")
            pendingPluginUIRequests.insert(pluginID)
            return
        }

        if let window = pluginWindows[pluginID] {
            configurePluginWindow(window)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let descriptor = pluginDescriptors[pluginID]
        let pluginTitle = descriptor?.name ?? audioUnit.auAudioUnit.audioUnitName ?? "Audio Unit"
        let compatibility = descriptor?.resolvedCompatibility ?? .automatic
        print("Opening plugin UI: \(pluginTitle) [\(pluginID)]")

        if let viewController = pluginViewControllers[pluginID] {
            presentPluginViewController(
                viewController,
                pluginID: pluginID,
                title: pluginTitle,
                cacheForPlugin: false
            )
            return
        }

        if compatibility.ui == .genericOnly {
            presentGenericPluginView(
                audioUnit: audioUnit,
                pluginID: pluginID,
                title: pluginTitle
            )
            return
        }

        if compatibility.ui == .disabled {
            return
        }

        guard audioUnit.auAudioUnit.providesUserInterface else {
            print("Plugin has no custom UI, using Generic UI: \(pluginTitle)")
            presentGenericPluginView(
                audioUnit: audioUnit,
                pluginID: pluginID,
                title: pluginTitle
            )
            return
        }

        // Some AU implementations are not safe to initialize their custom
        // view until the host graph has rendered at least one real-time cycle.
        // Use the same warm-up rule for every plug-in and retry after playback
        // starts instead of calling requestViewController too early.
        guard hasWarmedUpAudioGraph else {
            print("Plugin UI deferred until audio warm-up: \(pluginTitle)")
            pendingPluginUIRequests.insert(pluginID)
            return
        }

        requestOriginalPluginUI(
            audioUnit: audioUnit,
            pluginID: pluginID,
            title: pluginTitle,
            timeoutMs: compatibility.requestTimeoutMs
        )
    }


    private func openVST3PluginUI(pluginID: UUID) {
        guard let descriptor = pluginDescriptors[pluginID],
              descriptor.kind == .vst3 else {
            print("VST3 descriptor is not ready: \(pluginID)")
            return
        }
        // Attach to the same instance that actually processes audio, so
        // parameter edits made in the plugin's own editor affect playback.
        guard let instance = vst3Instances[pluginID] else {
            print("VST3 plugin instance is not ready: \(pluginID)")
            pendingPluginUIRequests.insert(pluginID)
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self,
                      self.pendingPluginUIRequests.remove(pluginID) != nil else { return }
                self.openPluginUI(pluginID: pluginID)
            }
            return
        }
        if let window = pluginWindows[pluginID] {
            configurePluginWindow(window)
            window.makeKeyAndOrderFront(nil)
            return
        }

        // ウィンドウを表示する前にエディタをアタッチしてサイズを確定する。
        // 旧実装では仮サイズ(640×480)でウィンドウを先に makeKeyAndOrderFront してから
        // サイズを変更していたため、ビットマップとウィンドウのサイズが一致しないことがあった。
        // C++ 側では attached() を先に呼んでから getSize() を取得するよう修正済み。
        let hostView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))

        guard let contentSize = instance.attachEditor(to: hostView) else {
            print("VST3 plugin editor attach failed: \(pluginID)")
            return
        }
        hostView.frame = NSRect(origin: .zero, size: contentSize)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostView
        window.title = pluginDescriptors[pluginID]?.name ?? "VST3"
        window.setContentSize(contentSize)
        window.center()
        restorePluginWindowFrame(window, pluginID: pluginID)
        window.isReleasedWhenClosed = false
        configurePluginWindow(window)
        pluginWindows[pluginID] = window

        // プラグインが後から IPlugFrame::resizeView() を呼んできたとき
        // ウィンドウとホストビューのサイズを追従させる。
        instance.onResizeRequest = { [weak self, weak window, weak hostView] newSize in
            guard let self, let window, let hostView else { return }
            let clamped = NSSize(
                width: max(320, newSize.width),
                height: max(240, newSize.height)
            )
            hostView.setFrameSize(clamped)
            window.setContentSize(clamped)
            window.layoutIfNeeded()
            print("VST3 resizeView: \(clamped) [\(pluginID)]")
            _ = self // suppress "self captured but never used" warning
        }

        window.makeKeyAndOrderFront(nil)
    }

    private func closePluginWindow(pluginID: UUID) {
        if pluginDescriptors[pluginID]?.kind == .vst3 {
            if let instance = vst3Instances[pluginID] {
                instance.onResizeRequest = nil
                instance.removeEditor()
            }
        }
        removePluginViewSizeObservers(pluginID: pluginID)
        guard let window = pluginWindows.removeValue(forKey: pluginID) else { return }
        window.contentViewController = nil
        window.contentView = nil
        window.close()
    }

    // An AU's close button only hides its window, and opening the UI again
    // shows that same window. Closing it moved the cached view controller
    // into a new window at every open, and some plug-in views (Waves
    // WaveShell) come up blank after a few such moves. VST3 editors are
    // detached and attached again instead, so their windows still close.
    // window.close() from the host (plug-in removed, project closed) does not
    // ask this and still closes the window.
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let entry = pluginWindows.first(where: { $0.value === sender }),
              pluginDescriptors[entry.key]?.kind != .vst3 else { return true }
        sender.orderOut(nil)
        return false
    }

    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        guard let entry = pluginWindows.first(where: { $0.value === window }) else { return }
        let pluginID = entry.key
        pluginWindowFrames[pluginID] = window.frame
        pluginWindows.removeValue(forKey: pluginID)
        removePluginViewSizeObservers(pluginID: pluginID)
        // The window's own close button bypasses closePluginWindow(), so the
        // VST3 editor must be detached here too. Otherwise the plugin still
        // believes it is attached to the (now deallocated) host view, and
        // MyDAWVST3AttachEditor skips re-attaching on the next open, leaving
        // the reopened window blank.
        if pluginDescriptors[pluginID]?.kind == .vst3, let instance = vst3Instances[pluginID] {
            instance.onResizeRequest = nil
            instance.removeEditor()
        }
    }

    /// プラグインウィンドウがキーになった（クリックされた）とき、
    /// そのウィンドウを orderFront して最前面に出す。
    /// これによりプラグイン間の重なり順をクリックで自由に変更できる。
    public func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              pluginWindows.values.contains(where: { $0 === window }) else { return }
        window.orderFront(nil)
    }

    private func requestOriginalPluginUI(
        audioUnit: AVAudioUnit,
        pluginID: UUID,
        title: String,
        timeoutMs: Int
    ) {
        guard !pluginUIRequests.contains(pluginID) else { return }
        pluginUIRequests.insert(pluginID)

        // Keep a potentially blocking third-party AU request off MainActor.
        // The returned AppKit controller is installed on MainActor below.
        pluginUIRequestQueue.async { [weak self] in
            let callbackReceived = DispatchSemaphore(value: 0)
            print("Requesting AU view controller: \(title) [\(pluginID)]")
            audioUnit.auAudioUnit.requestViewController { viewController in
                print("AU view controller callback: \(title), returned=\(viewController != nil) [\(pluginID)]")
                callbackReceived.signal()
                Task { @MainActor [weak self] in
                    guard let self,
                          self.pluginUIRequests.remove(pluginID) != nil else { return }

                    if let viewController {
                        self.pluginViewControllers[pluginID] = viewController
                        self.presentPluginViewController(
                            viewController,
                            pluginID: pluginID,
                            title: title
                        )
                    } else {
                        self.presentGenericPluginView(
                            audioUnit: audioUnit,
                            pluginID: pluginID,
                            title: title
                        )
                    }
                }
            }
            if callbackReceived.wait(timeout: .now() + .milliseconds(timeoutMs)) == .timedOut {
                Task { @MainActor [weak self] in
                    guard let self,
                          self.pluginUIRequests.remove(pluginID) != nil else { return }
                    print("AU view controller timed out, using Generic UI: \(title) [\(pluginID)]")
                    self.presentGenericPluginView(
                        audioUnit: audioUnit,
                        pluginID: pluginID,
                        title: title
                    )
                }
            }
        }
    }

    private func presentPluginViewController(
        _ viewController: NSViewController,
        pluginID: UUID,
        title: String,
        maximumContentSize: NSSize? = nil,
        cacheForPlugin: Bool = true
    ) {
        // contentViewController を使う場合、NSWindow は自動的にビューコントローラーの
        // view を contentView として設定し、ウィンドウのリサイズに追従させる。
        // translatesAutoresizingMaskIntoConstraints を false にすると
        // この自動リサイズが壊れ、ビューが左下に張り付いて上部に空白ができるため、
        // デフォルト (true) のままにする。
        let pluginView = viewController.view
        let preferredSize = viewController.preferredContentSize
        let viewSize = pluginView.frame.size
        let isValid: (NSSize) -> Bool = { $0.width > 1 && $0.height > 1 }

        let contentSize: NSSize
        if let maximumContentSize {
            // Host-built generic parameter view.
            contentSize = NSSize(
                width: min(max(viewSize.width, 480), maximumContentSize.width),
                height: min(max(viewSize.height, 360), maximumContentSize.height)
            )
        } else {
            // A plug-in's custom view is usually a fixed-size bitmap. Any
            // window larger than the view leaves blank space at the top and
            // right (AppKit anchors content bottom-left), so the window must
            // match the view exactly: no minimum size is imposed.
            let rawSize: NSSize
            if isValid(viewSize) {
                rawSize = viewSize
            } else if isValid(preferredSize) {
                rawSize = preferredSize
            } else {
                pluginView.layoutSubtreeIfNeeded()
                rawSize = pluginView.fittingSize
            }
            contentSize = NSSize(width: max(rawSize.width, 100), height: max(rawSize.height, 60))
        }
        print("[PluginUI] \(title): preferred=\(preferredSize) viewFrame=\(viewSize) -> window content \(contentSize)")

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = viewController
        window.title = title
        window.setContentSize(contentSize)
        window.center()
        restorePluginWindowFrame(window, pluginID: pluginID)
        window.isReleasedWhenClosed = false
        configurePluginWindow(window)
        window.makeKeyAndOrderFront(nil)
        pluginWindows[pluginID] = window
        if cacheForPlugin {
            pluginViewControllers[pluginID] = viewController
        }
        if maximumContentSize == nil {
            followPluginViewSize(viewController, window: window, pluginID: pluginID, title: title)
        }
    }

    // Some plug-ins (e.g. web-view based UIs) size their view only after it
    // is on screen. Keep the window matched to whatever size the plug-in
    // settles on, from either its view frame or its preferredContentSize.
    private func followPluginViewSize(
        _ viewController: NSViewController,
        window: NSWindow,
        pluginID: UUID,
        title: String
    ) {
        removePluginViewSizeObservers(pluginID: pluginID)
        let pluginView = viewController.view
        let apply: (NSSize) -> Void = { [weak window] size in
            guard let window, size.width > 1, size.height > 1,
                  window.contentLayoutRect.size != size else { return }
            print("[PluginUI] \(title): plug-in resized to \(size)")
            window.setContentSize(size)
        }
        pluginView.postsFrameChangedNotifications = true
        let frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: pluginView,
            queue: .main
        ) { [weak pluginView] _ in
            guard let pluginView else { return }
            MainActor.assumeIsolated { apply(pluginView.frame.size) }
        }
        let preferredObserver = viewController.observe(\.preferredContentSize, options: [.new]) { controller, _ in
            let size = controller.preferredContentSize
            DispatchQueue.main.async { apply(size) }
        }
        pluginViewSizeObservers[pluginID] = [frameObserver, preferredObserver]
    }

    private func removePluginViewSizeObservers(pluginID: UUID) {
        for observer in pluginViewSizeObservers.removeValue(forKey: pluginID) ?? [] {
            if let observation = observer as? NSKeyValueObservation {
                observation.invalidate()
            } else {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }

    private func configurePluginWindow(_ window: NSWindow) {
        window.delegate = self
        // .floating レベルにすることで、メインウィンドウを何度クリックしても
        // プラグインウィンドウが後ろに回らないようにする。
        // プラグイン同士は同じ .floating レベルにあるため、
        // クリックで互いの重なり順を変えることは引き続き可能。
        window.level = .floating
        // アプリが非アクティブになったとき（他のアプリに切り替えたとき）は
        // プラグインウィンドウを自動的に隠す。
        // MyDAW に戻ると自動的に再表示される。Logic Pro 等と同じ挙動。
        window.hidesOnDeactivate = true
        window.collectionBehavior.insert(.moveToActiveSpace)
    }

    private func restorePluginWindowFrame(_ window: NSWindow, pluginID: UUID) {
        guard let frame = pluginWindowFrames.removeValue(forKey: pluginID) else { return }
        window.setFrameOrigin(frame.origin)
    }

    private func presentGenericPluginView(
        audioUnit: AVAudioUnit,
        pluginID: UUID,
        title: String
    ) {
        guard let parameterTree = audioUnit.auAudioUnit.parameterTree else {
            print("AU has no parameter tree for Generic UI: \(title)")
            return
        }
        let view = GenericAUParameterView(parameterTree: parameterTree)
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = view

        let documentSize = view.fittingSize
        let maximumWidth = NSScreen.main?.visibleFrame.width ?? 1200
        let documentWidth = max(documentSize.width + 24, 480)
        let visibleSize = NSSize(
            width: min(documentWidth + 18, maximumWidth),
            height: min(max(documentSize.height, 360), 640)
        )
        scrollView.hasHorizontalScroller = documentWidth > visibleSize.width
        view.frame = NSRect(
            origin: .zero,
            size: NSSize(
                width: documentWidth,
                height: max(documentSize.height, visibleSize.height)
            )
        )
        scrollView.frame = NSRect(origin: .zero, size: visibleSize)

        let viewController = NSViewController()
        viewController.view = scrollView
        presentPluginViewController(
            viewController,
            pluginID: pluginID,
            title: title,
            maximumContentSize: visibleSize,
            cacheForPlugin: false
        )
    }

    // MARK: - Transport: Play / Record

    public func startPlayOrRecord(
        tracks: [AudioTrack],
        fxChannels: [FXChannel] = [],
        isRetry: Bool = false,
        recordArmedTracks: Bool = true
    ) {
        noteGraphEvent("startPlayOrRecord\(isRetry ? " (retry)" : "")")
        if isStartingPlayback && !isRetry && !isPlaying && !isRecording {
            startPlaybackTask?.cancel()
            startPlaybackTask = nil
            playbackRetryTask?.cancel()
            playbackRetryTask = nil
            isStartingPlayback = false
            return
        }

        if isPlaying || isRecording {
            stop(tracks: tracks)
            return
        }

        if !isRetry {
            isStartingPlayback = true
        }

        startPlaybackTask?.cancel()
        startPlaybackTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self,
                  !Task.isCancelled,
                  self.isStartingPlayback else { return }
            self.startPlaybackTask = nil
            self.beginPlayOrRecord(
                tracks: tracks,
                fxChannels: fxChannels,
                recordArmedTracks: recordArmedTracks
            )
        }
    }

    private func beginPlayOrRecord(
        tracks: [AudioTrack],
        fxChannels: [FXChannel],
        recordArmedTracks: Bool
    ) {
        // Ensure master graph matches configured master plugins before readiness check
        if configuredMasterPlugins.map(\.id) != masterPluginSignature && !isMasterPluginGraphBuilding {
            syncMasterPlugins(configuredMasterPlugins)
        }

        // The graph is prepared by project/plugin changes, never by transport
        // start. Wait here until asynchronous plugin insertion has completed.
        guard isPluginGraphReady(for: tracks, fxChannels: fxChannels) else {
            let diagnostic = masterGraphReadinessDiagnostic()
            if diagnostic != lastPlaybackReadinessDiagnostic {
                print("Playback delayed: \(diagnostic)")
                lastPlaybackReadinessDiagnostic = diagnostic
            }
            schedulePlaybackRetry(
                tracks: tracks,
                fxChannels: fxChannels,
                recordArmedTracks: recordArmedTracks
            )
            return
        }

        playbackRetryTask?.cancel()
        playbackRetryTask = nil
        lastPlaybackReadinessDiagnostic = nil

        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                print("Failed to start audio engine for playback: \(error)")
                isStartingPlayback = false
                return
            }
        }

        let armedTracks = recordArmedTracks ? tracks.filter { $0.isRecordArmed } : []
        let hasArmedTracks = !armedTracks.isEmpty

        if hasArmedTracks, recordingFinalizationTask != nil {
            schedulePlaybackRetry(
                tracks: tracks,
                fxChannels: fxChannels,
                recordArmedTracks: recordArmedTracks
            )
            return
        }

        if hasArmedTracks, punchInTime == nil, recordRollbackDuration > 0 {
            // Record from the playhead, playing from the rollback point.
            isRollbackPass = true
            punchInTime = currentTime
            punchOutTime = .infinity
            currentTime = max(0.0, currentTime - recordRollbackDuration)
        }

        // The start time is fixed after the clips are scheduled (see
        // startPlayback), so slow scheduling never costs the opening.
        isStartingPlayback = false
        // The click player starts before the clip players, so its first
        // click (on the start position) is never late. Its stop() and
        // play(at:) each take a render cycle, hence two extra calls.
        let sharedStartTime: AVAudioTime
        if hasArmedTracks {
            sharedStartTime = startRecording(
                armedTracks: armedTracks,
                playbackTracks: tracks.filter { !$0.isRecordArmed }
            )
        } else {
            sharedStartTime = startPlayback(
                tracks: tracks,
                extraPlayCalls: metronomeEnabled ? 2 : 0
            ) { [self] transportStartTime in
                startMetronome(at: transportStartTime)
            }
        }

        isPlaying = true
        isRecording = hasArmedTracks
        if punchInTime != nil, punchOutTime != nil, currentTime < (punchInTime ?? 0.0) {
            isRecording = false
        }
        hasWarmedUpAudioGraph = true
        schedulePendingPluginUIRequests()
        if playheadTimer == nil {
            startPlayheadTimer(at: sharedStartTime.hostTime)
        }
    }

    private func schedulePendingPluginUIRequests() {
        guard !pendingPluginUIRequests.isEmpty else { return }
        let requests = pendingPluginUIRequests
        pendingPluginUIRequests.removeAll()

        // Let AVAudioEngine enter its render cycle before asking an AU for its
        // AppKit view. This keeps UI creation outside the playback start path.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            for pluginID in requests {
                self.openPluginUI(pluginID: pluginID)
            }
        }
    }

    private func schedulePlaybackRetry(
        tracks: [AudioTrack],
        fxChannels: [FXChannel],
        recordArmedTracks: Bool
    ) {
        guard playbackRetryTask == nil else { return }

        playbackRetryTask = Task { @MainActor [weak self] in
            for _ in 0..<100 {
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      let self,
                      !self.isPlaying,
                      !self.isRecording else { return }
                guard self.isPluginGraphReady(for: tracks, fxChannels: fxChannels) else {
                    continue
                }
                self.playbackRetryTask = nil
                self.startPlayOrRecord(
                    tracks: tracks,
                    fxChannels: fxChannels,
                    isRetry: true,
                    recordArmedTracks: recordArmedTracks
                )
                return
            }
            self?.playbackRetryTask = nil
        }
    }

    private func masterGraphReadinessDiagnostic() -> String {
        let masterAUPlugins = configuredMasterPlugins.filter { $0.kind == .au }
        let auIDs = masterAUPlugins.map(\.id)
        let loadedCount = auIDs.filter { pluginAudioUnits[$0] != nil }.count
        let unavailableCount = auIDs.filter { unavailablePluginIDs.contains($0) }.count
        return "masterBuilding=\(isMasterPluginGraphBuilding), expectedAU=\(auIDs.count), nodes=\(masterPluginNodes.count), loaded=\(loadedCount), unavailable=\(unavailableCount), signature=\(masterPluginSignature.count)/\(configuredMasterPlugins.count)"
    }

    /// The pre-roll of a track: its own inserts' latency plus the FX
    /// compensation. Its renderer plays this much ahead of the transport.
    private func trackPreRoll(_ trackID: UUID) -> Double {
        (trackPluginLatencies[trackID] ?? 0.0) + fxCompensationLatency
    }

    /// Starts every track's renderer so that `startSec` is heard at the
    /// returned transport start (the playhead clock). The opening of each
    /// track is read from disk first, so nothing is lost at the start; the
    /// start is then the earliest safe time, plus a render cycle for each of
    /// the metronome's `extraPlayCalls`. `beforePlayersStart` sets up what
    /// must be in place at the start (recording, the metronome).
    @discardableResult
    private func startPlayback(
        tracks: [AudioTrack],
        startSec: Double? = nil,
        extraPlayCalls: Int = 0,
        beforePlayersStart: ((AVAudioTime) -> Void)? = nil
    ) -> AVAudioTime {
        let startSec = startSec ?? currentTime
        let rate = hardwareSampleRate
        let renderers = tracks.compactMap { track in trackRenderers[track.id].map { (track.id, $0) } }
        let startFrame = Int64((startSec * rate).rounded())
        for (_, renderer) in renderers {
            renderer.prepare(renderFrom: startFrame)
        }
        let readyDeadline = Date().addingTimeInterval(2.0)
        while !renderers.allSatisfy({ $0.1.isReadyToStart() }) && Date() < readyDeadline {
            Thread.sleep(forTimeInterval: 0.001)
        }

        let cycle = Double(max(256, inputBufferFrameSize)) / max(1.0, rate) * 1.2
        let transportStartTime = nextTransportStartTime(extraLead: Double(extraPlayCalls) * cycle)
        beforePlayersStart?(transportStartTime)
        for (trackID, renderer) in renderers {
            renderer.start(
                anchorHost: transportStartTime.hostTime,
                anchorFrame: Int64(((startSec + trackPreRoll(trackID)) * rate).rounded())
            )
        }
        return transportStartTime
    }

    /// After a latency change during playback: keeps every track's audio
    /// its new pre-roll ahead of the running transport clock.
    private func updateRendererAnchors() {
        let rate = hardwareSampleRate
        for (trackID, renderer) in trackRenderers {
            renderer.setAnchorFrame(Int64(((playheadStartOffset + trackPreRoll(trackID)) * rate).rounded()))
        }
    }

    /// Stops every renderer, reporting render cycles that found no audio
    /// read ahead (the disk could not keep up).
    private func stopRenderers() {
        var underruns: Int64 = 0
        for renderer in trackRenderers.values {
            underruns += renderer.stop()
        }
        if underruns > 0 {
            print("[Playback] \(underruns) render cycles found no audio read ahead")
        }
    }

    /// The transport position heard at `hostTime`, or nil before the
    /// transport clock has started.
    private func transportPosition(atHostTime hostTime: UInt64) -> Double? {
        guard let startHostTime = playheadStartHostTime, hostTime >= startHostTime else { return nil }
        return playheadStartOffset + Double(AudioConvertHostTimeToNanos(hostTime - startHostTime)) / 1_000_000_000.0
    }

    private static func hostTicks(_ seconds: Double) -> UInt64 {
        AudioConvertNanosToHostTime(UInt64(max(0.0, seconds) * 1_000_000_000.0))
    }

    /// When the transport starts: the renderers may play up to the pre-roll
    /// before it, so it is the earliest safe time plus the pre-roll.
    private func nextTransportStartTime(extraLead: Double = 0.0) -> AVAudioTime {
        AVAudioTime(hostTime: earliestPlayerStartHostTime() + Self.hostTicks(extraLead + transportPreRoll))
    }

    /// The engine renders ahead of what is heard (output latency plus an IO
    /// buffer or two), and render times are the times the audio is heard.
    /// Audio due inside the already rendered stretch would be lost, so start
    /// past it: two IO buffers after the last render, plus a margin, and
    /// never sooner than 50 ms from now.
    private func earliestPlayerStartHostTime() -> UInt64 {
        var earliest = mach_absolute_time() + Self.hostTicks(0.05)
        if engine.isRunning,
           let lastRender = engine.mainMixerNode.lastRenderTime,
           lastRender.isHostTimeValid {
            let ioBuffer = Double(max(256, inputBufferFrameSize)) / max(1.0, hardwareSampleRate)
            earliest = max(earliest, lastRender.hostTime + Self.hostTicks(2.0 * ioBuffer + 0.01))
        }
        return earliest
    }

    // Live input enters the track at its output mixer, so it passes the
    // track's fader, pan, inserts and sends like clip playback does.
    // Rewiring the input node needs the engine stopped; while the transport
    // runs the change is deferred to stop().
    /// Used on transport stop for the rewiring deferred during playback
    /// (track fan-out, input monitors). It needs the engine stopped, which
    /// cuts effect tails still ringing (an FX reverb, say) and replays a
    /// stale block on restart. So wait until the master output has decayed
    /// below -60 dB (at most 8 s) first — not lower: plug-in dither and armed
    /// inputs keep an idle master around -64 dB. If the transport starts
    /// again before that, the next stop tries again.
    private func applyDeferredRewiresWhenQuiet() {
        guard !pendingSplitterRewires.isEmpty ||
            desiredInputMonitors != appliedInputMonitors ||
            !fxOutputsMissingMainMixer().isEmpty else { return }
        inputMonitorApplyTask?.cancel()
        quietRewireGeneration += 1
        let generation = quietRewireGeneration
        isWaitingForQuietRewire = true
        inputMonitorApplyTask = Task { @MainActor [weak self] in
            defer {
                if self?.quietRewireGeneration == generation {
                    self?.isWaitingForQuietRewire = false
                }
            }
            let deadline = Date().addingTimeInterval(8)
            while let self, !Task.isCancelled, Date() < deadline {
                if self.isPlaying || self.isRecording || self.isStartingPlayback { return }
                if self.masterPeak < 0.001 { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let self, !Task.isCancelled,
                  !self.isPlaying, !self.isRecording, !self.isStartingPlayback else { return }
            let rewires = self.pendingSplitterRewires
            self.pendingSplitterRewires.removeAll()
            self.noteGraphEvent("applying deferred rewires (\(rewires.count) tracks)")
            for (trackID, format) in rewires {
                if let tail = self.trackChainTails[trackID] {
                    self.connectTrackChainTail(trackID, from: tail, format: format)
                }
            }
            if let format = AVAudioFormat(standardFormatWithSampleRate: self.hardwareSampleRate, channels: 2) {
                self.connectFXOutputsToMainMixer(format: format)
            }
            self.applyInputMonitoringIfNeeded()
        }
    }

    private func applyInputMonitoringIfNeeded() {
        guard desiredInputMonitors != appliedInputMonitors,
              !isPlaying, !isRecording else { return }
        let wasRunning = engine.isRunning
        if wasRunning {
            engine.stop()
        }
        connectInputMonitors()
        raiseMaximumFramesPerSlice()
        if wasRunning {
            do {
                try engine.start()
            } catch {
                print("Input monitoring: engine restart failed: \(error)")
            }
        }
    }

    // Any resampling stage in a path makes some render cycles longer than
    // the I/O buffer (e.g. 513 frames against 512). AVAudioEngine gives every
    // node the I/O units' slice limit, so a 512-limited AU would reject such
    // a cycle (-10874) and fail the whole pull. Raising the I/O units' limit
    // raises it for every node. Must be set while the engine is stopped.
    private func raiseMaximumFramesPerSlice() {
        var frames: UInt32 = 4096
        for unit in [engine.inputNode.audioUnit, engine.outputNode.audioUnit].compactMap({ $0 }) {
            let status = AudioUnitSetProperty(
                unit,
                kAudioUnitProperty_MaximumFramesPerSlice,
                kAudioUnitScope_Global,
                0,
                &frames,
                UInt32(MemoryLayout<UInt32>.size)
            )
            if status != noErr {
                print("Input monitoring: MaximumFramesPerSlice set failed: \(status)")
            }
        }
    }

    private func connectInputMonitors() {
        engine.disconnectNodeOutput(engine.inputNode)
        for (trackID, node) in inputMonitorNodes
            where desiredInputMonitors[trackID] == nil || trackOutputNodes[trackID] == nil {
            safeDisconnectNodeOutput(node)
            safeDetach(node)
            inputMonitorNodes.removeValue(forKey: trackID)
        }
        appliedInputMonitors = desiredInputMonitors
        guard let inputFormat = inputCaptureFormat,
              let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: hardwareSampleRate, channels: 2) else {
            return
        }

        _ = InputMonitorAudioUnit.registration
        var points: [AVAudioConnectionPoint] = []
        for (trackID, config) in desiredInputMonitors {
            guard let trackOutput = trackOutputNodes[trackID] else { continue }
            let node: AVAudioUnitEffect
            if let existing = inputMonitorNodes[trackID] {
                node = existing
            } else {
                node = AVAudioUnitEffect(audioComponentDescription: InputMonitorAudioUnit.componentDescription)
                engine.attach(node)
                inputMonitorNodes[trackID] = node
            }
            (node.auAudioUnit as? InputMonitorAudioUnit)?.configure(
                channelOffset: config.channelOffset,
                isStereo: config.isStereo
            )
            safeDisconnectNodeOutput(node)
            engine.connect(
                node,
                to: trackOutput,
                fromBus: 0,
                toBus: trackOutput.nextAvailableInputBus,
                format: stereoFormat
            )
            points.append(AVAudioConnectionPoint(node: node, bus: 0))
        }
        if !points.isEmpty {
            engine.connect(engine.inputNode, to: points, fromBus: 0, format: inputFormat)
        }
    }

    private func setRecordingMutedTracks(_ trackIDs: Set<UUID>) {
        recordingMutedTrackIDs = trackIDs
        for (trackID, renderer) in trackRenderers {
            renderer.setMuted(trackIDs.contains(trackID))
        }
    }

    /// Starts playback and recording; returns the transport start.
    private func startRecording(
        armedTracks: [AudioTrack],
        playbackTracks: [AudioTrack]
    ) -> AVAudioTime {
        // The renderers read ahead first, so the start time is fixed only once
        // that is done; the recording is armed before they start.
        return startPlayback(
            tracks: playbackTracks + armedTracks,
            extraPlayCalls: metronomeEnabled ? 2 : 0
        ) { [self] sharedStartTime in
            let usesPunchRange = punchInTime != nil && punchOutTime != nil
            if !usesPunchRange {
                setRecordingMutedTracks(Set(armedTracks.map(\.id)))
            }
            beginCapture(armedTracks: armedTracks, sharedStartTime: sharedStartTime)
            startMetronome(at: sharedStartTime)
        }
    }

    /// Creates the take files and starts capturing input for a transport
    /// that starts at `sharedStartTime`.
    private func beginCapture(armedTracks: [AudioTrack], sharedStartTime: AVAudioTime) {
        activeWriters.removeAll()
        punchArmedTrackIDs = Set(armedTracks.map(\.id))
        punchPlaybackState = 0
        isPunchRecording = punchInTime.map { currentTime >= $0 } ?? true
        // CRITICAL: Use hardwareSampleRate (actual HW rate from inputNode) — NOT the UI sampleRate.
        // This ensures the WAV file header matches the actual captured audio sample rate.
        let recordSampleRate = self.hardwareSampleRate

        activeClips.removeAll()
        if let punchInTime, let punchOutTime {
            recordingPunchTrim = PunchTrim(
                fileTimelineStart: currentTime - recordingPlacementCompensation,
                punchIn: punchInTime,
                punchOut: punchOutTime
            )
        } else {
            recordingPunchTrim = nil
        }
        recordingTakePunchTrim = recordingPunchTrim
        recordingTimingLock.withLock {
            recordingTimelineStart = currentTime
            recordingTransportStartHostTime = sharedStartTime.hostTime
            pendingRecordingClipStartTime = max(
                0.0,
                currentTime - recordingPlacementCompensation
            )
            hasLoggedFirstRecordingInput = false
        }
        // Signed: starting the players can take past the start time.
        let startNowHostTime = mach_absolute_time()
        let startDelayMs = (Double(AudioConvertHostTimeToNanos(sharedStartTime.hostTime))
            - Double(AudioConvertHostTimeToNanos(startNowHostTime))) / 1_000_000.0
        print(
            String(
                format: "[Timing] recording start: timeline=%.6f, currentTime=%.6f, sharedStartDelay=%.3f ms, inputStartSample=%@, deviceCompensation=%.3f ms, masterPluginLatency=%.3f ms",
                recordingTimelineStart,
                currentTime,
                startDelayMs,
                "hostTime",
                recordingLatencyCompensation * 1000.0,
                masterPluginLatency * 1000.0
            )
        )
        if !armedTracks.isEmpty {
            onRecordingWillAddTakes?()
        }
        for track in armedTracks {
            do {
                let writer = try AudioDiskWriter(
                    destinationDirectory: recordingsDirectory,
                    trackId: track.id,
                    trackName: track.name,
                    sampleRate: recordSampleRate,
                    channelCount: track.channelMode.channelCount,
                    is24Bit: true
                )
                activeWriters[track.id] = writer
                let compensatedStartTime = max(0.0, currentTime - recordingPlacementCompensation)
                activeClips[track.id] = track.addClip(startTime: compensatedStartTime, fileURL: writer.fileURL)
                print("Created disk writer for \(track.name) -> \(writer.fileURL.lastPathComponent) @ \(recordSampleRate) Hz")
            } catch {
                print("Failed to initialize disk writer for track \(track.name): \(error)")
            }
        }
        hasPendingRecording = !activeClips.isEmpty

        captureLock.withLock {
            self.writersSnapshot = activeWriters
            self.recordingActiveState = true
        }
    }

    private func updatePunchRecordingState() {
        guard isPlaying else { return }
        guard punchInTime != nil, punchOutTime != nil else { return }
        // Only while a punch take is being recorded: plain playback through
        // the punch range must not switch to "recording".
        guard !punchArmedTrackIDs.isEmpty else { return }
        let nextState: Int
        if let punchInTime, currentTime < punchInTime {
            nextState = 0
        } else if let punchOutTime, currentTime >= punchOutTime {
            nextState = 2
        } else {
            nextState = 1
        }
        guard nextState != punchPlaybackState else { return }
        punchPlaybackState = nextState
        let recordingNow = nextState == 1
        isPunchRecording = recordingNow
        isRecording = recordingNow
        setRecordingMutedTracks(recordingNow ? punchArmedTrackIDs : [])
    }

    private static func trimToPunchRange(_ clip: AudioClip, in track: AudioTrack, _ trim: PunchTrim) {
        let fileEnd = trim.fileTimelineStart + clip.originalDuration
        let start = max(trim.punchIn, trim.fileTimelineStart)
        let end = min(trim.punchOut, fileEnd)
        guard end - start >= 0.02 else {
            // Stopped before reaching the punch range: nothing was punched in.
            track.deleteClip(id: clip.id, removeFile: true)
            return
        }
        clip.setTrim(startTime: start, sourceStartTime: start - trim.fileTimelineStart, duration: end - start)
        clip.setFadeInDuration(punchCrossfadeDuration)
        clip.setFadeOutDuration(punchCrossfadeDuration)
    }

    // MARK: - Transport: Stop

    public func stop(tracks: [AudioTrack]) {
        noteGraphEvent("stop")
        startPlaybackTask?.cancel()
        startPlaybackTask = nil
        playbackRetryTask?.cancel()
        playbackRetryTask = nil
        isStartingPlayback = false
        stopPlayheadTimer()
        guard isPlaying || isRecording else { return }
        // The stop lands a timer tick past the song end flag; recorded clips
        // are cut back to it and the playhead is left on it.
        let songEndCut = isStoppingAtSongEnd ? songEndTime : nil

        stopMetronome()

        // 1. Immediately flag recording as stopped
        let writersToFinalize = captureLock.withLock { () -> [UUID: AudioDiskWriter] in
            self.recordingActiveState = false
            let snapshot = self.writersSnapshot
            self.writersSnapshot = [:]
            return snapshot
        }

        activeWriters.removeAll()

        // 2. Stop the renderers
        stopRenderers()
        setRecordingMutedTracks([])
        punchArmedTrackIDs.removeAll()
        punchPlaybackState = 0
        isPunchRecording = false
        if isRollbackPass {
            isRollbackPass = false
            punchInTime = nil
            punchOutTime = nil
        }
        // Keep AVAudioEngine running during normal transport stop. This is the
        // host's continuous render path and lets Audio Units preserve tails,
        // meters, and GUI-related runtime state between transport operations.

        // 3. Finalize all disk writers and attach URLs to tracks
        let punchTrim = recordingPunchTrim
        recordingPunchTrim = nil
        recordingFinalizationTask = Task { @MainActor [weak self] in
            for (trackId, writer) in writersToFinalize {
                if let savedURL = await writer.finalize() {
                    if let self,
                       let track = tracks.first(where: { $0.id == trackId }) {
                        if let clip = self.activeClips[trackId], clip.fileURL == savedURL {
                            clip.loadMetadata()
                            if let punchTrim {
                                Self.trimToPunchRange(clip, in: track, punchTrim)
                            }
                            if let songEndCut,
                               track.clips.contains(where: { $0 === clip }),
                               clip.startTime + clip.duration > songEndCut,
                               songEndCut - clip.startTime >= 0.02 {
                                clip.setTrim(
                                    startTime: clip.startTime,
                                    sourceStartTime: clip.sourceStartTime,
                                    duration: songEndCut - clip.startTime
                                )
                            }
                        }
                    }
                }
            }
            // Newly recorded clips are added after the previous graph sync.
            // Refresh the playback file cache after their files are finalized.
            // (Only after a recording: a plain stop needs no sync, and one
            // here would rewire at once while effect tails still ring.)
            if let self,
               !writersToFinalize.isEmpty,
               !self.isPlaying,
               !self.isRecording {
                self.syncTracks(tracks, fxChannels: self.syncedFXChannels)
            }
            self?.activeClips.removeAll()
            self?.recordingTakePunchTrim = nil
            self?.hasPendingRecording = false
            self?.recordingFinalizationTask = nil
        }

        stopPlayheadTimer()
        recordingTimingLock.withLock {
            pendingRecordingClipStartTime = nil
        }
        isPlaying = false
        isRecording = false
        if let songEndCut {
            currentTime = songEndCut
        }
        applyDeferredRewiresWhenQuiet()
    }

    public func shutdown() {
        startPlaybackTask?.cancel()
        startPlaybackTask = nil
        playbackRetryTask?.cancel()
        playbackRetryTask = nil
        isStartingPlayback = false
        stopPlayheadTimer()
        stopMetronome()
        loadMonitor.stop()

        captureLock.withLock {
            recordingActiveState = false
            writersSnapshot.removeAll()
        }
        stopRenderers()
        engine.stop()
        // Drained here, not after terminate: (which never returns), so the
        // plug-ins are really disposed while the process still runs.
        autoreleasepool {
            releaseVST3Instances()
            releaseAudioUnits()
        }
        restoreOriginalDefaultDevices()

        isPlaying = false
        isRecording = false
    }

    // VST3 modules must be torn down (instances destroyed, module released so
    // its bundleExit runs) before the process exits; otherwise plug-ins such
    // as Guitar Rig crash in their own static destructors during exit().
    private func releaseVST3Instances() {
        for pluginID in Array(vst3Instances.keys) {
            closePluginWindow(pluginID: pluginID)
        }
        for unit in pluginAudioUnits.values {
            (unit.auAudioUnit as? VST3AudioUnit)?.detachInstance()
        }
        vst3Instances.removeAll()
    }

    // AU plug-ins must also be disposed before exit(): plug-ins that run
    // their own threads (JUCE timers, UADx services) otherwise crash in their
    // static destructors while those threads are still running.
    private func releaseAudioUnits() {
        removeLatencyListeners()
        for pluginID in Array(pluginWindows.keys) {
            closePluginWindow(pluginID: pluginID)
        }
        pluginViewControllers.removeAll()
        pluginStateRestoreTasks.values.forEach { $0.cancel() }
        pluginStateRestoreTasks.removeAll()
        let nodes: [AVAudioNode] = Array(pluginAudioUnits.values) +
            trackPluginNodes.values.flatMap { $0 } +
            fxPluginNodes.values.flatMap { $0 } +
            masterPluginNodes
        for node in nodes {
            safeDisconnectNodeOutput(node)
            safeDisconnectNodeInput(node)
            safeDetach(node)
        }
        pluginAudioUnits.removeAll()
        trackPluginNodes.removeAll()
        fxPluginNodes.removeAll()
        masterPluginNodes.removeAll()
    }

    /// Renders the master output in real time into `url` as a 32-bit float
    /// file at the hardware rate (`ExportEncoder` makes the final file).
    /// Returns that rate. `progress` gets 0...1 as the range is captured.
    @discardableResult
    public func exportMasterMix(
        to url: URL,
        startTime: Double,
        endTime: Double,
        tracks: [AudioTrack],
        fxChannels: [FXChannel],
        progress: ((Double) -> Void)? = nil
    ) async throws -> Double {
        guard !isPlaying && !isRecording else {
            throw NSError(domain: "MyDAW.Export", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Stop playback before exporting.")])
        }
        let start = max(0.0, startTime)
        let end = max(start + 0.01, endTime)
        syncTracks(tracks, fxChannels: fxChannels)
        guard isPluginGraphReady(for: tracks, fxChannels: fxChannels) else {
            throw NSError(domain: "MyDAW.Export", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "Audio plug-ins are still loading. Try again in a moment.")])
        }
        guard let captureNode = masterPluginNodes.last ?? masterOutputNode,
              let format = AVAudioFormat(
                  standardFormatWithSampleRate: hardwareSampleRate,
                  channels: 2
              ) else {
            throw NSError(domain: "MyDAW.Export", code: 3, userInfo: [NSLocalizedDescriptionKey: String(localized: "Could not prepare the master output.")])
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: hardwareSampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let writeQueue = DispatchQueue(label: "MyDAW.master-export", qos: .userInitiated)
        var writeError: Error?
        let previousTime = currentTime

        // The sync above may have restarted the engine; wait until it
        // renders again before scheduling.
        if !engine.isRunning {
            try? engine.start()
        }
        let renderWaitStart = Date()
        let firstRenderTime = captureNode.lastRenderTime?.sampleTime
        while Date().timeIntervalSince(renderWaitStart) < 2.0 {
            if let time = captureNode.lastRenderTime, time.isSampleTimeValid,
               firstRenderTime == nil || time.sampleTime != firstRenderTime {
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        // The tap goes on first; the window opens once the start time is
        // known (after the renderers have read ahead).
        let window = ExportWindow(
            frameCount: AVAudioFramePosition(((end - start) * hardwareSampleRate).rounded()),
            sampleRate: hardwareSampleRate
        )
        captureNode.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, when in
            guard writeError == nil, let slice = window.slice(buffer, at: when) else { return }
            writeQueue.async {
                do {
                    try file.write(from: slice)
                } catch {
                    writeError = error
                }
            }
        }

        // startPlayback picks the start once the renderers have read ahead;
        // `start` is heard then, and the master plug-ins delay it further.
        // The file holds exactly the frames from there to `end`.
        currentTime = start
        let transportStartTime = startPlayback(tracks: tracks, startSec: start)
        window.open(at: transportStartTime.hostTime + Self.hostTicks(masterPluginLatency))

        func finish() {
            captureNode.removeTap(onBus: 0)
            stopRenderers()
            writeQueue.sync { }
            isPlaying = false
            isRecording = false
            currentTime = previousTime
        }
        isPlaying = true

        do {
            let deadline = Date().addingTimeInterval((end - start) + transportPreRoll + masterPluginLatency + 3.0)
            while !window.isComplete && Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
                progress?(window.fraction)
            }
        } catch {
            finish()
            throw error
        }
        let isComplete = window.isComplete
        finish()
        if let writeError { throw writeError }
        guard isComplete else {
            throw NSError(domain: "MyDAW.Export", code: 4, userInfo: [NSLocalizedDescriptionKey: String(localized: "The export ended before the whole range was captured.")])
        }
        return hardwareSampleRate
    }

    // MARK: - Transport: Rewind

    public func rewind(tracks: [AudioTrack], to time: Double = 0.0) {
        let wasPlaying = isPlaying || isRecording
        if wasPlaying {
            stop(tracks: tracks)
        }
        currentTime = max(0.0, time)
        playheadStartOffset = currentTime
        playheadStartTime = Date()
    }

    public func seek(to time: Double, tracks: [AudioTrack], fxChannels: [FXChannel] = []) {
        let wasPlaying = isPlaying || isRecording
        if wasPlaying {
            stop(tracks: tracks)
        }
        currentTime = max(0.0, time)
        playheadStartOffset = currentTime
        playheadStartTime = Date()

        if wasPlaying {
            startPlayOrRecord(tracks: tracks, fxChannels: fxChannels)
        }
    }

    // MARK: - Playhead Timer

    private func startPlayheadTimer(at hostTime: UInt64? = nil) {
        playheadStartTime = Date()
        playheadStartHostTime = hostTime
        playheadStartOffset = currentTime
        hasReachedSongEnd = false

        playheadTimer?.invalidate()
        playheadTimerGeneration += 1
        let generation = playheadTimerGeneration
        playheadTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.playheadTimerGeneration == generation else { return }
                let elapsed: Double
                if let startHostTime = self.playheadStartHostTime {
                    let nowHostTime = mach_absolute_time()
                    let elapsedNanos: UInt64
                    if nowHostTime >= startHostTime {
                        elapsedNanos = AudioConvertHostTimeToNanos(nowHostTime - startHostTime)
                    } else {
                        elapsedNanos = 0
                    }
                    elapsed = Double(elapsedNanos) / 1_000_000_000.0
                } else if let startTime = self.playheadStartTime {
                    elapsed = Date().timeIntervalSince(startTime)
                } else {
                    return
                }
                self.currentTime = self.playheadStartOffset + elapsed
                if let end = self.songEndTime,
                   !self.hasReachedSongEnd,
                   self.playheadStartOffset < end,
                   self.currentTime >= end {
                    self.hasReachedSongEnd = true
                    self.isStoppingAtSongEnd = true
                    self.onReachSongEnd?()
                    self.isStoppingAtSongEnd = false
                }
            }
        }
    }

    private func stopPlayheadTimer() {
        playheadTimer?.invalidate()
        playheadTimer = nil
        playheadTimerGeneration += 1
    }
}

public extension Notification.Name {
    static let audioEngineUpdatedPeaks = Notification.Name("audioEngineUpdatedPeaks")
}

/// Called on an arbitrary thread when a plug-in reports a new latency.
private let pluginLatencyListener: AudioUnitPropertyListenerProc = { context, _, _, _, _ in
    let manager = Unmanaged<AudioEngineManager>.fromOpaque(context).takeUnretainedValue()
    Task { @MainActor in
        manager.pluginLatencyDidChange()
    }
}

/// The frames of a master export: `frameCount` of them, from the one heard
/// at the host time given to `open(at:)`; nothing is kept before that call.
/// Fed from the tap thread.
private final class ExportWindow: @unchecked Sendable {
    private var startHostTime: UInt64?
    private let frameCount: AVAudioFramePosition
    private let sampleRate: Double
    private let lock = NSLock()
    private var written: AVAudioFramePosition = 0
    /// The last tap buffers before `open(at:)`, kept in case the window
    /// starts inside one of them.
    private var held: [(buffer: AVAudioPCMBuffer, when: AVAudioTime)] = []

    init(frameCount: AVAudioFramePosition, sampleRate: Double) {
        self.frameCount = frameCount
        self.sampleRate = sampleRate
    }

    func open(at hostTime: UInt64) {
        lock.withLock { startHostTime = hostTime }
    }

    var isComplete: Bool {
        lock.withLock { written >= frameCount }
    }

    var fraction: Double {
        lock.withLock { frameCount > 0 ? min(1.0, Double(written) / Double(frameCount)) : 1.0 }
    }

    /// The part of `buffer` (starting at `when`) that belongs in the file.
    func slice(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime) -> AVAudioPCMBuffer? {
        guard when.isHostTimeValid, buffer.floatChannelData != nil else { return nil }
        guard let startHostTime = lock.withLock({ self.startHostTime }) else {
            // Not open yet: keep a copy, the window may start in it.
            if let copy = buffer.copy() as? AVAudioPCMBuffer {
                lock.withLock {
                    held.append((copy, when))
                    if held.count > 8 { held.removeFirst() }
                }
            }
            return nil
        }
        let earlier = lock.withLock { () -> [(buffer: AVAudioPCMBuffer, when: AVAudioTime)] in
            defer { held.removeAll() }
            return held
        }
        guard !earlier.isEmpty else { return cut(buffer, at: when, startHostTime: startHostTime) }
        // Held buffers first, then this one, joined into one slice.
        let pieces = (earlier + [(buffer, when)]).compactMap { cut($0.buffer, at: $0.when, startHostTime: startHostTime) }
        guard let first = pieces.first else { return nil }
        let total = pieces.reduce(0) { $0 + Int($1.frameLength) }
        guard let joined = AVAudioPCMBuffer(pcmFormat: first.format, frameCapacity: AVAudioFrameCount(total)),
              let destination = joined.floatChannelData else { return nil }
        var offset = 0
        for piece in pieces {
            guard let data = piece.floatChannelData else { continue }
            for channel in 0..<Int(piece.format.channelCount) {
                (destination[channel] + offset).update(from: data[channel], count: Int(piece.frameLength))
            }
            offset += Int(piece.frameLength)
        }
        joined.frameLength = AVAudioFrameCount(total)
        return joined
    }

    private func cut(_ buffer: AVAudioPCMBuffer, at when: AVAudioTime, startHostTime: UInt64) -> AVAudioPCMBuffer? {
        guard let source = buffer.floatChannelData else { return nil }
        let bufferStart = Double(AudioConvertHostTimeToNanos(when.hostTime)) / 1_000_000_000.0
        let windowStart = Double(AudioConvertHostTimeToNanos(startHostTime)) / 1_000_000_000.0
        let skip = max(0, Int(((windowStart - bufferStart) * sampleRate).rounded()))
        let available = Int(buffer.frameLength) - skip
        guard available > 0 else { return nil }
        let take: Int = lock.withLock {
            let count = min(available, Int(frameCount - written))
            if count > 0 { written += AVAudioFramePosition(count) }
            return count
        }
        guard take > 0,
              let slice = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(take)),
              let destination = slice.floatChannelData else { return nil }
        for channel in 0..<Int(buffer.format.channelCount) {
            destination[channel].update(from: source[channel] + skip, count: take)
        }
        slice.frameLength = AVAudioFrameCount(take)
        return slice
    }
}

/// The master fader level (see `AudioEngineManager.masterVolumeState`).
@MainActor
public final class MasterVolumeState: ObservableObject {
    @Published public var value: Float = 1.0
}

/// The engine's playhead position (see `AudioEngineManager.transportClock`).
@MainActor
public final class TransportClock: ObservableObject {
    @Published public var time: Double = 0.0
}
