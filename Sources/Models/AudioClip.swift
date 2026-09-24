import Foundation
import AVFoundation
import SwiftUI

@MainActor
public final class AudioClip: Identifiable, ObservableObject {
    public let id: UUID
    @Published public var startTime: Double
    @Published public var sourceStartTime: Double
    @Published public var gainDB: Double
    @Published public private(set) var fadeInDuration: Double
    @Published public private(set) var fadeOutDuration: Double
    @Published public private(set) var sampleRate: Double = 48000.0
    @Published public private(set) var fileURL: URL
    @Published public private(set) var duration: Double
    public private(set) var originalDuration: Double = 0.0
    public let waveformCache: WaveformCache

    public init(id: UUID = UUID(), startTime: Double, fileURL: URL) {
        self.id = id
        self.startTime = max(0.0, startTime)
        self.sourceStartTime = 0.0
        self.gainDB = 0.0
        self.fadeInDuration = 0.0
        self.fadeOutDuration = 0.0
        self.fileURL = fileURL
        self.duration = 0.0
        self.waveformCache = WaveformCache()
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

    public func setGainDB(_ value: Double) {
        gainDB = min(24.0, max(-24.0, value.isFinite ? value : 0.0))
    }

    public func setFadeInDuration(_ value: Double) {
        fadeInDuration = min(max(0.0, value.isFinite ? value : 0.0), duration)
    }

    public func setFadeOutDuration(_ value: Double) {
        fadeOutDuration = min(max(0.0, value.isFinite ? value : 0.0), duration)
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
        copy.setFadeInDuration(fadeInDuration)
        copy.setFadeOutDuration(fadeOutDuration)
        return copy
    }
}