import Foundation
import AVFoundation
import SwiftUI

@MainActor
public final class AudioClip: Identifiable, ObservableObject {
    public let id: UUID
    @Published public var startTime: Double
    @Published public var sourceStartTime: Double
    public let fileURL: URL
    @Published public private(set) var duration: Double
    public private(set) var originalDuration: Double = 0.0
    public let waveformCache: WaveformCache

    public init(id: UUID = UUID(), startTime: Double, fileURL: URL) {
        self.id = id
        self.startTime = max(0.0, startTime)
        self.sourceStartTime = 0.0
        self.fileURL = fileURL
        self.duration = 0.0
        self.waveformCache = WaveformCache()
    }

    public func loadMetadata() {
        do {
            let file = try AVAudioFile(forReading: fileURL)
            let sampleRate = file.fileFormat.sampleRate
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

    public func appendLivePeaks(_ points: [(min: Float, max: Float)]) {
        waveformCache.appendLivePeaks(points)
    }

    public func setTrim(startTime: Double, sourceStartTime: Double, duration: Double) {
        self.startTime = max(0.0, startTime)
        self.sourceStartTime = max(0.0, sourceStartTime)
        self.duration = max(0.02, duration)
    }

    public func duplicate(at newStartTime: Double) -> AudioClip {
        let copy = AudioClip(startTime: newStartTime, fileURL: fileURL)
        copy.loadMetadata()
        copy.setTrim(
            startTime: newStartTime,
            sourceStartTime: sourceStartTime,
            duration: duration
        )
        return copy
    }
}