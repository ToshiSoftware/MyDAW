import AVFoundation
import AudioToolbox

private final class InputMonitorKernel {
    var channelOffset = 0
    var isStereo = true
    private(set) var capacity = 0
    private(set) var channelCount = 0
    private var buffers: [UnsafeMutablePointer<Float>] = []
    private(set) var inputList = AudioBufferList.allocate(maximumBuffers: 1)
    private(set) var silence = UnsafeMutablePointer<Float>.allocate(capacity: 1)

    func allocate(channels: Int, frames: Int) {
        guard channels != channelCount || frames > capacity else { return }
        release()
        channelCount = channels
        capacity = frames
        buffers = (0..<channels).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
        inputList = AudioBufferList.allocate(maximumBuffers: max(1, channels))
        silence = .allocate(capacity: frames)
        silence.initialize(repeating: 0, count: frames)
    }

    func buffer(_ channel: Int) -> UnsafeMutablePointer<Float> {
        buffers[channel]
    }

    private func release() {
        buffers.forEach { $0.deallocate() }
        buffers = []
        inputList.unsafeMutablePointer.deallocate()
        silence.deallocate()
    }

    deinit {
        release()
    }
}

/// Picks a track's input channel(s) out of the multichannel hardware input
/// so live input can be routed through the track's mixer and inserts.
final class InputMonitorAudioUnit: AUAudioUnit {
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x696E6D6E, // 'inmn'
        componentManufacturer: 0x4D794457, // 'MyDW'
        componentFlags: 0,
        componentFlagsMask: 0
    )

    static let registration: Void = {
        AUAudioUnit.registerSubclass(
            InputMonitorAudioUnit.self,
            as: componentDescription,
            name: "MyDAW: Input Monitor",
            version: 1
        )
    }()

    private let kernel = InputMonitorKernel()
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

    /// Set only while the engine is stopped.
    func configure(channelOffset: Int, isStereo: Bool) {
        kernel.channelOffset = channelOffset
        kernel.isStereo = isStereo
    }

    override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { outputBusArray }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        guard outputBusArray[0].format.channelCount == 2 else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        kernel.allocate(
            channels: Int(inputBusArray[0].format.channelCount),
            frames: Int(maximumFramesToRender)
        )
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let kernel = self.kernel
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pullInputBlock else { return kAudioUnitErr_NoConnection }
            let frames = Int(frameCount)
            guard frames <= kernel.capacity else { return kAudioUnitErr_TooManyFramesToProcess }
            let byteSize = UInt32(frames * MemoryLayout<Float>.size)

            let input = kernel.inputList
            for channel in 0..<kernel.channelCount {
                input[channel] = AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: byteSize,
                    mData: UnsafeMutableRawPointer(kernel.buffer(channel))
                )
            }
            var pullFlags = AudioUnitRenderActionFlags()
            let status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, input.unsafeMutablePointer)
            guard status == noErr else { return status }

            let output = UnsafeMutableAudioBufferListPointer(outputData)
            guard output.count >= 2 else { return kAudioUnitErr_FormatNotSupported }
            let leftChannel = kernel.channelOffset
            let rightChannel = kernel.isStereo ? kernel.channelOffset + 1 : kernel.channelOffset
            var left = kernel.silence
            if leftChannel >= 0, leftChannel < kernel.channelCount, let data = input[leftChannel].mData {
                left = data.assumingMemoryBound(to: Float.self)
            }
            var right = kernel.silence
            if rightChannel >= 0, rightChannel < kernel.channelCount, let data = input[rightChannel].mData {
                right = data.assumingMemoryBound(to: Float.self)
            }
            output[0].mDataByteSize = byteSize
            output[1].mDataByteSize = byteSize
            if let destination = output[0].mData {
                destination.assumingMemoryBound(to: Float.self).update(from: left, count: frames)
            } else {
                output[0].mData = UnsafeMutableRawPointer(left)
            }
            if let destination = output[1].mData {
                destination.assumingMemoryBound(to: Float.self).update(from: right, count: frames)
            } else {
                output[1].mData = UnsafeMutableRawPointer(right)
            }
            return noErr
        }
    }
}
