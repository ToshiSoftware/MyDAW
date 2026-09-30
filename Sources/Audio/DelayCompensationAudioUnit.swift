import AVFoundation
import AudioToolbox

/// A stereo delay line for the render thread: every frame goes in, and the
/// frame from `delay` frames earlier comes out. Its memory is set up off the
/// render thread; a delay it cannot hold passes the input through.
final class StereoDelayLine {
    private(set) var capacity = 0
    private var left = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private var right = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private var writeIndex = 0

    /// Only while not rendering. Clears the history.
    func allocate(frames: Int) {
        let frames = max(1, frames)
        if frames != capacity {
            left.deallocate()
            right.deallocate()
            left = .allocate(capacity: frames)
            right = .allocate(capacity: frames)
            capacity = frames
        }
        left.initialize(repeating: 0, count: capacity)
        right.initialize(repeating: 0, count: capacity)
        writeIndex = 0
    }

    /// Writes `frames` of input and, when outputs are given, reads the delayed
    /// signal into them. Outputs may be the inputs themselves.
    func process(
        inputLeft: UnsafePointer<Float>,
        inputRight: UnsafePointer<Float>,
        outputLeft: UnsafeMutablePointer<Float>?,
        outputRight: UnsafeMutablePointer<Float>?,
        frames: Int,
        delay: Int
    ) {
        let delay = delay < capacity ? max(0, delay) : 0
        for frame in 0..<frames {
            let inL = inputLeft[frame]
            let inR = inputRight[frame]
            left[writeIndex] = inL
            right[writeIndex] = inR
            var readIndex = writeIndex - delay
            if readIndex < 0 { readIndex += capacity }
            outputLeft?[frame] = left[readIndex]
            outputRight?[frame] = right[readIndex]
            writeIndex += 1
            if writeIndex == capacity { writeIndex = 0 }
        }
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }
}

private final class DelayCompensationKernel {
    let line = StereoDelayLine()
    /// Set from the main thread; read once per render cycle.
    var delayFrames = 0
    var isMuted = false
    private var gain: Float = 1
    private(set) var capacity = 0
    private(set) var inputLeft = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private(set) var inputRight = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    let inputList = AudioBufferList.allocate(maximumBuffers: 2)

    func allocate(frames: Int, sampleRate: Double) {
        if frames > capacity {
            inputLeft.deallocate()
            inputRight.deallocate()
            inputLeft = .allocate(capacity: frames)
            inputRight = .allocate(capacity: frames)
            capacity = frames
        }
        // One second covers any plug-in latency met in practice.
        line.allocate(frames: Int(sampleRate.rounded()) + frames)
        gain = isMuted ? 0 : 1
    }

    /// Ramps the mute over about 5 ms, so muting never clicks.
    func applyGain(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, frames: Int) {
        let target: Float = isMuted ? 0 : 1
        if gain == target {
            guard target == 0 else { return }
            left.update(repeating: 0, count: frames)
            right.update(repeating: 0, count: frames)
            return
        }
        let step: Float = 1.0 / 256.0
        for frame in 0..<frames {
            if gain < target {
                gain = min(target, gain + step)
            } else if gain > target {
                gain = max(target, gain - step)
            }
            left[frame] *= gain
            right[frame] *= gain
        }
    }

    deinit {
        inputLeft.deallocate()
        inputRight.deallocate()
        inputList.unsafeMutablePointer.deallocate()
    }
}

/// Delays its input by a set number of frames, and can mute it. Placed on
/// every track's dry path (delay D, the largest FX channel latency) and on
/// every FX return (D minus that channel's latency), so dry and wet sounds
/// line up. It reports no latency of its own: it is the compensation.
final class DelayCompensationAudioUnit: AUAudioUnit {
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x646C6370, // 'dlcp'
        componentManufacturer: 0x4D794457, // 'MyDW'
        componentFlags: 0,
        componentFlagsMask: 0
    )

    static let registration: Void = {
        AUAudioUnit.registerSubclass(
            DelayCompensationAudioUnit.self,
            as: componentDescription,
            name: "MyDAW: Delay Compensation",
            version: 1
        )
    }()

    private let kernel = DelayCompensationKernel()
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

    var delayFrames: Int {
        get { kernel.delayFrames }
        set { kernel.delayFrames = max(0, newValue) }
    }

    /// Silences the output (with a short ramp); the delay keeps running.
    var isMuted: Bool {
        get { kernel.isMuted }
        set { kernel.isMuted = newValue }
    }

    override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { outputBusArray }
    override var channelCapabilities: [NSNumber]? { [2, 2] }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        guard inputBusArray[0].format.channelCount == 2,
              outputBusArray[0].format.channelCount == 2 else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        kernel.allocate(frames: Int(maximumFramesToRender), sampleRate: outputBusArray[0].format.sampleRate)
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let kernel = self.kernel
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pullInputBlock else { return kAudioUnitErr_NoConnection }
            let frames = Int(frameCount)
            guard frames <= kernel.capacity else { return kAudioUnitErr_TooManyFramesToProcess }
            let byteSize = UInt32(frames * MemoryLayout<Float>.size)
            let output = UnsafeMutableAudioBufferListPointer(outputData)
            guard output.count >= 2 else { return kAudioUnitErr_FormatNotSupported }

            let input = kernel.inputList
            input[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteSize, mData: UnsafeMutableRawPointer(kernel.inputLeft))
            input[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteSize, mData: UnsafeMutableRawPointer(kernel.inputRight))
            var pullFlags = AudioUnitRenderActionFlags()
            let status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, input.unsafeMutablePointer)
            guard status == noErr else { return status }
            // The upstream node may have redirected mData to its own buffers.
            guard let inLeft = input[0].mData?.assumingMemoryBound(to: Float.self),
                  let inRight = input[1].mData?.assumingMemoryBound(to: Float.self) else {
                return kAudioUnitErr_InvalidParameter
            }

            if output[0].mData == nil { output[0].mData = UnsafeMutableRawPointer(kernel.inputLeft) }
            if output[1].mData == nil { output[1].mData = UnsafeMutableRawPointer(kernel.inputRight) }
            output[0].mDataByteSize = byteSize
            output[1].mDataByteSize = byteSize
            let outLeft = output[0].mData!.assumingMemoryBound(to: Float.self)
            let outRight = output[1].mData!.assumingMemoryBound(to: Float.self)

            kernel.line.process(
                inputLeft: inLeft,
                inputRight: inRight,
                outputLeft: outLeft,
                outputRight: outRight,
                frames: frames,
                delay: kernel.delayFrames
            )
            kernel.applyGain(outLeft, outRight, frames: frames)
            return noErr
        }
    }
}
