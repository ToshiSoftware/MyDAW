import Foundation
import AVFoundation
import Combine
import SwiftUI

@MainActor
public final class AudioClip: Identifiable, ObservableObject {
    public let id: UUID
    @Published public var startTime: Double
    @Published public var sourceStartTime: Double
    @Published public var gainDB: Double
    @Published public var isMuted: Bool
    @Published public private(set) var fadeInDuration: Double
    @Published public private(set) var fadeOutDuration: Double
    @Published public var fadeInCurve: FadeCurve = .auto
    @Published public var fadeOutCurve: FadeCurve = .auto
    @Published public private(set) var sampleRate: Double = 48000.0
    @Published public private(set) var fileURL: URL
    @Published public private(set) var duration: Double
    public private(set) var originalDuration: Double = 0.0
    public let waveformCache: WaveformCache
    /// Whether the waveform has peaks to draw. Views observe the clip, not
    /// its cache, so without this a clip whose peaks finish loading after it
    /// is added (a dropped file) stayed blank until something else redrew it.
    @Published public private(set) var hasWaveform = false
    private var hasWaveformSubscription: AnyCancellable?

    public init(id: UUID = UUID(), startTime: Double, fileURL: URL) {
        self.id = id
        self.startTime = max(0.0, startTime)
        self.sourceStartTime = 0.0
        self.gainDB = 0.0
        self.isMuted = false
        self.fadeInDuration = 0.0
        self.fadeOutDuration = 0.0
        self.fileURL = fileURL
        self.duration = 0.0
        self.waveformCache = WaveformCache()
        hasWaveformSubscription = waveformCache.$peaks
            .map { !$0.isEmpty }
            .removeDuplicates()
            .sink { [weak self] hasPeaks in self?.hasWaveform = hasPeaks }
    }

    public func loadMetadata() {
        do {
            let file = try AVAudioFile(forReading: fileURL)
            let sampleRate = file.fileFormat.sampleRate
            self.sampleRate = sampleRate > 0.0 ? sampleRate : 48000.0
            originalDuration = sampleRate > 0.0 ? Double(file.length) / sampleRate : 0.0
            if duration <= 0.0 {
                duration = originalDuration
            } else {
                let availableDuration = max(0.0, originalDuration - sourceStartTime)
                duration = min(duration, availableDuration)
            }
            waveformCache.loadPeaks(from: fileURL)
        } catch {
            print("Failed to load audio clip \(fileURL.lastPathComponent): \(error)")
        }
    }

    public var isFileMissing: Bool {
        !FileManager.default.fileExists(atPath: fileURL.path)
    }

    public func replaceFile(with url: URL) {
        fileURL = url
        waveformCache.clear()
        loadMetadata()
    }

    public func appendLivePeaks(_ points: [(min: Float, max: Float)]) {
        waveformCache.appendLivePeaks(points)
    }

    public func appendLiveChannelPeaks(_ channelPoints: [[(min: Float, max: Float)]]) {
        waveformCache.appendLiveChannelPeaks(channelPoints)
    }

    public func setTrim(startTime: Double, sourceStartTime: Double, duration: Double) {
        self.startTime = max(0.0, startTime)
        self.sourceStartTime = max(0.0, sourceStartTime)
        self.duration = max(0.02, duration)
    }

    /// Highest clip gain.
    public nonisolated static let maximumGainDB = 36.0
    /// Gains at or below this become -∞ (silence).
    public nonisolated static let silenceGainDB = -72.0

    /// Sets the gain, -∞ (silent) ... +36 dB.
    public func setGainDB(_ value: Double) {
        if value.isNaN {
            gainDB = 0.0
        } else {
            gainDB = value <= Self.silenceGainDB ? -.infinity : min(Self.maximumGainDB, value)
        }
    }

    public func setFadeInDuration(_ value: Double) {
        fadeInDuration = min(max(0.0, value.isFinite ? value : 0.0), duration)
    }

    public func setFadeOutDuration(_ value: Double) {
        fadeOutDuration = min(max(0.0, value.isFinite ? value : 0.0), duration)
    }

    /// A new clip holding the part of this clip between two timeline times, or
    /// nil when that part is shorter than 20 ms. Fades are kept only on the
    /// edges the piece shares with this clip.
    public func piece(from timelineStart: Double, to timelineEnd: Double) -> AudioClip? {
        let clipEnd = startTime + duration
        let start = max(startTime, timelineStart)
        let end = min(clipEnd, timelineEnd)
        guard end - start >= 0.02 else { return nil }
        let copy = AudioClip(startTime: start, fileURL: fileURL)
        copy.loadMetadata()
        copy.setTrim(
            startTime: start,
            sourceStartTime: sourceStartTime + (start - startTime),
            duration: end - start
        )
        copy.gainDB = gainDB
        copy.isMuted = isMuted
        if start == startTime {
            copy.setFadeInDuration(fadeInDuration)
            copy.fadeInCurve = fadeInCurve
        }
        if end == clipEnd {
            copy.setFadeOutDuration(fadeOutDuration)
            copy.fadeOutCurve = fadeOutCurve
        }
        return copy
    }

    public func duplicate(at newStartTime: Double) -> AudioClip {
        let copy = AudioClip(startTime: newStartTime, fileURL: fileURL)
        copy.loadMetadata()
        copy.setTrim(
            startTime: newStartTime,
            sourceStartTime: sourceStartTime,
            duration: duration
        )
        copy.gainDB = gainDB
        copy.isMuted = isMuted
        copy.setFadeInDuration(fadeInDuration)
        copy.setFadeOutDuration(fadeOutDuration)
        copy.fadeInCurve = fadeInCurve
        copy.fadeOutCurve = fadeOutCurve
        return copy
    }
}