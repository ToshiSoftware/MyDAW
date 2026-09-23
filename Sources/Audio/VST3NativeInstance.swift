import Foundation
import AppKit
import AVFoundation

@_silgen_name("MyDAWVST3Create")
private func myDAWVST3Create(_ bundlePath: UnsafePointer<CChar>, _ pluginUID: UnsafePointer<CChar>, _ sampleRate: Double, _ maxFrames: Int32) -> UnsafeMutableRawPointer?
@_silgen_name("MyDAWVST3ProcessInterleaved")
private func myDAWVST3ProcessInterleaved(_ instance: UnsafeMutableRawPointer?, _ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>, _ frames: Int32, _ channels: Int32) -> Int32
@_silgen_name("MyDAWVST3GetLatencySamples")
private func myDAWVST3GetLatencySamples(_ instance: UnsafeMutableRawPointer?) -> Int32
@_silgen_name("MyDAWVST3GetState")
private func myDAWVST3GetState(_ instance: UnsafeMutableRawPointer?, _ data: UnsafeMutablePointer<UnsafeMutableRawPointer?>, _ size: UnsafeMutablePointer<Int32>) -> Int32
@_silgen_name("MyDAWVST3SetState")
private func myDAWVST3SetState(_ instance: UnsafeMutableRawPointer?, _ data: UnsafeRawPointer, _ size: Int32) -> Int32
@_silgen_name("MyDAWVST3FreeState")
private func myDAWVST3FreeState(_ data: UnsafeMutableRawPointer?)
@_silgen_name("MyDAWVST3AttachEditor")
private func myDAWVST3AttachEditor(_ instance: UnsafeMutableRawPointer?, _ parentView: UnsafeMutableRawPointer, _ width: UnsafeMutablePointer<Int32>, _ height: UnsafeMutablePointer<Int32>) -> Int32
@_silgen_name("MyDAWVST3RemoveEditor")
private func myDAWVST3RemoveEditor(_ instance: UnsafeMutableRawPointer?)
@_silgen_name("MyDAWVST3Destroy")
private func myDAWVST3Destroy(_ instance: UnsafeMutableRawPointer?)

public final class VST3NativeInstance {
    private var handle: UnsafeMutableRawPointer?
    private let maxFrames: Int
    public let latencySamples: Int

    public init?(descriptor: TrackPluginDescriptor, sampleRate: Double, maxFrames: Int) {
        guard descriptor.kind == .vst3, let bundlePath = descriptor.bundleURL,
              let pluginUID = descriptor.pluginUID, maxFrames > 0 else { return nil }
        let createdHandle = bundlePath.withCString { path in
            pluginUID.withCString { uid in myDAWVST3Create(path, uid, sampleRate, Int32(maxFrames)) }
        }
        guard let createdHandle else { return nil }
        handle = createdHandle
        self.maxFrames = maxFrames
        latencySamples = Int(myDAWVST3GetLatencySamples(createdHandle))
    }

    public func process(buffer: AVAudioPCMBuffer) -> Bool {
        guard let handle,
              buffer.format.commonFormat == .pcmFormatFloat32,
              buffer.format.channelCount == 2,
              let channelData = buffer.floatChannelData else {
            return false
        }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return true }
        var input = [Float](repeating: 0.0, count: maxFrames * 2)
        var output = [Float](repeating: 0.0, count: maxFrames * 2)

        var frameOffset = 0
        while frameOffset < frameCount {
            let blockFrames = min(maxFrames, frameCount - frameOffset)
            for frame in 0..<blockFrames {
                input[frame * 2] = channelData[0][frameOffset + frame]
                input[frame * 2 + 1] = channelData[1][frameOffset + frame]
            }

            let result = input.withUnsafeBufferPointer { inputBuffer in
                output.withUnsafeMutableBufferPointer { outputBuffer in
                    myDAWVST3ProcessInterleaved(
                        handle,
                        inputBuffer.baseAddress!,
                        outputBuffer.baseAddress!,
                        Int32(blockFrames),
                        2
                    )
                }
            }
            guard result == 0 else { return false }

            for frame in 0..<blockFrames {
                channelData[0][frameOffset + frame] = output[frame * 2]
                channelData[1][frameOffset + frame] = output[frame * 2 + 1]
            }
            frameOffset += blockFrames
        }
        return true
    }

    public func processInterleaved(_ input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        guard let handle, frames > 0, frames <= maxFrames else { return false }
        return myDAWVST3ProcessInterleaved(handle, input, output, Int32(frames), 2) == 0
    }

    public func captureState() -> Data? {
        var statePointer: UnsafeMutableRawPointer?
        var stateSize: Int32 = 0
        guard myDAWVST3GetState(handle, &statePointer, &stateSize) == 0,
              let statePointer, stateSize > 0 else { return nil }
        defer { myDAWVST3FreeState(statePointer) }
        return Data(bytes: statePointer, count: Int(stateSize))
    }

    @discardableResult
    public func restoreState(_ data: Data) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return false }
            return myDAWVST3SetState(handle, baseAddress, Int32(data.count)) == 0
        }
    }

    public func attachEditor(to parentView: NSView) -> NSSize? {
        guard let handle else { return nil }
        var width: Int32 = 0
        var height: Int32 = 0
        let result = myDAWVST3AttachEditor(handle, Unmanaged.passUnretained(parentView).toOpaque(), &width, &height)
        guard result == 0 else {
            print("VST3 editor attach failed with code \(result)")
            return nil
        }
        return NSSize(width: Int(width), height: Int(height))
    }

    public func removeEditor() {
        myDAWVST3RemoveEditor(handle)
    }

    deinit {
        myDAWVST3RemoveEditor(handle)
        myDAWVST3Destroy(handle)
    }
}
