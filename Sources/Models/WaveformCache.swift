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

@MainActor
public final class WaveformCache: ObservableObject {
    @Published public private(set) var peaks: [PeakPoint] = []
    @Published public private(set) var channelPeaks: [[PeakPoint]] = []
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var duration: Double = 0.0

    public let samplesPerPeak: Int

    public init(samplesPerPeak: Int = 512) {
        self.samplesPerPeak = samplesPerPeak
    }

    public func clear() {
        peaks.removeAll(keepingCapacity: true)
        channelPeaks.removeAll(keepingCapacity: true)
        duration = 0.0
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

    public func loadPeaks(from url: URL, sampleRate: Double = 48000.0) {
        isLoading = true
        let targetSamplesPerPeak = self.samplesPerPeak

        Task.detached(priority: .userInitiated) {
            var calculatedPeaks: [PeakPoint] = []
            var calculatedChannelPeaks: [[PeakPoint]] = []
            var fileDuration: Double = 0.0

            do {
                let file = try AVAudioFile(forReading: url)
                let length = file.length
                let format = file.processingFormat
                let sampleRate = file.fileFormat.sampleRate
                fileDuration = sampleRate > 0.0 ? Double(length) / sampleRate : 0.0

                let bufferSize = AVAudioFrameCount(targetSamplesPerPeak * 128)
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferSize) else {
                    return
                }

                var peakId = 0
                while file.framePosition < length {
                    let framesToRead = AVAudioFrameCount(min(Int64(bufferSize), length - file.framePosition))
                    try file.read(into: buffer, frameCount: framesToRead)

                    guard let channelData = buffer.floatChannelData else { break }
                    let channelCount = Int(format.channelCount)
                    if calculatedChannelPeaks.isEmpty {
                        calculatedChannelPeaks = Array(repeating: [], count: channelCount)
                    }
                    let frameLength = Int(buffer.frameLength)

                    var i = 0
                    while i < frameLength {
                        let chunkEnd = min(i + targetSamplesPerPeak, frameLength)
                        var combinedMin: Float = 0.0
                        var combinedMax: Float = 0.0
                        var chunkChannelPeaks: [PeakPoint] = []

                        for ch in 0..<channelCount {
                            var minVal: Float = 0.0
                            var maxVal: Float = 0.0
                            let samples = channelData[ch]
                            for sampleIdx in i..<chunkEnd {
                                let val = samples[sampleIdx]
                                if val < minVal { minVal = val }
                                if val > maxVal { maxVal = val }
                            }
                            chunkChannelPeaks.append(PeakPoint(id: peakId, min: minVal, max: maxVal))
                            combinedMin = min(combinedMin, minVal)
                            combinedMax = max(combinedMax, maxVal)
                        }

                        calculatedPeaks.append(PeakPoint(id: peakId, min: combinedMin, max: combinedMax))
                        for ch in 0..<chunkChannelPeaks.count {
                            calculatedChannelPeaks[ch].append(chunkChannelPeaks[ch])
                        }
                        peakId += 1
                        i = chunkEnd
                    }
                }
            } catch {
                print("Failed to load peaks from \(url): \(error)")
            }

            let finalPeaks = calculatedPeaks
            let finalChannelPeaks = calculatedChannelPeaks
            let finalDuration = fileDuration

            await MainActor.run {
                self.peaks = finalPeaks
                self.channelPeaks = finalChannelPeaks.isEmpty ? [finalPeaks] : finalChannelPeaks
                self.duration = finalDuration
                self.isLoading = false
            }
        }
    }
}

