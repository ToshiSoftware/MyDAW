import AVFoundation
import AudioToolbox

/// State shared by a plug-in's capture and switch units (render thread,
/// except the flags and the latency, which are single aligned words).
final class PluginSwitchKernel {
    /// Longest plug-in latency the dry path can match.
    static let maximumLatencySeconds = 1.0
    private static let fadeSeconds = 0.01

    // Read on the render thread; a torn read only delays the switch a buffer.
    var isEnabled = true
    var latencyFrames = 0
    private(set) var capacity = 0
    private(set) var left = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private(set) var right = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private var size = 1
    private var mask = 0
    private var writeIndex = 0
    private var wetGain: Float = 1
    private var fadeStep: Float = 1

    /// Allocates for `frames` per render; called by both units, so it only
    /// grows. Not while rendering.
    func allocate(frames: Int, sampleRate: Double) {
        let needed = frames + Int(sampleRate * Self.maximumLatencySeconds) + 1
        fadeStep = Float(1 / max(sampleRate * Self.fadeSeconds, 1))
        guard needed > capacity else { return }
        left.deallocate()
        right.deallocate()
        capacity = needed
        size = 1
        while size < needed { size <<= 1 }
        mask = size - 1
        left = .allocate(capacity: size)
        right = .allocate(capacity: size)
        left.initialize(repeating: 0, count: size)
        right.initialize(repeating: 0, count: size)
        writeIndex = 0
        wetGain = isEnabled ? 1 : 0
    }

    /// Capture side: keeps the plug-in's input.
    func capture(_ inLeft: UnsafePointer<Float>, _ inRight: UnsafePointer<Float>, frames: Int) {
        for frame in 0..<frames {
            left[writeIndex] = inLeft[frame]
            right[writeIndex] = inRight[frame]
            writeIndex = (writeIndex + 1) & mask
        }
    }

    /// Switch side, after the plug-in rendered the same `frames`: mixes the
    /// plug-in's output (in place) with its input delayed by its latency.
    func mix(_ outLeft: UnsafeMutablePointer<Float>, _ outRight: UnsafeMutablePointer<Float>, frames: Int) {
        let target: Float = isEnabled ? 1 : 0
        if wetGain == 1 && target == 1 { return }
        let latency = min(max(latencyFrames, 0), size - frames - 1)
        var read = (writeIndex - frames - latency) & mask
        for frame in 0..<frames {
            if wetGain < target {
                wetGain = min(wetGain + fadeStep, target)
            } else if wetGain > target {
                wetGain = max(wetGain - fadeStep, target)
            }
            outLeft[frame] = left[read] + wetGain * (outLeft[frame] - left[read])
            outRight[frame] = right[read] + wetGain * (outRight[frame] - right[read])
            read = (read + 1) & mask
        }
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }
}

/// Output buffers of one switch unit.
final class PluginSwitchBuffers {
    private(set) var capacity = 0
    private(set) var left = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private(set) var right = UnsafeMutablePointer<Float>.allocate(capacity: 1)

    func allocate(frames: Int) {
        guard frames > capacity else { return }
        left.deallocate()
        right.deallocate()
        capacity = frames
        left = .allocate(capacity: frames)
        right = .allocate(capacity: frames)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }
}

/// Wraps every chain plug-in as capture → plug-in → switch, so turning a
/// plug-in off plays its input instead of relying on the plug-in's own
/// bypass (Relab LX480 Essentials, bypassed, outputs its left input on both
/// sides). Switching is a flag with a 10 ms crossfade: no reconnection, so
/// it works while playing. The dry signal is delayed by the plug-in's
/// latency, so latency compensation does not move. Both roles pass their
/// input through; only the switch changes it.
final class PluginSwitchAudioUnit: AUAudioUnit {
    enum Role {
        case capture
        case output
    }

    static let captureDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x70736363, // 'pscc'
        componentManufacturer: 0x4D794457, // 'MyDW'
        componentFlags: 0,
        componentFlagsMask: 0
    )

    static let outputDescription = AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: 0x7073776F, // 'pswo'
        componentManufacturer: 0x4D794457, // 'MyDW'
        componentFlags: 0,
        componentFlagsMask: 0
    )

    static let registration: Void = {
        AUAudioUnit.registerSubclass(PluginSwitchAudioUnit.self, as: captureDescription,
                                     name: "MyDAW: Plug-in Switch In", version: 1)
        AUAudioUnit.registerSubclass(PluginSwitchAudioUnit.self, as: outputDescription,
                                     name: "MyDAW: Plug-in Switch Out", version: 1)
    }()

    /// Set right after instantiation, before the units are connected.
    var kernel = PluginSwitchKernel()
    let role: Role
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!
    private let buffers = PluginSwitchBuffers()

    override init(
        componentDescription: AudioComponentDescription,
        options: AudioComponentInstantiationOptions = []
    ) throws {
        role = componentDescription.componentSubType == Self.captureDescription.componentSubType ? .capture : .output
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

    override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    override var outputBusses: AUAudioUnitBusArray { outputBusArray }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        guard inputBusArray[0].format.channelCount == 2,
              outputBusArray[0].format.channelCount == 2 else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        kernel.allocate(frames: Int(maximumFramesToRender), sampleRate: outputBusArray[0].format.sampleRate)
        buffers.allocate(frames: Int(maximumFramesToRender))
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        let kernel = self.kernel
        let role = self.role
        let buffers = self.buffers
        return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
            guard let pullInputBlock else { return kAudioUnitErr_NoConnection }
            let frames = Int(frameCount)
            guard frames <= buffers.capacity else { return kAudioUnitErr_TooManyFramesToProcess }
            let output = UnsafeMutableAudioBufferListPointer(outputData)
            guard output.count >= 2 else { return kAudioUnitErr_FormatNotSupported }

            // Render the input straight into the output buffers (our own when
            // the host passes none), then work in place.
            let byteSize = UInt32(frames * MemoryLayout<Float>.size)
            if output[0].mData == nil { output[0].mData = UnsafeMutableRawPointer(buffers.left) }
            if output[1].mData == nil { output[1].mData = UnsafeMutableRawPointer(buffers.right) }
            output[0].mDataByteSize = byteSize
            output[1].mDataByteSize = byteSize
            var pullFlags = AudioUnitRenderActionFlags()
            let status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, outputData)
            guard status == noErr,
                  let leftData = output[0].mData,
                  let rightData = output[1].mData else { return status }
            let left = leftData.assumingMemoryBound(to: Float.self)
            let right = rightData.assumingMemoryBound(to: Float.self)
            switch role {
            case .capture:
                kernel.capture(left, right, frames: frames)
            case .output:
                kernel.mix(left, right, frames: frames)
            }
            return noErr
        }
    }
}
