import AudioToolbox
import Foundation

/// The DSP side of a MyFX effect, as the shared render block drives it.
public protocol MyFXRenderKernel: AnyObject {
    /// Render thread: a parameter event at the current position.
    func applyParameter(_ address: AUParameterAddress, _ value: AUValue)

    /// Processes up to the prepared maximum of frames; output may be the
    /// same memory as input. `outputRight` is nil for mono, and then
    /// `inputLeft` and `inputRight` are the same channel.
    func process(
        inputLeft: UnsafePointer<Float>,
        inputRight: UnsafePointer<Float>,
        outputLeft: UnsafeMutablePointer<Float>,
        outputRight: UnsafeMutablePointer<Float>?,
        frameCount: Int
    )
}

/// Input buffers and the render block of a 1- or 2-channel MyFX effect
/// (Float32, deinterleaved, input channels = output channels). It pulls the
/// input into its own buffers, renders in place when the host gives no
/// output buffers, and splits each buffer at parameter events so automation
/// is sample-accurate.
public final class MyFXRenderer {
    public private(set) var capacity = 0
    private var channelCount = 2
    private let list = AudioBufferList.allocate(maximumBuffers: 2)
    private var left = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private var right = UnsafeMutablePointer<Float>.allocate(capacity: 1)

    public init() {}

    deinit {
        left.deallocate()
        right.deallocate()
        free(list.unsafeMutablePointer)
    }

    /// From allocateRenderResources (not while rendering).
    public func allocate(frames: Int, channelCount: Int) {
        left.deallocate()
        right.deallocate()
        capacity = frames
        self.channelCount = channelCount
        left = .allocate(capacity: frames)
        right = .allocate(capacity: frames)
        left.initialize(repeating: 0, count: frames)
        right.initialize(repeating: 0, count: frames)
    }

    public func makeRenderBlock<Kernel: MyFXRenderKernel>(kernel: Kernel) -> AUInternalRenderBlock {
        return { [self] _, timestamp, frameCount, _, outputData, realtimeEventListHead, pullInputBlock in
            guard let pullInputBlock else { return kAudioUnitErr_NoConnection }
            let frames = Int(frameCount)
            guard frames <= capacity else { return kAudioUnitErr_TooManyFramesToProcess }
            let channels = channelCount

            let inputData = prepareInput(frames: frames)
            var pullFlags = AudioUnitRenderActionFlags()
            let status = pullInputBlock(&pullFlags, timestamp, frameCount, 0, inputData)
            guard status == noErr else { return status }

            let input = UnsafeMutableAudioBufferListPointer(inputData)
            let output = UnsafeMutableAudioBufferListPointer(outputData)
            guard input.count >= channels, output.count >= channels else {
                return kAudioUnitErr_FormatNotSupported
            }
            let byteSize = UInt32(frames * MemoryLayout<Float>.size)
            for channel in 0..<channels {
                // No output buffer from the host: process in place.
                if output[channel].mData == nil { output[channel].mData = input[channel].mData }
                output[channel].mDataByteSize = byteSize
            }
            guard let inputLeftData = input[0].mData, let outputLeftData = output[0].mData else {
                return kAudioUnitErr_InvalidParameter
            }
            let inputLeft = UnsafePointer(inputLeftData.assumingMemoryBound(to: Float.self))
            let outputLeft = outputLeftData.assumingMemoryBound(to: Float.self)
            var inputRight = inputLeft
            var outputRight: UnsafeMutablePointer<Float>?
            if channels > 1 {
                guard let inputRightData = input[1].mData, let outputRightData = output[1].mData else {
                    return kAudioUnitErr_InvalidParameter
                }
                inputRight = UnsafePointer(inputRightData.assumingMemoryBound(to: Float.self))
                outputRight = outputRightData.assumingMemoryBound(to: Float.self)
            }

            // Split the buffer at each parameter event (sample-accurate automation).
            let bufferStart = AUEventSampleTime(timestamp.pointee.mSampleTime)
            var event = realtimeEventListHead
            var segmentStart = 0
            while segmentStart < frames {
                var segmentEnd = frames
                while let current = event {
                    let offset = Int(min(max(current.pointee.head.eventSampleTime - bufferStart, 0),
                                         AUEventSampleTime(frames)))
                    if offset > segmentStart {
                        segmentEnd = offset
                        break
                    }
                    switch current.pointee.head.eventType {
                    case .parameter, .parameterRamp:
                        // A ramp jumps to its end value; the kernel's smoothing glides there.
                        let change = current.pointee.parameter
                        kernel.applyParameter(change.parameterAddress, change.value)
                    default:
                        break
                    }
                    event = UnsafePointer(current.pointee.head.next)
                }
                kernel.process(
                    inputLeft: inputLeft + segmentStart,
                    inputRight: inputRight + segmentStart,
                    outputLeft: outputLeft + segmentStart,
                    outputRight: outputRight.map { $0 + segmentStart },
                    frameCount: segmentEnd - segmentStart
                )
                segmentStart = segmentEnd
            }
            return noErr
        }
    }

    /// Points the input list at our buffers; the upstream unit may replace mData.
    @inline(__always)
    private func prepareInput(frames: Int) -> UnsafeMutablePointer<AudioBufferList> {
        let byteSize = UInt32(frames * MemoryLayout<Float>.size)
        list.count = channelCount
        list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteSize, mData: UnsafeMutableRawPointer(left))
        if channelCount > 1 {
            list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteSize, mData: UnsafeMutableRawPointer(right))
        }
        return list.unsafeMutablePointer
    }
}
