import AVFoundation
import AudioToolbox

private func fourCharCode(_ string: String) -> FourCharCode {
    string.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
}

private final class VST3RenderKernel {
    var instance: VST3NativeInstance?
    var bypassed = false
    // A node pulled twice for the same render cycle must not run the plug-in
    // twice (its state would advance at double speed); replay the output.
    var lastSampleTime: Float64 = -1
    var lastFrames = 0
    private(set) var capacity = 0
    private(set) var inputLeft = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private(set) var inputRight = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private(set) var scratchLeft = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private(set) var scratchRight = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private(set) var cacheLeft = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private(set) var cacheRight = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    let inputList = AudioBufferList.allocate(maximumBuffers: 2)

    func allocate(frames: Int) {
        guard frames > capacity else { return }
        free()
        capacity = frames
        inputLeft = .allocate(capacity: frames)
        inputRight = .allocate(capacity: frames)
        scratchLeft = .allocate(capacity: frames)
        scratchRight = .allocate(capacity: frames)
        cacheLeft = .allocate(capacity: frames)
        cacheRight = .allocate(capacity: frames)
        lastSampleTime = -1
    }

    private func free() {
        inputLeft.deallocate()
        inputRight.deallocate()
        scratchLeft.deallocate()
        scratchRight.deallocate()
        cacheLeft.deallocate()
        cacheRight.deallocate()
    }

    deinit {
        free()
        inputList.unsafeMutablePointer.deallocate()
    }
}

/// Hosts one VST3 effect as an in-process AUv3 effect so it can sit in the
/// AVAudioEngine graph exactly like any other AU and be processed on the
/// render thread in graph order.
final class VST3AudioUnit: AUAudioUnit {
    static let componentDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: fourCharCode("vst3"),
        componentManufacturer: fourCharCode("MyDW"),
        componentFlags: 0,
        componentFlagsMask: 0
    )

    static let registration: Void = {
        AUAudioUnit.registerSubclass(
            VST3AudioUnit.self,
            as: componentDescription,
            name: "MyDAW: VST3 Host",
            version: 1
        )
    }()

    private let kernel = VST3RenderKernel()
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

    func attach(_ instance: VST3NativeInstance) {
        kernel.instance = instance
    }

    /// Only while the engine is stopped: drops the render path's reference so
    /// the instance (and its module) can be released.
    func detachInstance() {
        kernel.instance = nil
    }

    override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { outputBusArray }
    override var channelCapabilities: [NSNumber]? { [2, 2] }

    override var shouldBypassEffect: Bool {
        didSet { kernel.bypassed = shouldBypassEffect }
    }

    override var latency: TimeInterval {
        guard let instance = kernel.instance, instance.latencySamples > 0 else { return 0 }
        return Double(instance.latencySamples) / outputBusArray[0].format.sampleRate
    }

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
            let byteSize = UInt32(frames * MemoryLayout<Float>.size)
            let output = UnsafeMutableAudioBufferListPointer(outputData)
            guard output.count >= 2 else { return kAudioUnitErr_FormatNotSupported }

            let sampleTime = timestamp.pointee.mSampleTime
            let hasSampleTime = timestamp.pointee.mFlags.contains(.sampleTimeValid)
            if hasSampleTime, sampleTime == kernel.lastSampleTime, frames == kernel.lastFrames {
                if output[0].mData == nil { output[0].mData = UnsafeMutableRawPointer(kernel.scratchLeft) }
                if output[1].mData == nil { output[1].mData = UnsafeMutableRawPointer(kernel.scratchRight) }
                output[0].mDataByteSize = byteSize
                output[1].mDataByteSize = byteSize
                output[0].mData!.assumingMemoryBound(to: Float.self).update(from: kernel.cacheLeft, count: frames)
                output[1].mData!.assumingMemoryBound(to: Float.self).update(from: kernel.cacheRight, count: frames)
                return noErr
            }

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

            // VST3 plug-ins are not required to support in-place processing,
            // so never hand them output buffers that alias the input.
            let currentLeft = output[0].mData?.assumingMemoryBound(to: Float.self)
            if currentLeft == nil || currentLeft == inLeft || currentLeft == inRight {
                output[0].mData = UnsafeMutableRawPointer(kernel.scratchLeft)
            }
            let currentRight = output[1].mData?.assumingMemoryBound(to: Float.self)
            if currentRight == nil || currentRight == inLeft || currentRight == inRight {
                output[1].mData = UnsafeMutableRawPointer(kernel.scratchRight)
            }
            output[0].mDataByteSize = byteSize
            output[1].mDataByteSize = byteSize
            let outLeft = output[0].mData!.assumingMemoryBound(to: Float.self)
            let outRight = output[1].mData!.assumingMemoryBound(to: Float.self)

            let processed = !kernel.bypassed && (kernel.instance?.processStereo(
                inputLeft: inLeft,
                inputRight: inRight,
                outputLeft: outLeft,
                outputRight: outRight,
                frames: frames
            ) ?? false)
            if !processed {
                outLeft.update(from: inLeft, count: frames)
                outRight.update(from: inRight, count: frames)
            }
            if hasSampleTime {
                kernel.cacheLeft.update(from: outLeft, count: frames)
                kernel.cacheRight.update(from: outRight, count: frames)
                kernel.lastSampleTime = sampleTime
                kernel.lastFrames = frames
            }
            return noErr
        }
    }
}
