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

    /// Runs of silence at least `minimumDuration` long inside the range, in
    /// seconds from its start. A frame is silent when every channel's sample
    /// is at or below `thresholdDB` (dBFS), judged sample by sample.
    static func silenceRanges(
        of url: URL,
        sourceStartTime: Double,
        duration: Double,
        thresholdDB: Double,
        minimumDuration: Double
    ) throws -> [Range<Double>] {
        let file = try AVAudioFile(forReading: url)
        let sampleRate = file.processingFormat.sampleRate
        let range = frameRange(of: file, sourceStartTime: sourceStartTime, duration: duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else {
            return []
        }
        let threshold = Float(pow(10.0, thresholdDB / 20.0))
        let minimumFrames = max(1, AVAudioFramePosition((minimumDuration * sampleRate).rounded()))
        var runs: [Range<Double>] = []
        var runStart: AVAudioFramePosition?
        func closeRun(at end: AVAudioFramePosition) {
            if let start = runStart, end - start >= minimumFrames {
                runs.append(Double(start - range.lowerBound) / sampleRate..<Double(end - range.lowerBound) / sampleRate)
            }
            runStart = nil
        }

        file.framePosition = range.lowerBound
        while file.framePosition < range.upperBound {
            let chunkStart = file.framePosition
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), range.upperBound - chunkStart))
            try file.read(into: buffer, frameCount: frames)
            guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { break }
            let channelCount = Int(buffer.format.channelCount)
            for frame in 0..<Int(buffer.frameLength) {
                var isSilent = true
                for channel in 0..<channelCount where abs(channels[channel][frame]) > threshold {
                    isSilent = false
                    break
                }
                let position = chunkStart + AVAudioFramePosition(frame)
                if isSilent {
                    if runStart == nil { runStart = position }
                } else if runStart != nil {
                    closeRun(at: position)
                }
            }
        }
        closeRun(at: file.framePosition)
        return runs
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

extension ClipAudioProcessing {
    /// The stored format of an audio file.
    struct FileInfo {
        let channelCount: AVAudioChannelCount
        let sampleRate: Double
        let length: AVAudioFramePosition
        let bitDepth: Int
        let isFloat: Bool
    }

    static func fileInfo(_ url: URL) throws -> FileInfo {
        let file = try AVAudioFile(forReading: url)
        let settings = file.fileFormat.settings
        return FileInfo(
            channelCount: file.fileFormat.channelCount,
            sampleRate: file.fileFormat.sampleRate,
            length: file.length,
            bitDepth: (settings[AVLinearPCMBitDepthKey] as? NSNumber)?.intValue ?? 0,
            isFloat: (settings[AVLinearPCMIsFloatKey] as? NSNumber)?.boolValue ?? false
        )
    }

    /// What "Optimize Recordings" writes for one clip.
    struct ExtractPlan: Equatable {
        let frames: Range<AVAudioFramePosition>
        let channelCount: AVAudioChannelCount
        let sampleRate: Double
        let bitDepth: Int
        /// Where the clip starts in the new file: the part of a source
        /// sample it started inside of.
        let sourceStartTime: Double
    }

    enum ExtractDecision: Equatable {
        /// The clip plays no frame of the file.
        case nothing
        /// The file is already exactly what the clip needs.
        case keep
        case extract(ExtractPlan)
    }

    /// The file a clip needs: only the frames it plays; one channel on a
    /// mono track, otherwise the source's (at most two); the source rate,
    /// lowered to `targetSampleRate` but never raised; 16-bit for integer
    /// sources of 16 bits or less, otherwise 24-bit.
    static func extractDecision(
        for info: FileInfo,
        sourceStartTime: Double,
        duration: Double,
        isMonoTrack: Bool,
        targetSampleRate: Double
    ) -> ExtractDecision {
        let start = min(info.length, max(0, AVAudioFramePosition((sourceStartTime * info.sampleRate).rounded(.down))))
        let end = min(info.length, AVAudioFramePosition(((sourceStartTime + duration) * info.sampleRate).rounded(.up)))
        guard end > start else { return .nothing }
        let channelCount: AVAudioChannelCount = isMonoTrack ? 1 : min(2, info.channelCount)
        let sampleRate = info.sampleRate - targetSampleRate > 0.5 ? targetSampleRate : info.sampleRate
        let bitDepth = !info.isFloat && info.bitDepth <= 16 ? 16 : 24
        if start == 0, end == info.length, channelCount == info.channelCount,
           sampleRate == info.sampleRate, bitDepth == info.bitDepth, !info.isFloat {
            return .keep
        }
        return .extract(ExtractPlan(
            frames: start..<end,
            channelCount: channelCount,
            sampleRate: sampleRate,
            bitDepth: bitDepth,
            sourceStartTime: sourceStartTime - Double(start) / info.sampleRate
        ))
    }

    /// Writes `frames` of `url` to `destination` as an integer WAV of
    /// `bitDepth` bits at `sampleRate`. With one channel, a stereo source is
    /// mixed as (L + R) / 2, as a mono track plays it; with two, a mono
    /// source is doubled. Only the first two source channels are used.
    static func writeExtract(
        from url: URL,
        frames range: Range<AVAudioFramePosition>,
        channelCount: AVAudioChannelCount,
        sampleRate: Double,
        bitDepth: Int,
        to destination: URL
    ) throws {
        let source = try AVAudioFile(forReading: url)
        let inputFormat = source.processingFormat
        let inputChannels = Int(inputFormat.channelCount)
        guard inputChannels > 0,
              let mixedFormat = AVAudioFormat(standardFormatWithSampleRate: inputFormat.sampleRate, channels: channelCount),
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount),
              let readBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: chunkFrames),
              let mixedBuffer = AVAudioPCMBuffer(pcmFormat: mixedFormat, frameCapacity: chunkFrames) else {
            throw NSError(domain: "MyDAW.Optimize", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Unsupported audio format: \(inputFormat.description)")
            ])
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: bitDepth,
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

        source.framePosition = range.lowerBound
        /// Reads the next chunk of the range into `mixedBuffer` with the
        /// output's channels; false at the end of the range.
        func readNext() throws -> Bool {
            try Task.checkCancellation()
            let remaining = range.upperBound - source.framePosition
            guard remaining > 0 else { return false }
            try source.read(into: readBuffer, frameCount: AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), remaining)))
            let frames = Int(readBuffer.frameLength)
            guard frames > 0,
                  let input = readBuffer.floatChannelData,
                  let mixed = mixedBuffer.floatChannelData else { return false }
            if channelCount == 1 && inputChannels > 1 {
                for frame in 0..<frames {
                    mixed[0][frame] = (input[0][frame] + input[1][frame]) * 0.5
                }
            } else {
                for channel in 0..<Int(channelCount) {
                    mixed[channel].update(from: input[min(channel, inputChannels - 1)], count: frames)
                }
            }
            mixedBuffer.frameLength = AVAudioFrameCount(frames)
            return true
        }

        if abs(inputFormat.sampleRate - sampleRate) <= 0.5 {
            while try readNext() {
                try output.write(from: mixedBuffer)
            }
            return
        }

        guard let converter = AVAudioConverter(from: mixedFormat, to: outputFormat),
              let outputBuffer = AVAudioPCMBuffer(
                  pcmFormat: outputFormat,
                  frameCapacity: AVAudioFrameCount(Double(chunkFrames) * sampleRate / inputFormat.sampleRate) + 1024
              ) else {
            throw NSError(domain: "MyDAW.Optimize", code: 2, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Unsupported audio format: \(inputFormat.description)")
            ])
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        var readError: Error?
        var reachedEnd = false
        while true {
            outputBuffer.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
                do {
                    if !reachedEnd, try readNext() {
                        inputStatus.pointee = .haveData
                        return mixedBuffer
                    }
                } catch {
                    readError = error
                }
                reachedEnd = true
                inputStatus.pointee = .endOfStream
                return nil
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
