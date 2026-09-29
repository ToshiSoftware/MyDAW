import Foundation
import AVFoundation

/// Offline reads and renders over the part of an audio file a clip plays.
enum ClipAudioProcessing {
    private static let chunkFrames: AVAudioFrameCount = 65_536

    /// Frame range of `file` covered by `sourceStartTime` + `duration` seconds.
    private static func frameRange(
        of file: AVAudioFile,
        sourceStartTime: Double,
        duration: Double
    ) -> Range<AVAudioFramePosition> {
        let sampleRate = file.processingFormat.sampleRate
        let start = min(file.length, max(0, AVAudioFramePosition(sourceStartTime * sampleRate)))
        let end = min(file.length, start + AVAudioFramePosition((duration * sampleRate).rounded()))
        return start..<max(start, end)
    }

    /// Largest absolute sample value (all channels) in the range, 0...∞.
    static func peakAmplitude(of url: URL, sourceStartTime: Double, duration: Double) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        let range = frameRange(of: file, sourceStartTime: sourceStartTime, duration: duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else {
            return 0
        }
        var peak: Float = 0
        file.framePosition = range.lowerBound
        while file.framePosition < range.upperBound {
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), range.upperBound - file.framePosition))
            try file.read(into: buffer, frameCount: frames)
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { break }
            for channel in 0..<Int(buffer.format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) {
                    peak = max(peak, abs(channels[channel][frame]))
                }
            }
        }
        return peak
    }

    /// Writes the range reversed to a new 32-bit float WAV at `destination`.
    static func writeReversed(
        from url: URL,
        sourceStartTime: Double,
        duration: Double,
        to destination: URL
    ) throws {
        let source = try AVAudioFile(forReading: url)
        let format = source.processingFormat
        let range = frameRange(of: source, sourceStartTime: sourceStartTime, duration: duration)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = try AVAudioFile(
            forWriting: destination,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { return }

        // Walk the range from its end, reversing each chunk as it is written.
        var chunkEnd = range.upperBound
        while chunkEnd > range.lowerBound {
            let chunkStart = max(range.lowerBound, chunkEnd - AVAudioFramePosition(chunkFrames))
            source.framePosition = chunkStart
            try source.read(into: buffer, frameCount: AVAudioFrameCount(chunkEnd - chunkStart))
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { break }
            let count = Int(buffer.frameLength)
            for channel in 0..<Int(format.channelCount) {
                let samples = channels[channel]
                var low = 0
                var high = count - 1
                while low < high {
                    samples.swapAt(low, high)
                    low += 1
                    high -= 1
                }
            }
            try output.write(from: buffer)
            chunkEnd = chunkStart
        }
    }
}

extension ClipAudioProcessing {
    /// True when the file is already 24-bit integer PCM at `sampleRate`.
    static func is24BitPCM(_ url: URL, sampleRate: Double) throws -> Bool {
        let settings = try AVAudioFile(forReading: url).fileFormat.settings
        let bitDepth = (settings[AVLinearPCMBitDepthKey] as? NSNumber)?.intValue ?? 0
        let isFloat = (settings[AVLinearPCMIsFloatKey] as? NSNumber)?.boolValue ?? false
        let rate = (settings[AVSampleRateKey] as? NSNumber)?.doubleValue ?? 0
        return bitDepth == 24 && !isFloat && abs(rate - sampleRate) <= 0.5
    }

    /// Writes the whole file to `destination` as a 24-bit integer WAV at
    /// `sampleRate`, keeping its channel count.
    static func writeConverted(from url: URL, to destination: URL, sampleRate: Double) throws {
        let source = try AVAudioFile(forReading: url)
        let inputFormat = source.processingFormat
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: inputFormat.channelCount,
            interleaved: false
        ),
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
        let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: chunkFrames),
        let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: AVAudioFrameCount(Double(chunkFrames) * sampleRate / inputFormat.sampleRate) + 1024
        ) else {
            throw NSError(domain: "MyDAW.Import", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Unsupported audio format: \(inputFormat.description)")
            ])
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: inputFormat.channelCount,
            AVLinearPCMBitDepthKey: 24,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = try AVAudioFile(
            forWriting: destination,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        var readError: Error?
        var reachedEnd = false
        while true {
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                if reachedEnd || source.framePosition >= source.length {
                    reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try source.read(into: inputBuffer, frameCount: chunkFrames)
                } catch {
                    readError = error
                    reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if inputBuffer.frameLength == 0 {
                    reachedEnd = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return inputBuffer
            }
            if let error = readError ?? conversionError { throw error }
            if outputBuffer.frameLength > 0 {
                try output.write(from: outputBuffer)
            }
            if status == .endOfStream || status == .error { break }
        }
    }
}

private extension UnsafeMutablePointer where Pointee == Float {
    func swapAt(_ i: Int, _ j: Int) {
        let value = self[i]
        self[i] = self[j]
        self[j] = value
    }
}
