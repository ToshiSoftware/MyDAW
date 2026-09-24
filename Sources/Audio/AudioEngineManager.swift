import Foundation
import AVFoundation
import AppKit
import CoreAudioKit

private final class VST3BusProcessor {
    private let instances: [VST3NativeInstance]
    private let maxFrames: Int
    private let outputFormat: AVAudioFormat
    private let queueCapacity: Int
    private var queue: [Float]
    private var inputQueue: [Float]
    private var readFrame = 0
    private var writeFrame = 0
    private var queuedFrames = 0
    private var inputReadFrame = 0
    private var inputWriteFrame = 0
    private var inputQueuedFrames = 0
    private let lock = NSLock()
    private var inputBuffer: [Float]
    private var outputBuffer: [Float]
    private let processingQueue = DispatchQueue(label: "MyDAW.vst3-bus-processing", qos: .userInitiated)
    private let processingSignal = DispatchSemaphore(value: 0)
    private var isStopped = false

    lazy var inputNode: AVAudioSinkNode = AVAudioSinkNode { [weak self] _, frameCount, audioBufferList in
        guard let self else { return noErr }
        self.receive(frameCount: Int(frameCount), audioBufferList: audioBufferList)
        return noErr
    }

    lazy var outputNode: AVAudioSourceNode = AVAudioSourceNode(format: outputFormat) { [weak self] _, _, frameCount, audioBufferList in
        guard let self else { return noErr }
        self.provide(frameCount: Int(frameCount), audioBufferList: audioBufferList)
        return noErr
    }

    init?(instances: [VST3NativeInstance], format: AVAudioFormat, maxFrames: Int) {
        guard !instances.isEmpty, format.channelCount == 2, maxFrames > 0 else { return nil }
        self.instances = instances
        self.maxFrames = maxFrames
        self.outputFormat = format
        self.queueCapacity = maxFrames * 32
        self.queue = Array(repeating: 0.0, count: maxFrames * 32 * 2)
        self.inputQueue = Array(repeating: 0.0, count: maxFrames * 32 * 2)
        self.inputBuffer = Array(repeating: 0.0, count: maxFrames * 2)
        self.outputBuffer = Array(repeating: 0.0, count: maxFrames * 2)
        processingQueue.async { [weak self] in
            self?.processLoop()
        }
    }

    deinit {
        lock.lock()
        isStopped = true
        lock.unlock()
        processingSignal.signal()
    }

    private func receive(frameCount: Int, audioBufferList: UnsafePointer<AudioBufferList>) {
        guard frameCount > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        guard buffers.count >= 2,
              let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }

        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }
        let shouldSignal = inputQueuedFrames == 0
        for frame in 0..<frameCount {
            if inputQueuedFrames == queueCapacity {
                inputReadFrame = (inputReadFrame + 1) % queueCapacity
                inputQueuedFrames -= 1
            }
            let queueIndex = inputWriteFrame * 2
            inputQueue[queueIndex] = left[frame]
            inputQueue[queueIndex + 1] = right[frame]
            inputWriteFrame = (inputWriteFrame + 1) % queueCapacity
            inputQueuedFrames += 1
        }
        lock.unlock()
        if shouldSignal {
            processingSignal.signal()
        }
    }

    private func processLoop() {
        while true {
            processingSignal.wait()
            lock.lock()
            if isStopped {
                lock.unlock()
                return
            }
            let frames = min(maxFrames, inputQueuedFrames)
            for frame in 0..<frames {
                let queueIndex = inputReadFrame * 2
                inputBuffer[frame * 2] = inputQueue[queueIndex]
                inputBuffer[frame * 2 + 1] = inputQueue[queueIndex + 1]
                inputReadFrame = (inputReadFrame + 1) % queueCapacity
            }
            inputQueuedFrames -= frames
            lock.unlock()

            guard frames > 0 else { continue }
            var processed = true
            for instance in instances {
                let result = inputBuffer.withUnsafeBufferPointer { input in
                    outputBuffer.withUnsafeMutableBufferPointer { output in
                        guard let inputBase = input.baseAddress,
                              let outputBase = output.baseAddress else { return false }
                        return instance.processInterleaved(
                            inputBase,
                            output: outputBase,
                            frames: frames
                        )
                    }
                }
                guard result else {
                    processed = false
                    break
                }
                inputBuffer.replaceSubrange(0..<(frames * 2), with: outputBuffer[0..<(frames * 2)])
            }
            guard processed else { continue }

            lock.lock()
            for frame in 0..<frames {
                if queuedFrames == queueCapacity {
                    readFrame = (readFrame + 1) % queueCapacity
                    queuedFrames -= 1
                }
                let queueIndex = writeFrame * 2
                queue[queueIndex] = inputBuffer[frame * 2]
                queue[queueIndex + 1] = inputBuffer[frame * 2 + 1]
                writeFrame = (writeFrame + 1) % queueCapacity
                queuedFrames += 1
            }
            let hasPendingInput = inputQueuedFrames > 0
            lock.unlock()
            if hasPendingInput {
                processingSignal.signal()
            }
        }
    }

    private func provide(frameCount: Int, audioBufferList: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        guard buffers.count >= 2,
              let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }

        lock.lock()
        for frame in 0..<frameCount {
            if queuedFrames > 0 {
                let queueIndex = readFrame * 2
                left[frame] = queue[queueIndex]
                right[frame] = queue[queueIndex + 1]
                readFrame = (readFrame + 1) % queueCapacity
                queuedFrames -= 1
            } else {
                left[frame] = 0.0
                right[frame] = 0.0
            }
        }
        lock.unlock()
    }
}

private final class VST3StreamingClip {
    private let player: AVAudioPlayerNode
    private let file: AVAudioFile
    private let instances: [VST3NativeInstance]
    private let outputFormat: AVAudioFormat
    private let gain: Float
    private let clipDuration: Double
    private let fadeInDuration: Double
    private let fadeOutDuration: Double
    private var sourceFrame: AVAudioFramePosition
    private var timelineOffset: Double
    private let endFrame: AVAudioFramePosition
    private let chunkFrames = 512
    private let schedulingQueue = DispatchQueue(label: "MyDAW.vst3-streaming-clip", qos: .userInitiated)
    private let stateLock = NSLock()
    private var isFinished = false

    init?(
        player: AVAudioPlayerNode,
        fileURL: URL,
        instances: [VST3NativeInstance],
        outputFormat: AVAudioFormat,
        sourceStartTime: Double,
        clipOffset: Double,
        clipDuration: Double,
        gainDB: Double,
        fadeInDuration: Double,
        fadeOutDuration: Double
    ) {
        guard let file = try? AVAudioFile(forReading: fileURL) else { return nil }
        self.player = player
        self.file = file
        self.instances = instances
        self.outputFormat = outputFormat
        self.gain = Float(pow(10.0, gainDB / 20.0))
        self.clipDuration = clipDuration
        self.fadeInDuration = fadeInDuration
        self.fadeOutDuration = fadeOutDuration
        self.sourceFrame = AVAudioFramePosition((sourceStartTime + clipOffset) * file.processingFormat.sampleRate)
        self.timelineOffset = clipOffset
        self.endFrame = AVAudioFramePosition((sourceStartTime + clipDuration) * file.processingFormat.sampleRate)
    }

    func start(at startTime: AVAudioTime) {
        schedulingQueue.sync {
            for index in 0..<8 {
                let bufferStartTime: AVAudioTime? = index == 0
                    ? startTime
                    : nil
                guard scheduleNext(at: bufferStartTime) else { break }
            }
        }
        player.play(at: startTime)
    }

    func stop() {
        stateLock.withLock {
            isFinished = true
        }
        player.stop()
    }

    @discardableResult
    private func scheduleNext(at startTime: AVAudioTime?) -> Bool {
        guard stateLock.withLock({ !isFinished }), sourceFrame < endFrame else {
            stateLock.withLock { isFinished = true }
            return false
        }

        let sourceFramesRemaining = endFrame - sourceFrame
        let sourceFrames = min(
            AVAudioFramePosition(Double(chunkFrames) * file.processingFormat.sampleRate / outputFormat.sampleRate),
            sourceFramesRemaining
        )
        guard sourceFrames > 0,
              let inputBuffer = AVAudioPCMBuffer(
                  pcmFormat: file.processingFormat,
                  frameCapacity: AVAudioFrameCount(sourceFrames)
              ) else {
            stateLock.withLock { isFinished = true }
            return false
        }

        file.framePosition = sourceFrame
        do {
            try file.read(into: inputBuffer, frameCount: AVAudioFrameCount(sourceFrames))
        } catch {
            stateLock.withLock { isFinished = true }
            return false
        }
        guard let inputChannels = inputBuffer.floatChannelData,
              let outputBuffer = AVAudioPCMBuffer(
                  pcmFormat: outputFormat,
                  frameCapacity: AVAudioFrameCount(inputBuffer.frameLength)
              ),
              let outputChannels = outputBuffer.floatChannelData else {
                        stateLock.withLock { isFinished = true }
                        return false
        }

        let frames = Int(inputBuffer.frameLength)
        outputBuffer.frameLength = inputBuffer.frameLength
        var interleavedInput = [Float](repeating: 0.0, count: frames * 2)
        var interleavedOutput = [Float](repeating: 0.0, count: frames * 2)
        for frame in 0..<frames {
            let position = timelineOffset + Double(frame) / outputFormat.sampleRate
            let fadeInGain = fadeInDuration > 0.0 ? min(1.0, max(0.0, position / fadeInDuration)) : 1.0
            let fadeOutGain = fadeOutDuration > 0.0 ? min(1.0, max(0.0, (clipDuration - position) / fadeOutDuration)) : 1.0
            let frameGain = gain * Float(min(fadeInGain, fadeOutGain))
            interleavedInput[frame * 2] = inputChannels[0][frame] * frameGain
            interleavedInput[frame * 2 + 1] = (inputBuffer.format.channelCount > 1 ? inputChannels[1][frame] : inputChannels[0][frame]) * frameGain
        }
        var processed = true
        for instance in instances {
            let nextOutput = interleavedInput.withUnsafeBufferPointer { input in
                interleavedOutput.withUnsafeMutableBufferPointer { output in
                    instance.processInterleaved(input.baseAddress!, output: output.baseAddress!, frames: frames)
                }
            }
            guard nextOutput else {
                processed = false
                break
            }
            interleavedInput = interleavedOutput
        }
        guard processed else {
            stateLock.withLock { isFinished = true }
            return false
        }
        for frame in 0..<frames {
            outputChannels[0][frame] = interleavedOutput[frame * 2]
            outputChannels[1][frame] = interleavedOutput[frame * 2 + 1]
        }

        sourceFrame += AVAudioFramePosition(frames)
        timelineOffset += Double(frames) / outputFormat.sampleRate
        player.scheduleBuffer(outputBuffer, at: startTime, options: []) { [weak self] in
            guard let self else { return }
            self.schedulingQueue.async {
                _ = self.scheduleNext(at: nil)
            }
        }
        return true
    }
}

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
public final class AudioEngineManager: ObservableObject {
    public let engine = AVAudioEngine()

    @Published public var isPlaying: Bool = false
    @Published public var isRecording: Bool = false
    @Published public private(set) var isPunchRecording: Bool = false
    @Published public private(set) var isStartingPlayback: Bool = false
    @Published public var currentTime: Double = 0.0 // Playhead in seconds
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

    @Published public var masterVolume: Float = 1.0 {
        didSet {
            masterOutputNode?.outputVolume = masterVolume
        }
    }
    @Published public var masterPeak: Float = 0.0
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

    // Player node and file mapping per track ID
    private var playerNodes: [UUID: AVAudioPlayerNode] = [:]
    private var clipPlayerNodes: [UUID: AVAudioPlayerNode] = [:]
    private var sendPlayerNodes: [UUID: AVAudioPlayerNode] = [:]
    private var sendClipPlayerNodes: [String: AVAudioPlayerNode] = [:]
    private var mutedClipVolumes: [String: Float] = [:]
    private var trackMeterTaps: Set<UUID> = []
    private var trackOutputNodes: [UUID: AVAudioMixerNode] = [:]
    private var audioFiles: [UUID: [(clip: AudioClip, file: AVAudioFile)]] = [:]
    private var trackPluginNodes: [UUID: [AVAudioNode]] = [:]
    private var trackPluginLatencies: [UUID: Double] = [:]
    private var fxInputNodes: [UUID: AVAudioMixerNode] = [:]
    private var fxPluginNodes: [UUID: [AVAudioNode]] = [:]
    private var fxVSTProcessors: [UUID: VST3BusProcessor] = [:]
    private var fxGraphSignatures: [UUID: [UUID]] = [:]
    private var sendGainNodes: [UUID: AVAudioMixerNode] = [:]
    private var pluginAudioUnits: [UUID: AVAudioUnit] = [:]
    private var vst3Instances: [UUID: VST3NativeInstance] = [:]
    private var vst3UIInstances: [UUID: VST3NativeInstance] = [:]
    private var vst3StreamingClips: [UUID: VST3StreamingClip] = [:]
    private var fxVSTStreamingClips: [String: VST3StreamingClip] = [:]
    private var pendingVST3StartTimes: [String: AVAudioTime] = [:]
    private var fxVSTPluginsByChannelID: [UUID: [TrackPluginDescriptor]] = [:]
    private var syncedFXChannels: [FXChannel] = []
    private var pluginWindows: [UUID: NSWindow] = [:]
    private let masterChannelID = UUID()
    private var masterOutputNode: AVAudioMixerNode?
    private var masterPluginNodes: [AVAudioNode] = []
    private var masterVSTProcessor: VST3BusProcessor?
    private var masterPluginSignature: [UUID] = []
    private var masterPluginGraphGeneration = 0
    private var configuredMasterPlugins: [TrackPluginDescriptor] = []

    private func supportsRealtimeVST3(_ descriptor: TrackPluginDescriptor) -> Bool {
        // VST3 bus processing is not used. VST3 effects are rendered per
        // scheduled clip, matching the stable track-plugin path.
        return false
    }
    private var masterPluginIDs: Set<UUID> = []
    private var pluginDescriptors: [UUID: TrackPluginDescriptor] = [:]
    private var savedPluginStates: [UUID: Data] = [:]
    private var pluginStateRestoreTasks: [UUID: Task<Void, Never>] = [:]
    private var pluginUIRequests: Set<UUID> = []
    private var pendingPluginUIRequests: Set<UUID> = []
    private var hasWarmedUpAudioGraph = false
    private let pluginUIRequestQueue = DispatchQueue(
        label: "MyDAW.plugin-ui-request",
        qos: .userInitiated
    )
    private let pluginStateRestoreQueue = DispatchQueue(
        label: "MyDAW.plugin-state-restore",
        qos: .utility
    )
    private var pluginGraphGenerations: [UUID: Int] = [:]
    private var pluginGraphSignatures: [UUID: [UUID]] = [:]
    private var fxPluginGraphGenerations: [UUID: Int] = [:]

    public func isPluginUnavailable(_ pluginID: UUID) -> Bool {
        unavailablePluginIDs.contains(pluginID)
    }

    private func markPluginUnavailable(_ pluginID: UUID) {
        unavailablePluginIDs.insert(pluginID)
    }

    // Active disk writers during recording
    private var activeWriters: [UUID: AudioDiskWriter] = [:]
    private var activeClips: [UUID: AudioClip] = [:]

    // Thread-safe capture configuration passed to real-time audio thread
    private let captureLock = NSLock()
    private var captureConfigs: [TrackCaptureConfig] = []
    private var writersSnapshot: [UUID: AudioDiskWriter] = [:]
    private var recordingActiveState: Bool = false
    private let recordingTimingLock = NSLock()
    private var recordingTimelineStart: Double = 0.0
    private var recordingTransportStartHostTime: UInt64?
    private var punchInTime: Double?
    private var punchOutTime: Double?
    private var punchArmedTrackIDs: Set<UUID> = []
    private var punchPlaybackState: Int = 0
    private var pendingRecordingClipStartTime: Double?
    private var hasLoggedFirstRecordingInput = false

    // Realtime channel peak levels written by audio thread, read by 60Hz UI timer
    private let peakLock = NSLock()
    private var rawChannelPeaks: [Float] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
    private var masterOutputPeak: Float = 0.0
    private var trackOutputPeaks: [UUID: Float] = [:]
    private var liveWaveformPeaksBuffer: [UUID: [[(min: Float, max: Float)]]] = [:]

    // Timers
    private var playheadTimer: Timer?
    private var playheadStartTime: Date?
    private var playheadStartHostTime: UInt64?
    private var playheadStartOffset: Double = 0.0

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
    private var recordingFinalizationTask: Task<Void, Never>?

    private var masterPluginLatency: Double {
        masterPluginNodes
            .compactMap { ($0 as? AVAudioUnit)?.auAudioUnit.latency }
            .filter { $0.isFinite && $0 > 0.0 }
            .reduce(0.0, +)
    }

    public init() {
        self.recordingsDirectory = Self.resolveRecordingsDirectory()
        setupEngine()
        startMeterTimer()
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
        panel.title = "Choose Recordings Folder"
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
        let hwSampleRate = inputFormat.sampleRate > 0 ? inputFormat.sampleRate : 44100.0
        self.hardwareSampleRate = hwSampleRate
        self.sampleRate = hwSampleRate

        let masterNode = AVAudioMixerNode()
        engine.attach(masterNode)
        masterOutputNode = masterNode
        if let masterFormat = AVAudioFormat(standardFormatWithSampleRate: hwSampleRate, channels: 2) {
            engine.disconnectNodeOutput(mixer)
            engine.connect(mixer, to: masterNode, format: masterFormat)
            engine.connect(masterNode, to: engine.outputNode, format: masterFormat)
            masterNode.outputVolume = masterVolume

            mixer.removeTap(onBus: 0)
            mixer.installTap(onBus: 0, bufferSize: 512, format: masterFormat) { [weak self] buffer, _ in
                guard let channelData = buffer.floatChannelData else { return }
                var peak: Float = 0.0
                let channelCount = Int(buffer.format.channelCount)
                for channel in 0..<channelCount {
                    let samples = channelData[channel]
                    for index in 0..<Int(buffer.frameLength) {
                        peak = max(peak, abs(samples[index]))
                    }
                }
                self?.peakLock.withLock {
                    self?.masterOutputPeak = max(self?.masterOutputPeak ?? 0.0, peak)
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

        // Install tap BEFORE engine.start()
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: AVAudioFrameCount(inputBufferFrameSize), format: inputFormat) { [weak self] (buffer, time) in
            self?.processInputAudioBuffer(buffer: buffer, time: time)
        }

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
        punchInTime = enabled ? startTime : nil
        punchOutTime = enabled ? endTime : nil
    }

    /// Primes the hardware render path before restoring an asynchronous AU graph.
    /// Some Audio Units assume that the host has already prepared its output
    /// route, even though AVAudioEngine reports itself as running.
    public func prepareForPluginGraphRestore() {
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                print("Failed to start audio engine before plugin restore: \(error)")
                return
            }
        }
        engine.prepare()
    }

    public func setSavedPluginStates(_ states: [PluginStateDocument]) {
        savedPluginStates = states.reduce(into: [:]) { result, state in
            result[state.pluginID] = state.stateData
        }
    }

    public func capturePluginStates() -> [PluginStateDocument] {
        let auStates: [PluginStateDocument] = pluginAudioUnits.compactMap { entry in
            let (pluginID, audioUnit) = entry
            guard let state = audioUnit.auAudioUnit.fullStateForDocument else { return nil }
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

    private func syncVST3Instances(for descriptors: [TrackPluginDescriptor]) {
        let vst3Descriptors = descriptors.filter { $0.kind == .vst3 && $0.enabled }
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
        guard let data = savedPluginStates[pluginID] else { return }
        pluginStateRestoreTasks[pluginID]?.cancel()
        pluginStateRestoreTasks[pluginID] = Task { @MainActor [weak self] in
            // Let the running engine render before applying a document state.
            // This avoids racing AU initialization with state restoration.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self,
                  !Task.isCancelled,
                  let currentAudioUnit = self.pluginAudioUnits[pluginID],
                  currentAudioUnit === audioUnit else { return }
            self.pluginStateRestoreQueue.async { [weak self] in
                do {
                    let propertyList = try PropertyListSerialization.propertyList(
                        from: data,
                        options: [],
                        format: nil
                    )
                    guard let state = propertyList as? [String: Any] else {
                        print("Invalid saved state for plugin \(pluginID)")
                        return
                    }
                    print("Restoring saved state for plugin \(pluginID)")
                    audioUnit.auAudioUnit.fullStateForDocument = state
                    print("Restored saved state for plugin \(pluginID)")
                } catch {
                    print("Failed to restore state for plugin \(pluginID): \(error)")
                }
                Task { @MainActor [weak self] in
                    self?.pluginStateRestoreTasks.removeValue(forKey: pluginID)
                }
            }
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

    public func applyAudioDevices(inputDeviceID: AudioDeviceID, outputDeviceID: AudioDeviceID) -> Bool {
        guard !isPlaying && !isRecording else { return false }
        engine.stop()

        var inputID = inputDeviceID
        var outputID = outputDeviceID
        var applied = true
        if let inputUnit = engine.inputNode.audioUnit, inputID != 0 {
            let status = AudioUnitSetProperty(
                inputUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &inputID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            applied = applied && status == noErr
        }
        if let outputUnit = engine.outputNode.audioUnit, outputID != 0 {
            let status = AudioUnitSetProperty(
                outputUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &outputID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            applied = applied && status == noErr
        }
        guard applied else { return false }
        selectedInputDeviceID = inputDeviceID
        selectedOutputDeviceID = outputDeviceID
        setupEngine()
        return true
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
        let beatPosition = currentTime / interval
        let nearestBeat = round(beatPosition)
        let isOnBeat = abs(beatPosition - nearestBeat) < 0.0001
        let nextBeatPosition = isOnBeat ? nearestBeat : ceil(beatPosition)
        let timingOffset = metronomeTimingOffsetMs / 1000.0
        let delay = max(0.0, (nextBeatPosition * interval) - currentTime + timingOffset)
        let transportStartTime = sharedStartTime ?? AVAudioTime(
            hostTime: mach_absolute_time() + AudioConvertNanosToHostTime(50_000_000)
        )
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

        let punchPosition: Double? = recordingTimingLock.withLock {
            guard let transportHostTime = recordingTransportStartHostTime,
                  time.isHostTimeValid else { return nil }
            let elapsed = Double(
                AudioConvertHostTimeToNanos(
                    time.hostTime >= transportHostTime
                        ? time.hostTime - transportHostTime
                        : 0
                )
            ) / 1_000_000_000.0
            return recordingTimelineStart + elapsed
        }
        if let punchPosition {
            if let punchInTime, punchPosition < punchInTime { return }
            if let punchOutTime, punchPosition >= punchOutTime {
                return
            }
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

        let inputFrameOffset = 0
        let capturedFrameLength = frameLength

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
                    self.masterOutputPeak = 0.0
                    return peak
                }
                self.masterPeak = max(self.masterPeak * 0.85, outputMasterPeak)

                let outputPeaks = self.peakLock.withLock {
                    let values = self.trackOutputPeaks
                    self.trackOutputPeaks.removeAll(keepingCapacity: true)
                    return values
                }

                // Notify ProjectState to update track input meters
                MyDAWNotificationCenter.shared.post(
                    name: .audioEngineUpdatedPeaks,
                    object: nil,
                    userInfo: [
                        "peaks": peaks,
                        "liveChannelWaveforms": livePeaks,
                        "outputPeaks": outputPeaks
                    ]
                )
            }
        }
    }

    // MARK: - Track Synchronization

    public func syncTracks(_ tracks: [AudioTrack]) {
        syncFXChannels([])
        syncTracks(tracks, fxChannels: [])
    }

    public func syncTracks(_ tracks: [AudioTrack], fxChannels: [FXChannel]) {
        syncedFXChannels = fxChannels
        let allPlugins = tracks.flatMap(\.plugins) + fxChannels.flatMap(\.plugins) + configuredMasterPlugins
        let activePluginIDs = Set(allPlugins.map(\.id))
        let removedPluginIDs = Set(pluginDescriptors.keys).subtracting(activePluginIDs)
        for pluginID in removedPluginIDs {
            closePluginWindow(pluginID: pluginID)
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
        for input in fxInputNodes.values {
            engine.disconnectNodeInput(input)
        }
        let activeSendIDs = Set(tracks.flatMap { $0.fxSends.filter { $0.enabled && $0.level > 0 }.map(\.id) })
        for (sendID, gainNode) in sendGainNodes where !activeSendIDs.contains(sendID) {
            engine.disconnectNodeOutput(gainNode)
            engine.detach(gainNode)
            sendGainNodes.removeValue(forKey: sendID)
        }
        for (sendID, player) in sendPlayerNodes where !activeSendIDs.contains(sendID) {
            player.stop()
            engine.disconnectNodeOutput(player)
            engine.detach(player)
            sendPlayerNodes.removeValue(forKey: sendID)
            for key in fxVSTStreamingClips.keys where key.hasPrefix("fx:\(sendID.uuidString):") {
                fxVSTStreamingClips.removeValue(forKey: key)?.stop()
            }
        }
        let currentTrackIDs = Set(tracks.map { $0.id })
        let currentClipIDs = Set(tracks.flatMap { $0.clips.map(\.id) })
        let currentSendClipKeys = Set(tracks.flatMap { track in
            track.fxSends.filter { $0.enabled && $0.level > 0 }.flatMap { send in
                track.clips.map { sendClipKey(sendID: send.id, clipID: $0.id) }
            }
        })

        for (id, node) in clipPlayerNodes where !currentClipIDs.contains(id) {
            node.stop()
            vst3StreamingClips.removeValue(forKey: id)?.stop()
            for key in fxVSTStreamingClips.keys where key.hasSuffix(":\(id.uuidString)") {
                fxVSTStreamingClips.removeValue(forKey: key)?.stop()
            }
            engine.disconnectNodeOutput(node)
            engine.detach(node)
            clipPlayerNodes.removeValue(forKey: id)
        }
        for (key, node) in sendClipPlayerNodes where !currentSendClipKeys.contains(key) {
            node.stop()
            engine.disconnectNodeOutput(node)
            engine.detach(node)
            sendClipPlayerNodes.removeValue(forKey: key)
        }

        for (id, node) in playerNodes where !currentTrackIDs.contains(id) {
            engine.disconnectNodeOutput(node)
            engine.detach(node)
            playerNodes.removeValue(forKey: id)
            if let outputNode = trackOutputNodes.removeValue(forKey: id) {
                engine.disconnectNodeOutput(outputNode)
                engine.detach(outputNode)
            }
            audioFiles.removeValue(forKey: id)
            trackPluginLatencies.removeValue(forKey: id)
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

        let anySolo = tracks.contains { $0.isSoloed }

        for track in tracks {
            var player = playerNodes[track.id]
            if player == nil {
                let newNode = AVAudioPlayerNode()
                engine.attach(newNode)
                playerNodes[track.id] = newNode
                player = newNode
            }

            guard let node = player else { continue }

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
                engine.connect(node, to: outputNode, format: format)
            }
            if !trackMeterTaps.contains(track.id) {
                outputNode.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, _ in
                    guard let channelData = buffer.floatChannelData else { return }
                    var peak: Float = 0.0
                    let channelCount = Int(buffer.format.channelCount)
                    for channel in 0..<channelCount {
                        let samples = channelData[channel]
                        for index in 0..<Int(buffer.frameLength) {
                            peak = max(peak, abs(samples[index]))
                        }
                    }
                    self?.peakLock.withLock {
                        let previous = self?.trackOutputPeaks[track.id] ?? 0.0
                        self?.trackOutputPeaks[track.id] = max(previous, peak)
                    }
                }
                trackMeterTaps.insert(track.id)
            }
            // VST3 descriptors are persisted and shown in the mixer, but are
            // bypassed until their native processing host is connected.
            let enabledPlugins = track.plugins.filter { $0.enabled && $0.kind == .au }
            let desiredSignature = enabledPlugins.map(\.id)
            let existingSignature = pluginGraphSignatures[track.id]
            let graphNeedsRebuild = existingSignature != desiredSignature

            if graphNeedsRebuild {
                let wasEngineRunning = engine.isRunning
                if wasEngineRunning {
                    engine.pause()
                }
                let previousNodes = trackPluginNodes[track.id] ?? []
                for pluginNode in previousNodes {
                    engine.disconnectNodeOutput(pluginNode)
                    engine.detach(pluginNode)
                }
                trackPluginNodes[track.id] = []
                trackPluginLatencies[track.id] = 0.0
                pluginGraphGenerations[track.id, default: 0] += 1
                let graphGeneration = pluginGraphGenerations[track.id] ?? 0
                pluginGraphSignatures[track.id] = desiredSignature

                engine.disconnectNodeOutput(outputNode)
                engine.connect(outputNode, to: engine.mainMixerNode, format: format)
                if !enabledPlugins.isEmpty {
                    installAudioUnits(
                        enabledPlugins,
                        for: track.id,
                        previousNode: outputNode,
                        format: format,
                        index: 0,
                        generation: graphGeneration
                    )
                }
                if wasEngineRunning {
                    try? engine.start()
                }
            }

            engine.disconnectNodeOutput(outputNode)
            if enabledPlugins.isEmpty {
                engine.connect(outputNode, to: engine.mainMixerNode, format: format)
            } else if let firstPlugin = trackPluginNodes[track.id]?.first {
                engine.connect(outputNode, to: firstPlugin, format: format)
            }

            for send in track.fxSends where send.enabled && send.level > 0 {
                guard let fxInput = fxInputNodes[send.fxChannelID] else { continue }
                let gainNode: AVAudioMixerNode
                if let existing = sendGainNodes[send.id] {
                    gainNode = existing
                } else {
                    gainNode = AVAudioMixerNode()
                    engine.attach(gainNode)
                    sendGainNodes[send.id] = gainNode
                }
                gainNode.outputVolume = send.level
                let inputBus = fxInput.nextAvailableInputBus
                let sendPlayer: AVAudioPlayerNode
                if let existing = sendPlayerNodes[send.id] {
                    sendPlayer = existing
                } else {
                    sendPlayer = AVAudioPlayerNode()
                    engine.attach(sendPlayer)
                    sendPlayerNodes[send.id] = sendPlayer
                }
                sendPlayer.volume = effectiveTrackVolume(for: track, anySolo: anySolo)
                engine.disconnectNodeOutput(sendPlayer)
                engine.connect(sendPlayer, to: gainNode, format: format)
                engine.connect(gainNode, to: fxInput, fromBus: 0, toBus: inputBus, format: format)
                for clip in track.clips {
                    let key = sendClipKey(sendID: send.id, clipID: clip.id)
                    let sendClipPlayer: AVAudioPlayerNode
                    if let existing = sendClipPlayerNodes[key] {
                        sendClipPlayer = existing
                    } else {
                        sendClipPlayer = AVAudioPlayerNode()
                        engine.attach(sendClipPlayer)
                        sendClipPlayerNodes[key] = sendClipPlayer
                    }
                    sendClipPlayer.volume = effectiveTrackVolume(for: track, anySolo: anySolo) *
                        Float(pow(10.0, clip.gainDB / 20.0))
                    engine.disconnectNodeOutput(sendClipPlayer)
                    engine.connect(sendClipPlayer, to: gainNode, format: format)
                }
            }

            let effectiveVolume = effectiveTrackVolume(for: track, anySolo: anySolo)
            node.volume = effectiveVolume
            node.pan = track.pan
            outputNode.outputVolume = effectiveVolume
            outputNode.pan = track.pan

            var filesForTrack: [(clip: AudioClip, file: AVAudioFile)] = []
            for clip in track.clips {
                if let file = try? AVAudioFile(forReading: clip.fileURL) {
                    filesForTrack.append((clip: clip, file: file))
                }
            }
            filesForTrack.sort { left, right in
                if left.clip.startTime == right.clip.startTime {
                    return left.clip.id.uuidString < right.clip.id.uuidString
                }
                return left.clip.startTime < right.clip.startTime
            }
            audioFiles[track.id] = filesForTrack

            for clip in track.clips {
                let clipNode: AVAudioPlayerNode
                if let existing = clipPlayerNodes[clip.id] {
                    clipNode = existing
                } else {
                    clipNode = AVAudioPlayerNode()
                    engine.attach(clipNode)
                    clipPlayerNodes[clip.id] = clipNode
                }
                clipNode.volume = 1.0
                engine.disconnectNodeOutput(clipNode)
                engine.connect(clipNode, to: outputNode, format: format)
            }
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

    public func syncAfterClipEdit(_ tracks: [AudioTrack], fxChannels: [FXChannel] = []) {
        if isPlaying && !isRecording {
            syncTracks(tracks, fxChannels: fxChannels)
            reschedulePlayback(tracks: tracks)
        } else {
            syncTracks(tracks, fxChannels: fxChannels)
        }
    }

    public func updateMixerLevels(
        tracks: [AudioTrack],
        fxChannels: [FXChannel]
    ) {
        let anySolo = tracks.contains { $0.isSoloed }
        for track in tracks {
            let level = effectiveTrackVolume(for: track, anySolo: anySolo)
            playerNodes[track.id]?.volume = level
            playerNodes[track.id]?.pan = track.pan
            trackOutputNodes[track.id]?.outputVolume = level
            trackOutputNodes[track.id]?.pan = track.pan
            for clip in track.clips {
                clipPlayerNodes[clip.id]?.volume = 1.0
            }

            for send in track.fxSends {
                sendPlayerNodes[send.id]?.volume = level
                sendGainNodes[send.id]?.outputVolume = send.enabled ? send.level : 0.0
                for clip in track.clips {
                    let key = sendClipKey(sendID: send.id, clipID: clip.id)
                    sendClipPlayerNodes[key]?.volume = level
                }
            }
        }

        for channel in fxChannels {
            fxInputNodes[channel.id]?.outputVolume = channel.volume
            fxInputNodes[channel.id]?.pan = channel.pan
        }
    }

    public func setClipMuted(_ clipID: UUID, muted: Bool) {
        let mainKey = clipID.uuidString
        if let player = clipPlayerNodes[clipID] {
            if muted {
                if mutedClipVolumes[mainKey] == nil {
                    mutedClipVolumes[mainKey] = player.volume
                }
                player.volume = 0.0
            } else {
                player.volume = mutedClipVolumes.removeValue(forKey: mainKey) ?? 1.0
            }
        }

        for (key, player) in sendClipPlayerNodes where key.hasSuffix(":\(clipID.uuidString)") {
            let volumeKey = "send:\(key)"
            if muted {
                if mutedClipVolumes[volumeKey] == nil {
                    mutedClipVolumes[volumeKey] = player.volume
                }
                player.volume = 0.0
            } else {
                player.volume = mutedClipVolumes.removeValue(forKey: volumeKey) ?? 1.0
            }
        }
    }

    public func updateSendLevel(
        track: AudioTrack,
        send: FXSend,
        fxChannel: FXChannel,
        anySolo: Bool
    ) {
        guard let fxInput = fxInputNodes[fxChannel.id],
              let format = AVAudioFormat(
                  standardFormatWithSampleRate: hardwareSampleRate,
                  channels: 2
              ) else { return }

        let gainNode: AVAudioMixerNode
        if let existing = sendGainNodes[send.id] {
            gainNode = existing
        } else {
            gainNode = AVAudioMixerNode()
            engine.attach(gainNode)
            sendGainNodes[send.id] = gainNode
        }
        gainNode.outputVolume = send.enabled ? send.level : 0.0

        let sendPlayer: AVAudioPlayerNode
        if let existing = sendPlayerNodes[send.id] {
            sendPlayer = existing
        } else {
            sendPlayer = AVAudioPlayerNode()
            engine.attach(sendPlayer)
            sendPlayerNodes[send.id] = sendPlayer
            sendPlayer.volume = effectiveTrackVolume(for: track, anySolo: anySolo)
            engine.connect(sendPlayer, to: gainNode, format: format)
            engine.connect(
                gainNode,
                to: fxInput,
                fromBus: 0,
                toBus: fxInput.nextAvailableInputBus,
                format: format
            )
            if isPlaying {
                let sharedStartTime = AVAudioTime(
                    hostTime: mach_absolute_time() + AudioConvertNanosToHostTime(50_000_000)
                )
                scheduleClips(
                    for: track,
                    player: sendPlayer,
                    startSec: currentTime,
                    sharedStartTime: sharedStartTime,
                    sendID: send.id,
                    fxChannelID: send.fxChannelID
                )
            }
        }
        sendPlayer.volume = effectiveTrackVolume(for: track, anySolo: anySolo)
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
        configuredMasterPlugins = plugins
        masterPluginIDs = Set(plugins.map(\.id))
        for plugin in plugins {
            pluginDescriptors[plugin.id] = plugin
        }
        guard let masterOutputNode,
              let format = AVAudioFormat(standardFormatWithSampleRate: hardwareSampleRate, channels: 2) else { return }
        let enabledPlugins = plugins.filter(\.enabled)
        let auPlugins = enabledPlugins.filter { $0.kind == .au }
        let vstPlugins = enabledPlugins.filter { supportsRealtimeVST3($0) }
        let signature = enabledPlugins.map(\.id)
        guard signature != masterPluginSignature else { return }
        let removedPluginIDs = Set(masterPluginSignature).subtracting(signature)
        for pluginID in removedPluginIDs {
            pluginUIRequests.remove(pluginID)
            pendingPluginUIRequests.remove(pluginID)
            vst3UIInstances.removeValue(forKey: pluginID)?.removeEditor()
            pluginWindows[pluginID]?.close()
            pluginWindows.removeValue(forKey: pluginID)
        }
        playbackRetryTask?.cancel()
        playbackRetryTask = nil
        masterPluginSignature = signature
        masterPluginGraphGeneration += 1
        let graphGeneration = masterPluginGraphGeneration
        let wasEngineRunning = engine.isRunning
        if wasEngineRunning {
            engine.pause()
        }
        for node in masterPluginNodes {
            engine.disconnectNodeOutput(node)
            engine.detach(node)
        }
        masterPluginNodes.removeAll()
        if let processor = masterVSTProcessor {
            engine.disconnectNodeOutput(processor.inputNode)
            engine.disconnectNodeOutput(processor.outputNode)
            engine.detach(processor.inputNode)
            engine.detach(processor.outputNode)
            masterVSTProcessor = nil
        }
        if let processor = VST3BusProcessor(
            instances: vstPlugins.compactMap { vst3Instances[$0.id] },
            format: format,
            maxFrames: inputBufferFrameSize
        ) {
            masterVSTProcessor = processor
            engine.attach(processor.inputNode)
            engine.attach(processor.outputNode)
        }
        engine.disconnectNodeOutput(engine.mainMixerNode)
        engine.disconnectNodeOutput(masterOutputNode)
        engine.connect(engine.mainMixerNode, to: masterOutputNode, format: format)
        if masterVSTProcessor == nil {
            engine.connect(masterOutputNode, to: engine.outputNode, format: format)
        }
        if wasEngineRunning {
            try? engine.start()
        }
        installMasterAudioUnits(
            auPlugins,
            previousNode: masterOutputNode,
            format: format,
            index: 0,
            generation: graphGeneration
        )
        if auPlugins.isEmpty {
            connectMasterOutput(from: masterOutputNode, format: format)
        }
    }

    public func setPluginEnabled(_ pluginID: UUID, enabled: Bool) {
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
        pluginAudioUnits[pluginID]?.auAudioUnit.shouldBypassEffect = !enabled
        vst3Instances[pluginID]?.setBypassed(!enabled)
    }

    private func connectMasterOutput(from node: AVAudioNode, format: AVAudioFormat) {
        guard let processor = masterVSTProcessor else {
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.outputNode, format: format)
            return
        }
        engine.disconnectNodeOutput(node)
        engine.connect(node, to: processor.inputNode, format: format)
        engine.disconnectNodeOutput(processor.outputNode)
        engine.connect(processor.outputNode, to: engine.outputNode, format: format)
    }

    private func installMasterAudioUnits(
        _ plugins: [TrackPluginDescriptor],
        previousNode: AVAudioNode,
        format: AVAudioFormat,
        index: Int,
        generation: Int
    ) {
        guard index < plugins.count else { return }
        let plugin = plugins[index]
        AVAudioUnit.instantiate(with: plugin.audioComponentDescription, options: []) { [weak self] audioUnit, error in
            guard let self else { return }
            guard let audioUnit else {
                DispatchQueue.main.async {
                    self.markPluginUnavailable(plugin.id)
                    if let error {
                        print("Failed to create master AU \(plugin.name): \(error)")
                    } else {
                        print("Failed to create master AU \(plugin.name): unknown error")
                    }
                }
                return
            }
            DispatchQueue.main.async {
                    guard self.masterPluginGraphGeneration == generation,
                        self.masterPluginSignature == self.configuredMasterPlugins.filter(\.enabled).map(\.id) else {
                    return
                }
                let wasEngineRunning = self.engine.isRunning
                if wasEngineRunning {
                    self.engine.pause()
                }
                self.engine.disconnectNodeOutput(previousNode)
                self.engine.attach(audioUnit)
                self.unavailablePluginIDs.remove(plugin.id)
                self.engine.connect(previousNode, to: audioUnit, format: format)
                audioUnit.auAudioUnit.shouldBypassEffect = !(self.pluginDescriptors[plugin.id]?.enabled ?? true)
                self.restoreSavedState(for: plugin.id, audioUnit: audioUnit)
                self.masterPluginNodes.append(audioUnit)
                self.pluginAudioUnits[plugin.id] = audioUnit
                self.retryPendingPluginUIRequest(for: plugin.id)
                self.installMasterAudioUnits(
                    plugins,
                    previousNode: audioUnit,
                    format: format,
                    index: index + 1,
                    generation: generation
                )
                if index + 1 == plugins.count {
                    self.connectMasterOutput(from: audioUnit, format: format)
                }
                if wasEngineRunning {
                    try? self.engine.start()
                }
            }
        }
    }

    private func effectiveTrackVolume(for track: AudioTrack, anySolo: Bool) -> Float {
        if track.isMuted || (anySolo && !track.isSoloed) {
            return 0.0
        }
        return track.volume
    }

    private func sendClipKey(sendID: UUID, clipID: UUID) -> String {
        "\(sendID.uuidString):\(clipID.uuidString)"
    }

    private func fxStreamKey(sendID: UUID, clipID: UUID) -> String {
        "fx:\(sendID.uuidString):\(clipID.uuidString)"
    }

    private func syncFXChannels(_ fxChannels: [FXChannel]) {
        let currentIDs = Set(fxChannels.map(\.id))
        for (id, node) in fxInputNodes where !currentIDs.contains(id) {
            engine.disconnectNodeInput(node)
            engine.disconnectNodeOutput(node)
            engine.detach(node)
            fxInputNodes.removeValue(forKey: id)
            fxPluginNodes.removeValue(forKey: id)
            fxVSTPluginsByChannelID.removeValue(forKey: id)
            if let processor = fxVSTProcessors.removeValue(forKey: id) {
                engine.disconnectNodeOutput(processor.inputNode)
                engine.disconnectNodeOutput(processor.outputNode)
                engine.detach(processor.inputNode)
                engine.detach(processor.outputNode)
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

            input.outputVolume = channel.volume
            input.pan = channel.pan
            let enabledPlugins = channel.plugins.filter(\.enabled)
            let plugins = enabledPlugins.filter { $0.kind == .au }
            fxVSTPluginsByChannelID[channel.id] = enabledPlugins.filter { $0.kind == .vst3 }
            let vstPlugins: [TrackPluginDescriptor] = []
            let signature = enabledPlugins.map(\.id)
            guard fxGraphSignatures[channel.id] != signature else { continue }
            fxPluginGraphGenerations[channel.id, default: 0] += 1
            let generation = fxPluginGraphGenerations[channel.id] ?? 0
            for node in fxPluginNodes[channel.id] ?? [] {
                engine.disconnectNodeOutput(node)
                engine.detach(node)
            }
            fxPluginNodes[channel.id] = []
            fxGraphSignatures[channel.id] = signature

            if let processor = fxVSTProcessors.removeValue(forKey: channel.id) {
                engine.disconnectNodeOutput(processor.inputNode)
                engine.disconnectNodeOutput(processor.outputNode)
                engine.detach(processor.inputNode)
                engine.detach(processor.outputNode)
            }
            if let processor = VST3BusProcessor(
                instances: vstPlugins.compactMap { vst3Instances[$0.id] },
                format: format,
                maxFrames: inputBufferFrameSize
            ) {
                fxVSTProcessors[channel.id] = processor
                engine.attach(processor.inputNode)
                engine.attach(processor.outputNode)
            }

            engine.disconnectNodeOutput(input)
            if plugins.isEmpty && fxVSTProcessors[channel.id] == nil {
                engine.connect(input, to: engine.mainMixerNode, format: format)
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
    }

    private func connectFXOutput(
        channelID: UUID,
        from node: AVAudioNode,
        format: AVAudioFormat
    ) {
        engine.disconnectNodeOutput(node)
        if let processor = fxVSTProcessors[channelID] {
            engine.connect(node, to: processor.inputNode, format: format)
            engine.disconnectNodeOutput(processor.outputNode)
            engine.connect(processor.outputNode, to: engine.mainMixerNode, format: format)
        } else {
            engine.connect(node, to: engine.mainMixerNode, format: format)
        }
    }

    private func installFXAudioUnits(
        _ plugins: [TrackPluginDescriptor],
        channelID: UUID,
        previousNode: AVAudioNode,
        format: AVAudioFormat,
        index: Int,
        generation: Int
    ) {
        guard index < plugins.count else {
            connectFXOutput(channelID: channelID, from: previousNode, format: format)
            return
        }
        let plugin = plugins[index]
        AVAudioUnit.instantiate(
            with: plugin.audioComponentDescription,
            options: [],
            completionHandler: { [weak self] audioUnit, _ in
                guard let self else { return }
                guard let audioUnit else {
                    DispatchQueue.main.async {
                        self.markPluginUnavailable(plugin.id)
                        self.installFXAudioUnits(
                            plugins,
                            channelID: channelID,
                            previousNode: previousNode,
                            format: format,
                            index: index + 1,
                            generation: generation
                        )
                    }
                    return
                }
                DispatchQueue.main.async {
                                        guard self.fxPluginGraphGenerations[channelID] == generation else {
                        return
                    }
                    self.engine.disconnectNodeOutput(previousNode)
                    self.engine.attach(audioUnit)
                    self.unavailablePluginIDs.remove(plugin.id)
                    self.engine.connect(previousNode, to: audioUnit, format: format)
                    self.restoreSavedState(for: plugin.id, audioUnit: audioUnit)
                    self.fxPluginNodes[channelID, default: []].append(audioUnit)
                    self.pluginAudioUnits[plugin.id] = audioUnit
                    self.retryPendingPluginUIRequest(for: plugin.id)
                    self.installFXAudioUnits(
                        plugins,
                        channelID: channelID,
                        previousNode: audioUnit,
                        format: format,
                        index: index + 1,
                        generation: generation
                    )
                    if index + 1 == plugins.count {
                        self.connectFXOutput(channelID: channelID, from: audioUnit, format: format)
                    }
                }
            }
        )
    }

    private func isPluginGraphReady(
        for tracks: [AudioTrack],
        fxChannels: [FXChannel]
    ) -> Bool {
        for track in tracks {
            let requiredPluginIDs = track.plugins
                .filter { $0.enabled && $0.kind == .au }
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
                .filter { $0.enabled && $0.kind == .au }
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
            let vstIDs = channel.plugins
                .filter { $0.enabled && supportsRealtimeVST3($0) }
                .map(\.id)
            guard vstIDs.allSatisfy({ vst3Instances[$0] != nil || unavailablePluginIDs.contains($0) }) else {
                return false
            }
            if vstIDs.contains(where: { !unavailablePluginIDs.contains($0) }),
               fxVSTProcessors[channel.id] == nil {
                return false
            }
        }

        let masterAUPlugins = configuredMasterPlugins.filter { $0.enabled && $0.kind == .au }
        guard masterAUPlugins.allSatisfy({
            pluginAudioUnits[$0.id] != nil || unavailablePluginIDs.contains($0.id)
        }) else { return false }
        let availableMasterAUCount = masterAUPlugins.filter {
            !unavailablePluginIDs.contains($0.id)
        }.count
        guard masterPluginNodes.count == availableMasterAUCount else { return false }

        let masterVSTIDs = configuredMasterPlugins
            .filter { $0.enabled && supportsRealtimeVST3($0) }
            .map(\.id)
        guard masterVSTIDs.allSatisfy({ vst3Instances[$0] != nil || unavailablePluginIDs.contains($0) }) else {
            return false
        }
        if masterVSTIDs.contains(where: { !unavailablePluginIDs.contains($0) }),
           masterVSTProcessor == nil {
            return false
        }

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
        generation: Int
    ) {
        guard index < plugins.count else {
            engine.disconnectNodeOutput(previousNode)
            engine.connect(previousNode, to: engine.mainMixerNode, format: format)
            return
        }

        let plugin = plugins[index]
        guard plugin.kind == .au else {
            installAudioUnits(
                plugins,
                for: trackID,
                previousNode: previousNode,
                format: format,
                index: index + 1,
                generation: generation
            )
            return
        }

        let componentDescription = plugin.audioComponentDescription
        let pluginName = plugin.name
        let pluginID = plugin.id
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            AVAudioUnit.instantiate(
                with: componentDescription,
                options: [],
                completionHandler: { audioUnit, error in
                    guard let self else { return }
                    DispatchQueue.main.async {
                        guard self.playerNodes[trackID] != nil,
                              self.pluginGraphGenerations[trackID] == generation else {
                            return
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
                                generation: generation
                            )
                            return
                        }

                        let wasEngineRunning = self.engine.isRunning
                        if wasEngineRunning {
                            self.engine.pause()
                        }
                        self.engine.disconnectNodeOutput(previousNode)
                        self.engine.attach(audioUnit)
                        self.unavailablePluginIDs.remove(pluginID)
                        self.engine.connect(previousNode, to: audioUnit, format: format)
                        audioUnit.auAudioUnit.shouldBypassEffect = !(self.pluginDescriptors[pluginID]?.enabled ?? true)
                        self.restoreSavedState(for: pluginID, audioUnit: audioUnit)
                        self.trackPluginNodes[trackID, default: []].append(audioUnit)
                        self.pluginAudioUnits[pluginID] = audioUnit
                        self.trackPluginLatencies[trackID] = self.trackPluginNodes[trackID, default: []]
                            .compactMap { ($0 as? AVAudioUnit)?.auAudioUnit.latency }
                            .filter { $0.isFinite && $0 >= 0.0 }
                            .reduce(0.0, +)
                        self.retryPendingPluginUIRequest(for: pluginID)
                        self.installAudioUnits(
                            plugins,
                            for: trackID,
                            previousNode: audioUnit,
                            format: format,
                            index: index + 1,
                            generation: generation
                        )
                        if wasEngineRunning {
                            try? self.engine.start()
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

        if let descriptor,
           isRelabLX480(descriptor),
           hasMultipleRelabLX480Instances(descriptor: descriptor) {
            print("Using Generic UI for multiple Relab LX480 AU instances: \(pluginTitle)")
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

    private func isRelabLX480(_ descriptor: TrackPluginDescriptor) -> Bool {
        descriptor.kind == .au &&
            descriptor.name.localizedCaseInsensitiveContains("LX480")
    }

    private func hasMultipleRelabLX480Instances(
        descriptor: TrackPluginDescriptor
    ) -> Bool {
        pluginDescriptors.values.filter { candidate in
            isRelabLX480(candidate) &&
                candidate.componentType == descriptor.componentType &&
                candidate.componentSubType == descriptor.componentSubType &&
                candidate.componentManufacturer == descriptor.componentManufacturer
        }.count > 1
    }

    private func openVST3PluginUI(pluginID: UUID) {
        guard let descriptor = pluginDescriptors[pluginID],
              descriptor.kind == .vst3 else {
            print("VST3 descriptor is not ready: \(pluginID)")
            return
        }
        let instance: VST3NativeInstance
        if let existing = vst3UIInstances[pluginID] {
            instance = existing
        } else if let created = VST3NativeInstance(
            descriptor: descriptor,
            sampleRate: hardwareSampleRate,
            maxFrames: inputBufferFrameSize
        ) {
            vst3UIInstances[pluginID] = created
            instance = created
        } else {
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

        let hostView = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let window = NSWindow(
            contentRect: hostView.frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostView
        window.title = pluginDescriptors[pluginID]?.name ?? "VST3"
        window.center()
        window.isReleasedWhenClosed = false
        configurePluginWindow(window)
        window.makeKeyAndOrderFront(nil)

        guard let contentSize = instance.attachEditor(to: hostView) else {
            print("VST3 plugin editor attach failed: \(pluginID)")
            window.close()
            return
        }
        hostView.frame = NSRect(origin: .zero, size: contentSize)
        window.setContentSize(contentSize)
        window.layoutIfNeeded()
        pluginWindows[pluginID] = window
    }

    private func closePluginWindow(pluginID: UUID) {
        if pluginDescriptors[pluginID]?.kind == .vst3 {
            vst3UIInstances.removeValue(forKey: pluginID)?.removeEditor()
        }
        guard let window = pluginWindows.removeValue(forKey: pluginID) else { return }
        window.contentViewController = nil
        window.contentView = nil
        window.close()
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
        maximumContentSize: NSSize? = nil
    ) {
        let pluginView = viewController.view
        pluginView.translatesAutoresizingMaskIntoConstraints = false
        pluginView.layoutSubtreeIfNeeded()

        let fittingSize = pluginView.fittingSize
        let intrinsicSize = pluginView.intrinsicContentSize
        let existingSize = pluginView.bounds.size
        let fittingContentSize = NSSize(
            width: max(fittingSize.width, intrinsicSize.width, existingSize.width, 480),
            height: max(fittingSize.height, intrinsicSize.height, existingSize.height, 360)
        )
        let contentSize: NSSize
        if let maximumContentSize {
            contentSize = NSSize(
                width: min(fittingContentSize.width, maximumContentSize.width),
                height: min(fittingContentSize.height, maximumContentSize.height)
            )
        } else {
            contentSize = fittingContentSize
        }

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
        window.isReleasedWhenClosed = false
        configurePluginWindow(window)
        window.makeKeyAndOrderFront(nil)
        pluginWindows[pluginID] = window
    }

    private func configurePluginWindow(_ window: NSWindow) {
        window.level = .normal
        window.hidesOnDeactivate = true
        window.collectionBehavior.insert(.moveToActiveSpace)

        guard let mainWindow = NSApp.windows.first(where: {
            $0 !== window && $0.isMainWindow
        }) else { return }
        if !(mainWindow.childWindows ?? []).contains(where: { $0 === window }) {
            mainWindow.addChildWindow(window, ordered: .above)
        }
    }

    private func presentGenericPluginView(
        audioUnit: AVAudioUnit,
        pluginID: UUID,
        title: String
    ) {
        let view = AUGenericView(
            audioUnit: audioUnit.audioUnit,
            displayFlags: AUGenericViewDisplayFlags(rawValue: (1 << 0) | (1 << 2))
        )
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = view

        let documentSize = view.fittingSize
        let visibleSize = NSSize(
            width: min(max(documentSize.width, 480), 900),
            height: min(max(documentSize.height, 360), 640)
        )
        view.frame = NSRect(
            origin: .zero,
            size: NSSize(
                width: max(documentSize.width, visibleSize.width),
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
            maximumContentSize: visibleSize
        )
    }

    // MARK: - Transport: Play / Record

    public func startPlayOrRecord(
        tracks: [AudioTrack],
        fxChannels: [FXChannel] = [],
        isRetry: Bool = false,
        recordArmedTracks: Bool = true
    ) {
        if isPlaying || isRecording || (isStartingPlayback && !isRetry) {
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

        // The graph is prepared by project/plugin changes, never by transport
        // start. Wait here until asynchronous plugin insertion has completed.
        guard isPluginGraphReady(for: tracks, fxChannels: fxChannels) else {
            schedulePlaybackRetry(
                tracks: tracks,
                fxChannels: fxChannels,
                recordArmedTracks: recordArmedTracks
            )
            return
        }

        playbackRetryTask?.cancel()
        playbackRetryTask = nil

        if !engine.isRunning {
            try? engine.start()
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

        let sharedStartTime = AVAudioTime(
            hostTime: mach_absolute_time() + AudioConvertNanosToHostTime(50_000_000)
        )

        isStartingPlayback = false
        if hasArmedTracks {
            startRecording(
                armedTracks: armedTracks,
                playbackTracks: tracks.filter { !$0.isRecordArmed },
                sharedStartTime: sharedStartTime
            )
        } else {
            startPlayback(tracks: tracks, sharedStartTime: sharedStartTime)
        }

        isPlaying = true
        isRecording = hasArmedTracks
        if punchInTime != nil, punchOutTime != nil, currentTime < (punchInTime ?? 0.0) {
            isRecording = false
        }
        hasWarmedUpAudioGraph = true
        schedulePendingPluginUIRequests()
        startMetronome(at: sharedStartTime)
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

    private func startPlayback(tracks: [AudioTrack], sharedStartTime: AVAudioTime? = nil) {
        let startSec = currentTime
        let transportStartTime = sharedStartTime ?? AVAudioTime(
            hostTime: mach_absolute_time() + AudioConvertNanosToHostTime(50_000_000)
        )

        for track in tracks {
            guard let player = playerNodes[track.id] else {
                continue
            }

            scheduleClips(
                for: track,
                player: player,
                startSec: startSec,
                sharedStartTime: transportStartTime,
                startPlayers: false
            )

            for send in track.fxSends where send.enabled && send.level > 0 {
                guard let sendPlayer = sendPlayerNodes[send.id] else { continue }
                scheduleClips(
                    for: track,
                    player: sendPlayer,
                    startSec: startSec,
                    compensatePluginLatency: false,
                    sharedStartTime: transportStartTime,
                    sendID: send.id,
                    fxChannelID: send.fxChannelID,
                    startPlayers: false
                )
            }
        }

        for (clipID, stream) in vst3StreamingClips {
            stream.start(at: pendingVST3StartTimes.removeValue(forKey: clipID.uuidString) ?? transportStartTime)
        }
        for (clipKey, stream) in fxVSTStreamingClips {
            stream.start(at: pendingVST3StartTimes.removeValue(forKey: clipKey) ?? transportStartTime)
        }
        for player in clipPlayerNodes.values {
            player.play(at: transportStartTime)
        }
        for player in sendClipPlayerNodes.values {
            player.play(at: transportStartTime)
        }
    }

    private func reschedulePlayback(tracks: [AudioTrack]) {
        if !engine.isRunning {
            try? engine.start()
            if !engine.isRunning { return }
        }

        let sharedStartTime = AVAudioTime(
            hostTime: mach_absolute_time() + AudioConvertNanosToHostTime(50_000_000)
        )
        startPlayback(tracks: tracks, sharedStartTime: sharedStartTime)
    }

    private func scheduleClips(
        for track: AudioTrack,
        player: AVAudioPlayerNode,
        startSec: Double,
        compensatePluginLatency: Bool = true,
        sharedStartTime: AVAudioTime,
        sendID: UUID? = nil,
        fxChannelID: UUID? = nil,
        startPlayers: Bool = true
    ) {
        guard let clips = audioFiles[track.id] else { return }
        let isSendPlayback = sendID != nil
        let isMainTrackPlayer = player === playerNodes[track.id]
        player.stop()
        if isMainTrackPlayer {
            for item in clips {
                clipPlayerNodes[item.clip.id]?.stop()
                vst3StreamingClips.removeValue(forKey: item.clip.id)?.stop()
            }
        } else if let sendID {
            for item in clips {
                sendClipPlayerNodes[sendClipKey(sendID: sendID, clipID: item.clip.id)]?.stop()
                fxVSTStreamingClips.removeValue(
                    forKey: fxStreamKey(sendID: sendID, clipID: item.clip.id)
                )?.stop()
            }
        }
        let pluginLatency = compensatePluginLatency ? (trackPluginLatencies[track.id] ?? 0.0) : 0.0
        for item in clips {
            if item.clip.isMuted {
                continue
            }
            let file = item.file
            let clipStart = item.clip.startTime
            let format = file.processingFormat
            let clipDuration = min(item.clip.duration, item.clip.originalDuration - item.clip.sourceStartTime)
            let scheduledClipStart = clipStart - pluginLatency
            guard startSec < scheduledClipStart + clipDuration else { continue }

            let offset = max(0.0, startSec - scheduledClipStart) + item.clip.sourceStartTime
            let startingFrame = AVAudioFramePosition(offset * format.sampleRate)
            let remainingDuration = clipDuration - max(0.0, startSec - scheduledClipStart)
            let frameCount = AVAudioFrameCount(max(0.0, remainingDuration) * format.sampleRate)
            let delay = max(0.0, scheduledClipStart - startSec)
            let startTime = AVAudioTime(
                hostTime: sharedStartTime.hostTime + AudioConvertNanosToHostTime(
                    UInt64(delay * 1_000_000_000.0)
                )
            )

            let targetPlayer: AVAudioPlayerNode
            if isMainTrackPlayer {
                targetPlayer = clipPlayerNodes[item.clip.id] ?? player
            } else if let sendID, let sendClipPlayer = sendClipPlayerNodes[
                sendClipKey(sendID: sendID, clipID: item.clip.id)
            ] {
                targetPlayer = sendClipPlayer
            } else {
                targetPlayer = player
            }
            targetPlayer.volume = isMainTrackPlayer ? 1.0 : player.volume
            let vst3Plugins = isMainTrackPlayer
                ? track.plugins.filter { $0.enabled && $0.kind == .vst3 }
                : (fxChannelID.flatMap { fxVSTPluginsByChannelID[$0] } ?? [])
            if !vst3Plugins.isEmpty,
               let outputFormat = AVAudioFormat(
                   standardFormatWithSampleRate: hardwareSampleRate,
                   channels: 2
               ) {
                let instances = vst3Plugins.compactMap { vst3Instances[$0.id] }
                if instances.count == vst3Plugins.count,
                   let streamingClip = VST3StreamingClip(
                       player: targetPlayer,
                       fileURL: item.clip.fileURL,
                       instances: instances,
                       outputFormat: outputFormat,
                       sourceStartTime: item.clip.sourceStartTime,
                       clipOffset: max(0.0, startSec - scheduledClipStart),
                       clipDuration: clipDuration,
                       gainDB: item.clip.gainDB,
                       fadeInDuration: item.clip.fadeInDuration,
                       fadeOutDuration: item.clip.fadeOutDuration
                   ) {
                    if let sendID {
                        let key = fxStreamKey(sendID: sendID, clipID: item.clip.id)
                        fxVSTStreamingClips[key]?.stop()
                        fxVSTStreamingClips[key] = streamingClip
                    } else {
                        vst3StreamingClips[item.clip.id]?.stop()
                        vst3StreamingClips[item.clip.id] = streamingClip
                        if !startPlayers {
                            pendingVST3StartTimes[item.clip.id.uuidString] = startTime
                        }
                    }
                    if let sendID, !startPlayers {
                        pendingVST3StartTimes[fxStreamKey(sendID: sendID, clipID: item.clip.id)] = startTime
                    }
                    if startPlayers {
                        streamingClip.start(at: startTime)
                    }
                    continue
                }
            }
            if item.clip.gainDB == 0.0,
               item.clip.fadeInDuration == 0.0,
               item.clip.fadeOutDuration == 0.0 {
                targetPlayer.scheduleSegment(
                    item.file,
                    startingFrame: startingFrame,
                    frameCount: frameCount,
                    at: startTime,
                    completionHandler: nil
                )
            } else {
                guard let playbackBuffer = makeClipPlaybackBuffer(
                    fileURL: item.clip.fileURL,
                    startingFrame: startingFrame,
                    frameCount: frameCount,
                    gainDB: item.clip.gainDB,
                    clipOffset: max(0.0, startSec - scheduledClipStart),
                    clipDuration: clipDuration,
                    fadeInDuration: item.clip.fadeInDuration,
                    fadeOutDuration: item.clip.fadeOutDuration
                ) else { continue }
                targetPlayer.scheduleBuffer(
                    playbackBuffer,
                    at: startTime,
                    options: [],
                    completionHandler: nil
                )
            }
        }
        guard startPlayers else { return }

        if isMainTrackPlayer {
            for item in clips {
                let hasStreamingClip: Bool
                if let sendID {
                    hasStreamingClip = fxVSTStreamingClips[fxStreamKey(sendID: sendID, clipID: item.clip.id)] != nil
                } else {
                    hasStreamingClip = vst3StreamingClips[item.clip.id] != nil
                }
                if !hasStreamingClip {
                    clipPlayerNodes[item.clip.id]?.play(at: sharedStartTime)
                }
            }
        } else if isSendPlayback, let sendID {
            for item in clips {
                sendClipPlayerNodes[sendClipKey(sendID: sendID, clipID: item.clip.id)]?.play(at: sharedStartTime)
            }
        } else {
            player.play(at: sharedStartTime)
        }
    }

    private func makeClipPlaybackBuffer(
        fileURL: URL,
        startingFrame: AVAudioFramePosition,
        frameCount: AVAudioFrameCount,
        gainDB: Double,
        clipOffset: Double,
        clipDuration: Double,
        fadeInDuration: Double,
        fadeOutDuration: Double
    ) -> AVAudioPCMBuffer? {
        guard frameCount > 0,
              let file = try? AVAudioFile(forReading: fileURL),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: file.processingFormat,
                  frameCapacity: frameCount
              ) else { return nil }

        file.framePosition = startingFrame
        do {
            try file.read(into: buffer, frameCount: frameCount)
        } catch {
            return nil
        }
        guard let sourceChannelData = buffer.floatChannelData else { return buffer }
        let linearGain = Float(pow(10.0, gainDB / 20.0))
        let frames = Int(buffer.frameLength)
        guard let outputFormat = AVAudioFormat(
            standardFormatWithSampleRate: hardwareSampleRate,
            channels: 2
        ),
        let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(frames)
        ),
        let outputChannelData = outputBuffer.floatChannelData else {
            return nil
        }
        outputBuffer.frameLength = AVAudioFrameCount(frames)

        for frame in 0..<frames {
            let position = clipOffset + Double(frame) / buffer.format.sampleRate
            let fadeInGain = fadeInDuration > 0.0
                ? min(1.0, max(0.0, position / fadeInDuration))
                : 1.0
            let remaining = clipDuration - position
            let fadeOutGain = fadeOutDuration > 0.0
                ? min(1.0, max(0.0, remaining / fadeOutDuration))
                : 1.0
            let gain = linearGain * Float(min(fadeInGain, fadeOutGain))
            let left = sourceChannelData[0][frame] * gain
            let right = buffer.format.channelCount > 1
                ? sourceChannelData[1][frame] * gain
                : left
            outputChannelData[0][frame] = left
            outputChannelData[1][frame] = right
        }
        return outputBuffer
    }

    private func startRecording(
        armedTracks: [AudioTrack],
        playbackTracks: [AudioTrack],
        sharedStartTime: AVAudioTime
    ) {
        activeWriters.removeAll()
        punchArmedTrackIDs = Set(armedTracks.map(\.id))
        punchPlaybackState = 0
        isPunchRecording = punchInTime.map { currentTime >= $0 } ?? true
        // CRITICAL: Use hardwareSampleRate (actual HW rate from inputNode) — NOT the UI sampleRate.
        // This ensures the WAV file header matches the actual captured audio sample rate.
        let recordSampleRate = self.hardwareSampleRate

        activeClips.removeAll()
        recordingTimingLock.withLock {
            recordingTimelineStart = currentTime
            recordingTransportStartHostTime = sharedStartTime.hostTime
            pendingRecordingClipStartTime = max(
                0.0,
                (punchInTime ?? currentTime) - recordingPlacementCompensation
            )
            hasLoggedFirstRecordingInput = false
        }
        let startNowHostTime = mach_absolute_time()
        let startDelayMs = Double(
            AudioConvertHostTimeToNanos(sharedStartTime.hostTime - startNowHostTime)
        ) / 1_000_000.0
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

        captureLock.withLock {
            self.writersSnapshot = activeWriters
            self.recordingActiveState = self.isPunchRecording
        }

        startPlayback(
            tracks: playbackTracks + armedTracks,
            sharedStartTime: sharedStartTime
        )
    }

    private func updatePunchRecordingState() {
        guard isPlaying else { return }
        guard punchInTime != nil, punchOutTime != nil else { return }
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
        captureLock.withLock {
            recordingActiveState = recordingNow
        }
        let playbackVolume: Float = recordingNow ? 0.0 : 1.0
        for trackID in punchArmedTrackIDs {
            trackOutputNodes[trackID]?.outputVolume = playbackVolume
        }
    }

    // MARK: - Transport: Stop

    public func stop(tracks: [AudioTrack]) {
        startPlaybackTask?.cancel()
        startPlaybackTask = nil
        playbackRetryTask?.cancel()
        playbackRetryTask = nil
        isStartingPlayback = false
        stopPlayheadTimer()
        guard isPlaying || isRecording else { return }

        stopMetronome()

        // 1. Immediately flag recording as stopped
        let writersToFinalize = captureLock.withLock { () -> [UUID: AudioDiskWriter] in
            self.recordingActiveState = false
            let snapshot = self.writersSnapshot
            self.writersSnapshot = [:]
            return snapshot
        }

        activeWriters.removeAll()

        // 2. Stop player nodes
        for (_, player) in playerNodes {
            player.stop()
        }
        for player in clipPlayerNodes.values {
            player.stop()
        }
        for stream in vst3StreamingClips.values {
            stream.stop()
        }
        vst3StreamingClips.removeAll()
        for stream in fxVSTStreamingClips.values {
            stream.stop()
        }
        fxVSTStreamingClips.removeAll()
        pendingVST3StartTimes.removeAll()
        for player in sendClipPlayerNodes.values {
            player.stop()
        }
        for (_, player) in sendPlayerNodes {
            player.stop()
        }
        // Punch recording temporarily mutes the armed tracks' main output.
        // Restore it before the next transport start; FX sends use a separate
        // path and otherwise can remain audible while the track stays silent.
        let anySolo = tracks.contains { $0.isSoloed }
        for track in tracks where punchArmedTrackIDs.contains(track.id) {
            let volume = effectiveTrackVolume(for: track, anySolo: anySolo)
            trackOutputNodes[track.id]?.outputVolume = volume
            playerNodes[track.id]?.volume = volume
        }
        punchArmedTrackIDs.removeAll()
        punchPlaybackState = 0
        isPunchRecording = false
        // Keep AVAudioEngine running during normal transport stop. This is the
        // host's continuous render path and lets Audio Units preserve tails,
        // meters, and GUI-related runtime state between transport operations.

        // 3. Finalize all disk writers and attach URLs to tracks
        recordingFinalizationTask = Task { @MainActor [weak self] in
            for (trackId, writer) in writersToFinalize {
                if let savedURL = await writer.finalize() {
                    if let self,
                       tracks.contains(where: { $0.id == trackId }) {
                        if let clip = self.activeClips[trackId], clip.fileURL == savedURL {
                            clip.loadMetadata()
                        }
                    }
                }
            }
            // Newly recorded clips are added after the previous graph sync.
            // Refresh the playback file cache after their files are finalized.
            if let self,
               !self.isPlaying,
               !self.isRecording {
                self.syncTracks(tracks, fxChannels: self.syncedFXChannels)
            }
            self?.activeClips.removeAll()
            self?.recordingFinalizationTask = nil
        }

        stopPlayheadTimer()
        recordingTimingLock.withLock {
            pendingRecordingClipStartTime = nil
        }
        isPlaying = false
        isRecording = false
    }

    public func exportMasterMix(
        to url: URL,
        startTime: Double,
        endTime: Double,
        tracks: [AudioTrack],
        fxChannels: [FXChannel]
    ) async throws {
        guard !isPlaying && !isRecording else {
            throw NSError(domain: "MyDAW.Export", code: 1, userInfo: [NSLocalizedDescriptionKey: "Stop playback before exporting."])
        }
        let start = max(0.0, startTime)
        let end = max(start + 0.01, endTime)
        syncTracks(tracks, fxChannels: fxChannels)
        guard isPluginGraphReady(for: tracks, fxChannels: fxChannels) else {
            throw NSError(domain: "MyDAW.Export", code: 2, userInfo: [NSLocalizedDescriptionKey: "Audio plug-ins are still loading. Try again in a moment."])
        }
        guard let captureNode = masterVSTProcessor?.outputNode ?? masterPluginNodes.last ?? masterOutputNode,
              let format = AVAudioFormat(
                  standardFormatWithSampleRate: hardwareSampleRate,
                  channels: 2
              ) else {
            throw NSError(domain: "MyDAW.Export", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not prepare the master output."])
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: hardwareSampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
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

        captureNode.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, _ in
            guard writeError == nil else { return }
            guard let copy = buffer.copy() as? AVAudioPCMBuffer else { return }
            writeQueue.async {
                do {
                    try file.write(from: copy)
                } catch {
                    writeError = error
                }
            }
        }

        currentTime = start
        startPlayback(tracks: tracks)
        isPlaying = true
        try? engine.start()

        do {
            try await Task.sleep(nanoseconds: UInt64((end - start) * 1_000_000_000.0))
        } catch is CancellationError {
            captureNode.removeTap(onBus: 0)
            for player in playerNodes.values { player.stop() }
            for player in clipPlayerNodes.values { player.stop() }
            for player in sendPlayerNodes.values { player.stop() }
            writeQueue.sync { }
            isPlaying = false
            isRecording = false
            currentTime = previousTime
            throw CancellationError()
        } catch {
            captureNode.removeTap(onBus: 0)
            for player in playerNodes.values { player.stop() }
            for player in clipPlayerNodes.values { player.stop() }
            for player in sendPlayerNodes.values { player.stop() }
            writeQueue.sync { }
            isPlaying = false
            isRecording = false
            currentTime = previousTime
            throw error
        }

        for player in playerNodes.values { player.stop() }
        for player in clipPlayerNodes.values { player.stop() }
        for player in sendPlayerNodes.values { player.stop() }
        captureNode.removeTap(onBus: 0)
        writeQueue.sync { }
        isPlaying = false
        isRecording = false
        currentTime = previousTime
        if let writeError { throw writeError }
    }

    // MARK: - Transport: Rewind

    public func rewind(tracks: [AudioTrack]) {
        let wasPlaying = isPlaying || isRecording
        if wasPlaying {
            stop(tracks: tracks)
        }
        currentTime = 0.0
        playheadStartOffset = 0.0
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

        playheadTimer?.invalidate()
        playheadTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
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
            }
        }
    }

    private func stopPlayheadTimer() {
        playheadTimer?.invalidate()
        playheadTimer = nil
    }
}

public extension Notification.Name {
    static let audioEngineUpdatedPeaks = Notification.Name("audioEngineUpdatedPeaks")
}
