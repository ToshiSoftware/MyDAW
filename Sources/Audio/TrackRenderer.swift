import AVFoundation
import AudioToolbox

@_silgen_name("MyDAWAtomicLoad64")
private func atomicLoad(_ pointer: UnsafePointer<Int64>) -> Int64

@_silgen_name("MyDAWAtomicStore64")
private func atomicStore(_ pointer: UnsafeMutablePointer<Int64>, _ value: Int64)

@_silgen_name("MyDAWMemoryFence")
private func memoryFence()

/// What one track plays, copied from its clips on the main thread so the
/// streaming thread never touches them.
struct TrackPlaybackPlan: @unchecked Sendable {
    struct Piece {
        let start: Double
        let end: Double
        /// Needs a per-sample envelope (fades, crossfades).
        let isShaped: Bool
    }

    struct Clip {
        let id: UUID
        let fileURL: URL
        let startTime: Double
        let sourceStartTime: Double
        let gain: Double
        /// Fades and crossfades, prepared once for per-sample use.
        let envelope: ClipLayering.Envelope?
        /// The audible parts (hidden ones are left out), in timeline seconds.
        let pieces: [Piece]
    }

    var clips: [Clip] = []

    /// The track's unmuted clips whose files exist, with the parts covered
    /// by upper clips left out (see `ClipLayering`).
    @MainActor
    static func make(for track: AudioTrack) -> TrackPlaybackPlan {
        let loaded = track.clips.filter { !$0.isFileMissing }
        let spans = ClipLayering.spans(for: loaded)
        var clips: [Clip] = []
        for clip in loaded where !clip.isMuted {
            let pieces = ClipLayering.segments(spans, clip: clip.id)
                .filter { $0.kind != .hidden }
                .map { Piece(start: $0.start, end: $0.end, isShaped: $0.kind == .shaped) }
            guard !pieces.isEmpty else { continue }
            clips.append(Clip(
                id: clip.id,
                fileURL: clip.fileURL,
                startTime: clip.startTime,
                sourceStartTime: clip.sourceStartTime,
                gain: pow(10.0, clip.gainDB / 20.0),
                envelope: ClipLayering.Envelope(spans, clip: clip.id),
                pieces: pieces
            ))
        }
        return TrackPlaybackPlan(clips: clips)
    }
}

/// Plays one track's clips through an `AVAudioSourceNode`.
///
/// The render thread only copies samples out of blocks that `TrackStreamer`
/// has read from disk and mixed ahead of the playhead (about four seconds).
/// So starting the transport needs no per-clip player and no call that
/// blocks on the engine (each `AVAudioPlayerNode.play(at:)` waited a render
/// cycle and held the engine meanwhile), and an edit during playback is
/// heard once the blocks ahead have been read again.
///
/// Timeline frames count output-rate frames from the timeline's zero; block
/// `k` holds frames `k * blockFrames ..< (k + 1) * blockFrames` in slot
/// `k % slotCount`. A slot is guarded by a sequence number (odd while it is
/// written), so the render thread never waits and never plays a torn block.
final class TrackRenderer: @unchecked Sendable {
    static let blockShift: Int64 = 12
    static let blockFrames = 1 << 12
    static let slotCount = 48

    let sampleRate: Double
    private(set) var node: AVAudioSourceNode!

    // Shared with the render thread (atomic loads and stores only).
    private enum Field: Int {
        case running, anchorGeneration, anchorHost, anchorFrame, renderFrom
        case muted, lastRendered, underruns, resetDone
        static let count = 9
    }
    private let fields = UnsafeMutablePointer<Int64>.allocate(capacity: Field.count)
    private let sequences = UnsafeMutablePointer<Int64>.allocate(capacity: TrackRenderer.slotCount)
    private let blockIDs = UnsafeMutablePointer<Int64>.allocate(capacity: TrackRenderer.slotCount)
    private let left = UnsafeMutablePointer<Float>.allocate(capacity: TrackRenderer.slotCount * TrackRenderer.blockFrames)
    private let right = UnsafeMutablePointer<Float>.allocate(capacity: TrackRenderer.slotCount * TrackRenderer.blockFrames)

    // Render thread only.
    private var renderAnchorGeneration: Int64 = -1
    private var renderAnchorSample: Double = 0
    private var renderGain: Float = 1
    private let secondsPerHostTick: Double

    // Written by the main thread, read by the streamer, under `lock`.
    private let lock = NSLock()
    private var plan = TrackPlaybackPlan()
    private var planGeneration = 0
    private var isActive = false
    private var resetRequest: Int64 = 0
    private var resetFrom: Int64 = 0

    // Streamer thread only.
    private var slotPlanGenerations = [Int](repeating: -1, count: TrackRenderer.slotCount)
    private var handledReset: Int64 = 0
    private var writeFrom: Int64 = 0
    private var readers: [URL: ClipReader] = [:]
    private var blockCounter = 0
    private let scratchLeft = UnsafeMutablePointer<Float>.allocate(capacity: TrackRenderer.blockFrames)
    private let scratchRight = UnsafeMutablePointer<Float>.allocate(capacity: TrackRenderer.blockFrames)

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        secondsPerHostTick = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000.0
        fields.initialize(repeating: 0, count: Field.count)
        fields[Field.lastRendered.rawValue] = -1
        sequences.initialize(repeating: 0, count: Self.slotCount)
        blockIDs.initialize(repeating: -1, count: Self.slotCount)
        left.initialize(repeating: 0, count: Self.slotCount * Self.blockFrames)
        right.initialize(repeating: 0, count: Self.slotCount * Self.blockFrames)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        node = AVAudioSourceNode(format: format) { [unowned self] isSilence, timestamp, frameCount, bufferList in
            self.render(isSilence: isSilence, timestamp: timestamp, frameCount: Int(frameCount), bufferList: bufferList)
        }
        TrackStreamer.shared.register(self)
    }

    deinit {
        fields.deallocate()
        sequences.deallocate()
        blockIDs.deallocate()
        left.deallocate()
        right.deallocate()
        scratchLeft.deallocate()
        scratchRight.deallocate()
    }

    private func load(_ field: Field) -> Int64 {
        atomicLoad(fields + field.rawValue)
    }

    private func store(_ field: Field, _ value: Int64) {
        atomicStore(fields + field.rawValue, value)
    }

    // MARK: - Main thread

    /// Takes a new plan; while playing, the blocks ahead are read again.
    func setPlan(_ newPlan: TrackPlaybackPlan) {
        lock.withLock {
            plan = newPlan
            planGeneration += 1
        }
        TrackStreamer.shared.wake()
    }

    /// Silences the track (the armed track while it records), ramped.
    func setMuted(_ muted: Bool) {
        store(.muted, muted ? 1 : 0)
    }

    /// Stops output and starts reading from `frame` for the next `start`.
    func prepare(renderFrom frame: Int64) {
        store(.running, 0)
        store(.renderFrom, frame)
        store(.lastRendered, -1)
        lock.withLock {
            isActive = true
            resetRequest += 1
            resetFrom = frame
        }
        TrackStreamer.shared.wake()
    }

    /// True once the blocks at the prepared position are ready to play.
    func isReadyToStart(blocks: Int = 2) -> Bool {
        let (request, from) = lock.withLock { (resetRequest, resetFrom) }
        guard load(.resetDone) == request else { return false }
        let first = from >> Self.blockShift
        return (0..<Int64(blocks)).allSatisfy { offset in
            let block = first + offset
            return atomicLoad(blockIDs + Self.slot(block)) == block
        }
    }

    /// Starts output: timeline frame `anchorFrame` is heard at host time
    /// `anchorHost`; nothing before the prepared frame plays.
    func start(anchorHost: UInt64, anchorFrame: Int64) {
        store(.anchorHost, Int64(bitPattern: anchorHost))
        store(.anchorFrame, anchorFrame)
        store(.anchorGeneration, load(.anchorGeneration) + 1)
        store(.running, 1)
    }

    /// Moves the timeline against the clock (a plug-in latency changed).
    func setAnchorFrame(_ anchorFrame: Int64) {
        store(.anchorFrame, anchorFrame)
    }

    /// Stops output; returns how many render cycles found no block ready.
    @discardableResult
    func stop() -> Int64 {
        store(.running, 0)
        lock.withLock { isActive = false }
        let underruns = load(.underruns)
        store(.underruns, 0)
        TrackStreamer.shared.wake()
        return underruns
    }

    func unregister() {
        stop()
        TrackStreamer.shared.unregister(self)
    }

    private static func slot(_ block: Int64) -> Int {
        Int(block % Int64(slotCount))
    }

    // MARK: - Render thread

    private func render(
        isSilence: UnsafeMutablePointer<ObjCBool>,
        timestamp: UnsafePointer<AudioTimeStamp>,
        frameCount frames: Int,
        bufferList: UnsafeMutablePointer<AudioBufferList>
    ) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        guard buffers.count >= 2,
              let outLeft = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let outRight = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
            return noErr
        }
        guard load(.running) != 0 else {
            outLeft.update(repeating: 0, count: frames)
            outRight.update(repeating: 0, count: frames)
            isSilence.pointee = true
            renderGain = load(.muted) != 0 ? 0 : 1
            return noErr
        }

        let time = timestamp.pointee
        let generation = load(.anchorGeneration)
        if generation != renderAnchorGeneration {
            renderAnchorGeneration = generation
            let anchorHost = Double(UInt64(bitPattern: load(.anchorHost)))
            let hostNow = time.mFlags.contains(.hostTimeValid)
                ? Double(time.mHostTime)
                : Double(mach_absolute_time())
            renderAnchorSample = time.mSampleTime + ((anchorHost - hostNow) * secondsPerHostTick * sampleRate).rounded()
        }
        let firstFrame = load(.anchorFrame) + Int64((time.mSampleTime - renderAnchorSample).rounded())
        let renderFrom = load(.renderFrom)

        var index = 0
        var missing = false
        while index < frames {
            let frame = firstFrame + Int64(index)
            if frame < renderFrom {
                let count = Int(min(Int64(frames - index), renderFrom - frame))
                (outLeft + index).update(repeating: 0, count: count)
                (outRight + index).update(repeating: 0, count: count)
                index += count
                continue
            }
            let block = frame >> Self.blockShift
            let offset = Int(frame & Int64(Self.blockFrames - 1))
            let count = min(frames - index, Self.blockFrames - offset)
            let slot = Self.slot(block)
            let before = atomicLoad(sequences + slot)
            var copied = false
            if before & 1 == 0, atomicLoad(blockIDs + slot) == block {
                let base = slot * Self.blockFrames + offset
                (outLeft + index).update(from: left + base, count: count)
                (outRight + index).update(from: right + base, count: count)
                memoryFence()
                copied = atomicLoad(sequences + slot) == before
            }
            if !copied {
                (outLeft + index).update(repeating: 0, count: count)
                (outRight + index).update(repeating: 0, count: count)
                missing = true
            }
            index += count
        }
        if missing {
            store(.underruns, load(.underruns) + 1)
        }
        store(.lastRendered, firstFrame + Int64(frames))

        // The recording mute, ramped over about 5 ms so it never clicks.
        let target: Float = load(.muted) != 0 ? 0 : 1
        if renderGain != target || target == 0 {
            let step: Float = 1.0 / 256.0
            for frame in 0..<frames {
                renderGain = renderGain < target ? min(target, renderGain + step) : max(target, renderGain - step)
                outLeft[frame] *= renderGain
                outRight[frame] *= renderGain
            }
        }
        return noErr
    }

    // MARK: - Streamer thread

    /// Reads and mixes up to a few blocks ahead of the playhead; returns
    /// whether it wrote any (so the streamer comes back without waiting).
    func service() -> Bool {
        let (plan, generation, active, request, from) = lock.withLock {
            (plan, planGeneration, isActive, resetRequest, resetFrom)
        }
        guard active else {
            readers.removeAll()
            return false
        }
        if request != handledReset {
            for slot in 0..<Self.slotCount {
                let sequence = sequences[slot]
                atomicStore(sequences + slot, sequence + 1)
                atomicStore(blockIDs + slot, -1)
                atomicStore(sequences + slot, sequence + 2)
                slotPlanGenerations[slot] = -1
            }
            handledReset = request
            writeFrom = from
            store(.resetDone, request)
        }

        let running = load(.running) != 0
        let rendered = load(.lastRendered)
        let playFrame = running && rendered > writeFrom ? rendered : writeFrom
        let firstBlock = playFrame >> Self.blockShift
        var written = 0
        for block in firstBlock..<(firstBlock + Int64(Self.slotCount - 1)) {
            let slot = Self.slot(block)
            let present = atomicLoad(blockIDs + slot) == block
            if present && slotPlanGenerations[slot] == generation { continue }
            // A block about to be played is not rewritten for an edit: the
            // render thread could meet it half written and play silence.
            if present && running && block < firstBlock + 2 { continue }
            writeBlock(block, slot: slot, plan: plan)
            slotPlanGenerations[slot] = generation
            written += 1
            if written >= 4 { break }
        }
        if written > 0 {
            // Files not needed within the look-ahead are closed again, so a
            // project of hundreds of clips keeps only a few open.
            readers = readers.filter { blockCounter - $0.value.lastUsed <= Self.slotCount }
        }
        return written > 0
    }

    private func writeBlock(_ block: Int64, slot: Int, plan: TrackPlaybackPlan) {
        blockCounter += 1
        let sequence = sequences[slot]
        atomicStore(sequences + slot, sequence + 1)
        memoryFence()

        let base = slot * Self.blockFrames
        let outLeft = left + base
        let outRight = right + base
        outLeft.update(repeating: 0, count: Self.blockFrames)
        outRight.update(repeating: 0, count: Self.blockFrames)
        let blockStart = block << Self.blockShift
        let blockEnd = blockStart + Int64(Self.blockFrames)
        let rate = sampleRate
        func frame(_ seconds: Double) -> Int64 { Int64((seconds * rate).rounded()) }

        for clip in plan.clips {
            let offset = frame(clip.sourceStartTime - clip.startTime)
            for piece in clip.pieces {
                let start = max(frame(piece.start), blockStart)
                let end = min(frame(piece.end), blockEnd)
                guard end > start else { continue }
                let count = Int(end - start)
                guard let reader = reader(for: clip.fileURL) else { continue }
                reader.lastUsed = blockCounter
                let filled = reader.read(from: start + offset, count: count, left: scratchLeft, right: scratchRight)
                let destination = Int(start - blockStart)
                for index in 0..<filled {
                    let gain: Double
                    if piece.isShaped, let envelope = clip.envelope {
                        gain = clip.gain * envelope.gain(at: Double(start + Int64(index)) / rate)
                    } else {
                        gain = clip.gain
                    }
                    outLeft[destination + index] += scratchLeft[index] * Float(gain)
                    outRight[destination + index] += scratchRight[index] * Float(gain)
                }
            }
        }

        memoryFence()
        atomicStore(blockIDs + slot, block)
        atomicStore(sequences + slot, sequence + 2)
    }

    private func reader(for url: URL) -> ClipReader? {
        if let existing = readers[url] { return existing }
        guard let reader = ClipReader(url: url, outputRate: sampleRate, capacity: Self.blockFrames) else {
            return nil
        }
        readers[url] = reader
        return reader
    }
}

/// Reads an audio file as stereo at the output rate, converting the rate
/// when the file has another one. Used by one streamer thread only.
private final class ClipReader {
    private let file: AVAudioFile
    private let outputRate: Double
    private let inputBuffer: AVAudioPCMBuffer
    private let converter: AVAudioConverter?
    private let convertedFormat: AVAudioFormat?
    /// Output-rate position the converter continues from.
    private var nextConvertedFrame: Int64 = .min
    var lastUsed = 0

    init?(url: URL, outputRate: Double, capacity: Int) {
        guard let file = try? AVAudioFile(forReading: url),
              let inputBuffer = AVAudioPCMBuffer(
                  pcmFormat: file.processingFormat,
                  frameCapacity: AVAudioFrameCount(capacity)
              ) else { return nil }
        self.file = file
        self.outputRate = outputRate
        self.inputBuffer = inputBuffer
        let format = file.processingFormat
        if abs(format.sampleRate - outputRate) > 0.5,
           let converted = AVAudioFormat(
               standardFormatWithSampleRate: outputRate,
               channels: format.channelCount
           ),
           let converter = AVAudioConverter(from: format, to: converted) {
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            self.converter = converter
            self.convertedFormat = converted
        } else {
            self.converter = nil
            self.convertedFormat = nil
        }
    }

    /// Fills `count` frames from output-rate position `position` of the
    /// file; returns how many were filled (fewer at the file's end).
    func read(
        from position: Int64,
        count: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>
    ) -> Int {
        guard position >= 0, count > 0 else { return 0 }
        if converter != nil {
            return readConverted(from: position, count: count, left: left, right: right)
        }
        guard position < file.length else { return 0 }
        let frames = AVAudioFrameCount(min(Int64(count), file.length - position))
        file.framePosition = position
        do {
            try file.read(into: inputBuffer, frameCount: frames)
        } catch {
            return 0
        }
        return copyChannels(of: inputBuffer, left: left, right: right, count: count)
    }

    private func readConverted(
        from position: Int64,
        count: Int,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>
    ) -> Int {
        guard let converter, let convertedFormat,
              let output = AVAudioPCMBuffer(pcmFormat: convertedFormat, frameCapacity: AVAudioFrameCount(count)) else {
            return 0
        }
        if position != nextConvertedFrame {
            let sourceFrame = Int64((Double(position) * file.processingFormat.sampleRate / outputRate).rounded())
            guard sourceFrame < file.length else { return 0 }
            file.framePosition = sourceFrame
            converter.reset()
        }
        let file = self.file
        let input = inputBuffer
        var reachedEnd = false
        var error: NSError?
        _ = converter.convert(to: output, error: &error) { requested, status in
            if reachedEnd || file.framePosition >= file.length {
                reachedEnd = true
                status.pointee = .endOfStream
                return nil
            }
            let frames = min(requested, input.frameCapacity, AVAudioFrameCount(file.length - file.framePosition))
            do {
                try file.read(into: input, frameCount: frames)
            } catch {
                reachedEnd = true
                status.pointee = .endOfStream
                return nil
            }
            status.pointee = .haveData
            return input
        }
        nextConvertedFrame = position + Int64(output.frameLength)
        if reachedEnd {
            nextConvertedFrame = .min
        }
        return copyChannels(of: output, left: left, right: right, count: count)
    }

    private func copyChannels(
        of buffer: AVAudioPCMBuffer,
        left: UnsafeMutablePointer<Float>,
        right: UnsafeMutablePointer<Float>,
        count: Int
    ) -> Int {
        guard let channels = buffer.floatChannelData else { return 0 }
        let frames = min(count, Int(buffer.frameLength))
        left.update(from: channels[0], count: frames)
        right.update(from: channels[buffer.format.channelCount > 1 ? 1 : 0], count: frames)
        return frames
    }
}

/// The background thread that keeps every `TrackRenderer` read ahead. It
/// serves the tracks in turn, a few blocks each, so all of them get their
/// opening ready together when the transport starts.
final class TrackStreamer: @unchecked Sendable {
    static let shared = TrackStreamer()

    private final class Entry {
        weak var renderer: TrackRenderer?
        init(_ renderer: TrackRenderer) { self.renderer = renderer }
    }

    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Entry] = [:]
    private let wakeSignal = DispatchSemaphore(value: 0)

    private init() {
        let thread = Thread { [unowned self] in self.run() }
        thread.name = "MyDAW.TrackStreamer"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func register(_ renderer: TrackRenderer) {
        lock.withLock { entries[ObjectIdentifier(renderer)] = Entry(renderer) }
    }

    func unregister(_ renderer: TrackRenderer) {
        _ = lock.withLock { entries.removeValue(forKey: ObjectIdentifier(renderer)) }
    }

    func wake() {
        wakeSignal.signal()
    }

    private func run() {
        while true {
            let renderers = lock.withLock { entries.values.compactMap(\.renderer) }
            var didWork = false
            for renderer in renderers where renderer.service() {
                didWork = true
            }
            if !didWork {
                _ = wakeSignal.wait(timeout: .now() + .milliseconds(10))
            }
        }
    }
}
