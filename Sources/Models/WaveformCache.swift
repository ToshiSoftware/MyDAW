import Foundation
import AVFoundation

public struct PeakPoint: Identifiable, Sendable {
    public let id: Int
    public let min: Float
    public let max: Float

    public init(id: Int, min: Float, max: Float) {
        self.id = id
        self.min = min
        self.max = max
    }
}

/// A fine-level peak: the lowest and highest sample of a short block,
/// stored as 16-bit values to keep the fine level small in memory.
public struct CompactPeak: Sendable {
    public let min: Int16
    public let max: Int16

    @inline(__always) public var minValue: Float { Float(min) / 32767.0 }
    @inline(__always) public var maxValue: Float { Float(max) / 32767.0 }

    init(min: Float, max: Float) {
        // Rounded outwards, so a peak is never drawn smaller than it is.
        self.min = Int16(Swift.max(-32767.0, Swift.min(32767.0, (min * 32767.0).rounded(.down))))
        self.max = Int16(Swift.max(-32767.0, Swift.min(32767.0, (max * 32767.0).rounded(.up))))
    }
}

@MainActor
public final class WaveformCache: ObservableObject {
    @Published public private(set) var peaks: [PeakPoint] = []
    @Published public private(set) var channelPeaks: [[PeakPoint]] = []
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var duration: Double = 0.0
    /// The fine level (`fineSamplesPerPeak` samples per peak), drawn when the
    /// view is zoomed in past one `samplesPerPeak` peak per point. Empty for
    /// a take still being recorded (its peaks arrive at the coarse level).
    @Published public private(set) var fineChannelPeaks: [[CompactPeak]] = []
    @Published public private(set) var fineCombinedPeaks: [CompactPeak] = []

    /// Raw samples around the visible part, read on demand when zoomed in
    /// past the fine level (see `requestSamples`).
    public struct SampleWindow: Sendable {
        public let startFrame: Int
        public let channels: [[Float]]
        /// The channel average (a mono track's lane).
        public let combined: [Float]
        public var endFrame: Int { startFrame + combined.count }

        public func samples(for channel: Int?) -> [Float] {
            guard let channel, channel >= 0, channel < channels.count else { return combined }
            return channels[channel]
        }
    }
    @Published public private(set) var sampleWindow: SampleWindow?
    private var sampleSourceURL: URL?
    private var pendingSampleRange: Range<Int>?
    private var sampleLoadGeneration = 0
    /// Longest range read for one request (frames at 48 kHz: 4 s), so a
    /// waveform drawn whole (the drag preview) never reads a whole file.
    private static let maximumSampleRequest = 4 * 48_000

    public let samplesPerPeak: Int
    /// About one peak per point at 800 px/s (48 kHz); zoomed in further, a
    /// peak spans several points.
    public nonisolated static let fineSamplesPerPeak = 64

    public init(samplesPerPeak: Int = 512) {
        self.samplesPerPeak = samplesPerPeak
    }

    public func clear() {
        peaks.removeAll(keepingCapacity: true)
        channelPeaks.removeAll(keepingCapacity: true)
        fineChannelPeaks.removeAll()
        fineCombinedPeaks.removeAll()
        duration = 0.0
        resetSampleWindow()
    }

    private func resetSampleWindow() {
        sampleWindow = nil
        pendingSampleRange = nil
        sampleLoadGeneration += 1
    }

    /// Makes `sampleWindow` cover `range` (frames of the file): reads it,
    /// with a margin on each side for scrolling, in the background unless
    /// it is already there or on its way. Cheap to call on every draw.
    public func requestSamples(_ range: Range<Int>) {
        guard let url = sampleSourceURL,
              !range.isEmpty,
              range.count <= Self.maximumSampleRequest else { return }
        if let window = sampleWindow,
           window.startFrame <= range.lowerBound, window.endFrame >= range.upperBound {
            return
        }
        if let pending = pendingSampleRange,
           pending.lowerBound <= range.lowerBound, pending.upperBound >= range.upperBound {
            return
        }
        let margin = range.count
        let load = max(0, range.lowerBound - margin)..<(range.upperBound + margin)
        pendingSampleRange = load
        sampleLoadGeneration += 1
        let generation = sampleLoadGeneration
        Task.detached(priority: .userInitiated) { [weak self] in
            let window = Self.readSamples(from: url, frames: load)
            await self?.applySampleWindow(window, generation: generation)
        }
    }

    private func applySampleWindow(_ window: SampleWindow?, generation: Int) {
        // A newer request or a new file supersedes this one. On failure the
        // pending range stays, so it is not retried on every draw.
        guard sampleLoadGeneration == generation, let window else { return }
        sampleWindow = window
        pendingSampleRange = nil
    }

    private nonisolated static func readSamples(from url: URL, frames: Range<Int>) -> SampleWindow? {
        do {
            let file = try AVAudioFile(forReading: url)
            let start = Int64(frames.lowerBound)
            guard start < file.length else { return nil }
            let count = AVAudioFrameCount(min(Int64(frames.count), file.length - start))
            let format = file.processingFormat
            guard count > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { return nil }
            file.framePosition = start
            try file.read(into: buffer, frameCount: count)
            guard let data = buffer.floatChannelData else { return nil }
            let length = Int(buffer.frameLength)
            let channelCount = Int(format.channelCount)
            let channels = (0..<channelCount).map { Array(UnsafeBufferPointer(start: data[$0], count: length)) }
            var combined = channels.first ?? []
            if channelCount > 1 {
                let scale = 1.0 / Float(channelCount)
                for index in 0..<length {
                    var sum: Float = 0.0
                    for channel in channels { sum += channel[index] }
                    combined[index] = sum * scale
                }
            }
            return SampleWindow(startFrame: frames.lowerBound, channels: channels, combined: combined)
        } catch {
            return nil
        }
    }

    public func finePeaks(for channel: Int?) -> [CompactPeak] {
        guard let channel, channel >= 0, channel < fineChannelPeaks.count else {
            return fineCombinedPeaks
        }
        return fineChannelPeaks[channel]
    }

    public func peaks(for channel: Int?) -> [PeakPoint] {
        guard let channel, channel >= 0, channel < channelPeaks.count else {
            return peaks
        }
        return channelPeaks[channel]
    }

    public func appendLivePeak(min: Float, max: Float) {
        let newIndex = peaks.count
        let clampedMin = Swift.max(-1.0, Swift.min(1.0, min))
        let clampedMax = Swift.max(-1.0, Swift.min(1.0, max))
        peaks.append(PeakPoint(id: newIndex, min: clampedMin, max: clampedMax))
    }

    public func appendLivePeaks(_ newPoints: [(min: Float, max: Float)]) {
        var startIdx = peaks.count
        var batch: [PeakPoint] = []
        batch.reserveCapacity(newPoints.count)
        for pt in newPoints {
            let clampedMin = Swift.max(-1.0, Swift.min(1.0, pt.min))
            let clampedMax = Swift.max(-1.0, Swift.min(1.0, pt.max))
            batch.append(PeakPoint(id: startIdx, min: clampedMin, max: clampedMax))
            startIdx += 1
        }
        peaks.append(contentsOf: batch)
        if channelPeaks.isEmpty {
            channelPeaks = [peaks]
        } else {
            for index in channelPeaks.indices {
                channelPeaks[index].append(contentsOf: batch)
            }
        }
    }

    public func appendLiveChannelPeaks(_ channelPoints: [[(min: Float, max: Float)]]) {
        guard !channelPoints.isEmpty else { return }
        let pointCount = channelPoints.map(\.count).max() ?? 0
        var combinedPoints: [(min: Float, max: Float)] = []
        combinedPoints.reserveCapacity(pointCount)
        for index in 0..<pointCount {
            var minimum: Float = 0.0
            var maximum: Float = 0.0
            for points in channelPoints where index < points.count {
                minimum = min(minimum, points[index].min)
                maximum = max(maximum, points[index].max)
            }
            combinedPoints.append((min: minimum, max: maximum))
        }
        if channelPeaks.count < channelPoints.count {
            channelPeaks.append(contentsOf: Array(
                repeating: [],
                count: channelPoints.count - channelPeaks.count
            ))
        }
        let startIndex = peaks.count
        peaks.append(contentsOf: combinedPoints.enumerated().map { offset, point in
            PeakPoint(
                id: startIndex + offset,
                min: Swift.max(-1.0, Swift.min(1.0, point.min)),
                max: Swift.max(-1.0, Swift.min(1.0, point.max))
            )
        })
        for channel in channelPoints.indices {
            for (offset, point) in channelPoints[channel].enumerated() {
                channelPeaks[channel].append(PeakPoint(
                    id: startIndex + offset,
                    min: Swift.max(-1.0, Swift.min(1.0, point.min)),
                    max: Swift.max(-1.0, Swift.min(1.0, point.max))
                ))
            }
        }
    }

    /// Peaks of one file, shared by every clip that plays it: the pieces of
    /// a split clip all point at the same file, and reading it once per
    /// clip cost time, memory and open files.
    private struct LoadedPeaks {
        let peaks: [PeakPoint]
        let channelPeaks: [[PeakPoint]]
        let fineChannelPeaks: [[CompactPeak]]
        let fineCombinedPeaks: [CompactPeak]
        let duration: Double
    }

    private struct WeakCache {
        weak var cache: WaveformCache?
    }

    private static var loadedPeaks: [String: LoadedPeaks] = [:]
    private static var waitingCaches: [String: [WeakCache]] = [:]

    /// Identifies a file's contents: a changed file gets a new key.
    private static func peakKey(for url: URL, samplesPerPeak: Int) -> String {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return [
            url.standardizedFileURL.path,
            String(values?.fileSize ?? -1),
            String(values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0),
            String(samplesPerPeak)
        ].joined(separator: "|")
    }

    private func apply(_ loaded: LoadedPeaks) {
        peaks = loaded.peaks
        channelPeaks = loaded.channelPeaks.isEmpty ? [loaded.peaks] : loaded.channelPeaks
        fineChannelPeaks = loaded.fineChannelPeaks
        fineCombinedPeaks = loaded.fineCombinedPeaks
        duration = loaded.duration
        isLoading = false
    }

    public func loadPeaks(from url: URL, sampleRate: Double = 48000.0) {
        resetSampleWindow()
        sampleSourceURL = url
        let key = Self.peakKey(for: url, samplesPerPeak: samplesPerPeak)
        if let loaded = Self.loadedPeaks[key] {
            apply(loaded)
            return
        }
        isLoading = true
        if Self.waitingCaches[key] != nil {
            Self.waitingCaches[key]?.append(WeakCache(cache: self))
            return
        }
        Self.waitingCaches[key] = [WeakCache(cache: self)]
        let targetSamplesPerPeak = self.samplesPerPeak

        Task.detached(priority: .userInitiated) {
            let loaded = Self.computePeaks(from: url, samplesPerPeak: targetSamplesPerPeak)
            await MainActor.run {
                let waiting = Self.waitingCaches.removeValue(forKey: key) ?? []
                if let loaded {
                    Self.loadedPeaks[key] = loaded
                }
                let result = loaded ?? LoadedPeaks(
                    peaks: [], channelPeaks: [], fineChannelPeaks: [], fineCombinedPeaks: [], duration: 0.0
                )
                for entry in waiting {
                    entry.cache?.apply(result)
                }
            }
        }
    }

    /// Reads the whole file once; nil when it cannot be read. Both levels
    /// come from the same pass: each coarse peak is the extremes of the
    /// fine peaks it covers.
    private nonisolated static func computePeaks(from url: URL, samplesPerPeak targetSamplesPerPeak: Int) -> LoadedPeaks? {
        let fineSize = fineSamplesPerPeak
        let finePerCoarse = max(1, targetSamplesPerPeak / fineSize)
        var calculatedPeaks: [PeakPoint] = []
        var calculatedChannelPeaks: [[PeakPoint]] = []
        var fineChannels: [[CompactPeak]] = []
        var fineCombined: [CompactPeak] = []
        var fileDuration: Double = 0.0

        do {
            let file = try AVAudioFile(forReading: url)
            let length = file.length
            let format = file.processingFormat
            let sampleRate = file.fileFormat.sampleRate
            fileDuration = sampleRate > 0.0 ? Double(length) / sampleRate : 0.0
            let channelCount = Int(format.channelCount)
            guard channelCount > 0 else { return nil }

            let expectedFine = Int(length / Int64(fineSize)) + 1
            fineChannels = Array(repeating: [], count: channelCount)
            for ch in 0..<channelCount { fineChannels[ch].reserveCapacity(expectedFine) }
            if channelCount > 1 { fineCombined.reserveCapacity(expectedFine) }
            calculatedChannelPeaks = Array(repeating: [], count: channelCount)

            // A whole number of coarse peaks, so they never straddle reads.
            let bufferSize = AVAudioFrameCount(targetSamplesPerPeak * 128)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferSize) else {
                return nil
            }

            // The coarse peak being gathered from fine peaks.
            // True extremes (not anchored at 0): zoomed in, a peak covers
            // part of one cycle and must sit where that part is.
            var coarseMin = [Float](repeating: .infinity, count: channelCount)
            var coarseMax = [Float](repeating: -.infinity, count: channelCount)
            var coarseCombinedMin: Float = .infinity
            var coarseCombinedMax: Float = -.infinity
            var finesInCoarse = 0
            var peakId = 0
            var fineMin = [Float](repeating: 0.0, count: channelCount)
            var fineMax = [Float](repeating: 0.0, count: channelCount)
            let channelScale = 1.0 / Float(channelCount)

            func flushCoarse() {
                guard finesInCoarse > 0 else { return }
                for ch in 0..<channelCount {
                    calculatedChannelPeaks[ch].append(PeakPoint(id: peakId, min: coarseMin[ch], max: coarseMax[ch]))
                    coarseMin[ch] = .infinity
                    coarseMax[ch] = -.infinity
                }
                // The single-lane (mono track) waveform shows the channel
                // average, which is what a mono track plays.
                calculatedPeaks.append(PeakPoint(id: peakId, min: coarseCombinedMin, max: coarseCombinedMax))
                coarseCombinedMin = .infinity
                coarseCombinedMax = -.infinity
                finesInCoarse = 0
                peakId += 1
            }

            while file.framePosition < length {
                let framesToRead = AVAudioFrameCount(min(Int64(bufferSize), length - file.framePosition))
                try file.read(into: buffer, frameCount: framesToRead)

                guard let channelData = buffer.floatChannelData else { break }
                let frameLength = Int(buffer.frameLength)

                var i = 0
                while i < frameLength {
                    let chunkEnd = min(i + fineSize, frameLength)
                    for ch in 0..<channelCount {
                        var minVal: Float = .infinity
                        var maxVal: Float = -.infinity
                        let samples = channelData[ch]
                        for sampleIdx in i..<chunkEnd {
                            let val = samples[sampleIdx]
                            if val < minVal { minVal = val }
                            if val > maxVal { maxVal = val }
                        }
                        fineMin[ch] = minVal
                        fineMax[ch] = maxVal
                        fineChannels[ch].append(CompactPeak(min: minVal, max: maxVal))
                        coarseMin[ch] = min(coarseMin[ch], minVal)
                        coarseMax[ch] = max(coarseMax[ch], maxVal)
                    }

                    var combinedMin: Float = .infinity
                    var combinedMax: Float = -.infinity
                    if channelCount == 1 {
                        combinedMin = fineMin[0]
                        combinedMax = fineMax[0]
                    } else {
                        for sampleIdx in i..<chunkEnd {
                            var sum: Float = 0.0
                            for ch in 0..<channelCount {
                                sum += channelData[ch][sampleIdx]
                            }
                            let val = sum * channelScale
                            if val < combinedMin { combinedMin = val }
                            if val > combinedMax { combinedMax = val }
                        }
                        fineCombined.append(CompactPeak(min: combinedMin, max: combinedMax))
                    }
                    coarseCombinedMin = min(coarseCombinedMin, combinedMin)
                    coarseCombinedMax = max(coarseCombinedMax, combinedMax)

                    finesInCoarse += 1
                    if finesInCoarse == finePerCoarse { flushCoarse() }
                    i = chunkEnd
                }
            }
            flushCoarse()
        } catch {
            print("Failed to load peaks from \(url): \(error)")
            return nil
        }

        return LoadedPeaks(
            peaks: calculatedPeaks,
            channelPeaks: calculatedChannelPeaks,
            fineChannelPeaks: fineChannels,
            // A mono file's average is its only channel (shared storage).
            fineCombinedPeaks: fineChannels.count == 1 ? fineChannels[0] : fineCombined,
            duration: fileDuration
        )
    }

}

