import AVFoundation
import AudioToolbox

private final class MonoDownmixKernel {
    // Read on the render thread; a torn read only delays the switch a buffer.
    var isMono = false
    private(set) var capacity = 0
    private(set) var left = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private(set) var right = UnsafeMutablePointer<Float>.allocate(capacity: 1)

    func allocate(frames: Int) {
        guard frames > capacity else { return }
        release()
        capacity = frames
        left = .allocate(capacity: frames)
        right = .allocate(capacity: frames)
    }

    private func release() {
        left.deallocate()
        right.deallocate()
    }

    deinit {
        release()
    }
}

/// Head of every track's chain. For a mono track it sums L and R at half gain
/// into both sides, so stereo clips play as mono without touching their
/// files; a mono clip (already L = R) passes unchanged. Stereo tracks pass
/// through as is.
final class MonoDownmixAudioUnit: AUAudioUnit {
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x6D6E6478, // 'mndx'
        componentManufacturer: 0x4D794457, // 'MyDW'
        componentFlags: 0,
        componentFlagsMask: 0
    )

    static let registration: Void = {
        AUAudioUnit.registerSubclass(
            MonoDownmixAudioUnit.self,
            as: componentDescription,
            name: "MyDAW: Mono Downmix",
            version: 1
        )
    }()

    private let kernel = MonoDownmixKernel()
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

    var isMono: Bool {
        get { kernel.isMono }
        set { kernel.isMono = newValue }
    }

    override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { outputBusArray }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        guard inputBusArray[0].format.channelCount == 2,
              outputBusArray[0].format.channelCount == 2 else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
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

            // Render the input straight into the output buffers (our own when
            // the host passes none), then downmix in place.
            let byteSize = UInt32(frames * MemoryLayout<Float>.size)
            if output[0].mData == nil { output[0].mData = UnsafeMutableRawPointer(kernel.left) }
            if output[1].mData == nil { output[1].mData = UnsafeMutableRawPointer(kernel.right) }
            output[0].mDataByteSize = byteSize
            output[1].mDataByteSize = byteSize
            var pullFlags = AudioUnitRenderActionFlags()
            let status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, outputData)
            guard status == noErr else { return status }

            guard kernel.isMono,
                  let leftData = output[0].mData,
                  let rightData = output[1].mData else { return noErr }
            let left = leftData.assumingMemoryBound(to: Float.self)
            let right = rightData.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames {
                let mono = 0.5 * (left[frame] + right[frame])
                left[frame] = mono
                right[frame] = mono
            }
            return noErr
        }
    }
}
