import AVFoundation
import AudioToolbox

private final class VolumeAutomationKernel {
    /// How often the line is read; the gain is ramped in between, so it
    /// neither clicks nor steps.
    static let controlFrames = 64

    // Shared with the render thread under `lock`. The main thread holds it
    // only to swap values; the render thread never waits for it.
    private let lock: UnsafeMutablePointer<os_unfair_lock> = {
        let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        return lock
    }()
    private var curve: UnsafeMutablePointer<VolumeAutomationPoint>?
    private var curveCount = 0
    private var isRunning = false
    private var heldTime = 0.0
    private var anchorGeneration = 0
    private var anchorHost: UInt64 = 0
    private var anchorFrame: Int64 = 0

    // Set while not rendering.
    private(set) var capacity = 0
    private(set) var left = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private(set) var right = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    var sampleRate = 48_000.0

    // Render thread only.
    private var renderAnchorGeneration = -1
    private var renderAnchorSample = 0.0
    private var gain: Float = 1
    private let secondsPerHostTick: Double

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        secondsPerHostTick = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000.0
    }

    func allocate(frames: Int) {
        guard frames > capacity else { return }
        left.deallocate()
        right.deallocate()
        capacity = frames
        left = .allocate(capacity: frames)
        right = .allocate(capacity: frames)
    }

    // MARK: Main thread

    /// Nil: no automation, the signal passes unchanged.
    func setCurve(_ points: [VolumeAutomationPoint]?) {
        var copy: UnsafeMutablePointer<VolumeAutomationPoint>?
        if let points {
            copy = .allocate(capacity: max(1, points.count))
            copy?.initialize(from: points, count: points.count)
        }
        os_unfair_lock_lock(lock)
        let old = curve
        curve = copy
        curveCount = points?.count ?? 0
        os_unfair_lock_unlock(lock)
        // Out of the lock's reach, so the render thread no longer reads it.
        old?.deallocate()
    }

    /// While stopped the gain stays at the line's value at this time, which
    /// live input and live notes pass through.
    func setHeldTime(_ time: Double) {
        os_unfair_lock_lock(lock)
        heldTime = time
        os_unfair_lock_unlock(lock)
    }

    func start(anchorHost host: UInt64, anchorFrame frame: Int64) {
        os_unfair_lock_lock(lock)
        anchorHost = host
        anchorFrame = frame
        anchorGeneration += 1
        isRunning = true
        os_unfair_lock_unlock(lock)
    }

    func setAnchorFrame(_ frame: Int64) {
        os_unfair_lock_lock(lock)
        anchorFrame = frame
        os_unfair_lock_unlock(lock)
    }

    func stop(heldTime time: Double) {
        os_unfair_lock_lock(lock)
        isRunning = false
        heldTime = time
        os_unfair_lock_unlock(lock)
    }

    // MARK: Render thread

    func process(
        _ left: UnsafeMutablePointer<Float>,
        _ right: UnsafeMutablePointer<Float>,
        frames: Int,
        timestamp: UnsafePointer<AudioTimeStamp>
    ) {
        guard os_unfair_lock_trylock(lock) else {
            // The main thread is swapping a value: one cycle at the same gain.
            if gain != 1 {
                for frame in 0..<frames {
                    left[frame] *= gain
                    right[frame] *= gain
                }
            }
            return
        }
        defer { os_unfair_lock_unlock(lock) }

        guard let curve else {
            ramp(left, right, frames: frames, to: 1)
            return
        }
        let points = UnsafeBufferPointer(start: curve, count: curveCount)
        var position = heldTime
        var secondsPerFrame = 0.0
        if isRunning {
            let time = timestamp.pointee
            if anchorGeneration != renderAnchorGeneration {
                renderAnchorGeneration = anchorGeneration
                let hostNow = time.mFlags.contains(.hostTimeValid)
                    ? Double(time.mHostTime)
                    : Double(mach_absolute_time())
                renderAnchorSample = time.mSampleTime
                    + ((Double(anchorHost) - hostNow) * secondsPerHostTick * sampleRate).rounded()
            }
            secondsPerFrame = 1.0 / sampleRate
            position = (Double(anchorFrame) + (time.mSampleTime - renderAnchorSample)) * secondsPerFrame
        }

        var offset = 0
        while offset < frames {
            let count = min(frames - offset, Self.controlFrames)
            let end = position + Double(offset + count) * secondsPerFrame
            let level = VolumeAutomationScale.level(at: end, in: points)
            ramp(left + offset, right + offset, frames: count,
                 to: Float(VolumeAutomationScale.gain(forLevel: level)))
            offset += count
        }
    }

    private func ramp(
        _ left: UnsafeMutablePointer<Float>,
        _ right: UnsafeMutablePointer<Float>,
        frames: Int,
        to target: Float
    ) {
        if gain == target {
            guard target != 1 else { return }
            for frame in 0..<frames {
                left[frame] *= target
                right[frame] *= target
            }
            return
        }
        let step = (target - gain) / Float(frames)
        var current = gain
        for frame in 0..<frames {
            current += step
            left[frame] *= current
            right[frame] *= current
        }
        gain = target
    }

    deinit {
        curve?.deallocate()
        left.deallocate()
        right.deallocate()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }
}

/// A track's volume automation: a gain of its own after the inserts, apart
/// from the fader, whose position it leaves alone. Sends and the track's
/// meter come after it. It reads the line at the timeline position of the
/// audio passing through it; `AudioEngineManager` works that position out
/// from the latency still to come after this point.
final class VolumeAutomationAudioUnit: AUAudioUnit {
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x76617574, // 'vaut'
        componentManufacturer: 0x4D794457, // 'MyDW'
        componentFlags: 0,
        componentFlagsMask: 0
    )

    static let registration: Void = {
        AUAudioUnit.registerSubclass(
            VolumeAutomationAudioUnit.self,
            as: componentDescription,
            name: "MyDAW: Volume Automation",
            version: 1
        )
    }()

    private let kernel = VolumeAutomationKernel()
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!

    override init(
        componentDescription: AudioComponentDescription,
        options: AudioComponentInstantiationOptions = []
    ) throws {
        try super.init(componentDescription: componentDescription, options: options)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        inputBusArray = AUAudioUnitBusArray(
            audioUnit: self,
            busType: .input,
            busses: [try AUAudioUnitBus(format: format)]
        )
        outputBusArray = AUAudioUnitBusArray(
            audioUnit: self,
            busType: .output,
            busses: [try AUAudioUnitBus(format: format)]
        )
        maximumFramesToRender = 4096
    }

    func setCurve(_ points: [VolumeAutomationPoint]?) { kernel.setCurve(points) }
    func setHeldTime(_ time: Double) { kernel.setHeldTime(time) }
    func start(anchorHost: UInt64, anchorFrame: Int64) { kernel.start(anchorHost: anchorHost, anchorFrame: anchorFrame) }
    func setAnchorFrame(_ frame: Int64) { kernel.setAnchorFrame(frame) }
    func stop(heldTime: Double) { kernel.stop(heldTime: heldTime) }

    override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { outputBusArray }
    override var channelCapabilities: [NSNumber]? { [2, 2] }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        guard inputBusArray[0].format.channelCount == 2,
              outputBusArray[0].format.channelCount == 2 else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        kernel.sampleRate = outputBusArray[0].format.sampleRate
        kernel.allocate(frames: Int(maximumFramesToRender))
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let kernel = self.kernel
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pullInputBlock else { return kAudioUnitErr_NoConnection }
            let frames = Int(frameCount)
            guard frames <= kernel.capacity else { return kAudioUnitErr_TooManyFramesToProcess }
            let output = UnsafeMutableAudioBufferListPointer(outputData)
            guard output.count >= 2 else { return kAudioUnitErr_FormatNotSupported }

            let byteSize = UInt32(frames * MemoryLayout<Float>.size)
            if output[0].mData == nil { output[0].mData = UnsafeMutableRawPointer(kernel.left) }
            if output[1].mData == nil { output[1].mData = UnsafeMutableRawPointer(kernel.right) }
            output[0].mDataByteSize = byteSize
            output[1].mDataByteSize = byteSize
            var pullFlags = AudioUnitRenderActionFlags()
            let status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, outputData)
            guard status == noErr,
                  let left = output[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = output[1].mData?.assumingMemoryBound(to: Float.self) else { return status }
            kernel.process(left, right, frames: frames, timestamp: timestamp)
            return noErr
        }
    }
}
