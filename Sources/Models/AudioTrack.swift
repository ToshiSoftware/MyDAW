import Foundation
import SwiftUI
import AVFoundation

public enum ChannelMode: String, CaseIterable, Identifiable, Codable {
    case mono = "Mono"
    case stereo = "Stereo"

    public var id: String { rawValue }
    public var channelCount: AVAudioChannelCount {
        switch self {
        case .mono: return 1
        case .stereo: return 2
        }
    }
}

@MainActor
public final class AudioTrack: Identifiable, ObservableObject {
    public let id: UUID
    @Published public var name: String
    @Published public var channelMode: ChannelMode
    @Published public var inputChannelIndex: Int // 0-indexed hardware channel offset
    @Published public var isRecordArmed: Bool    // Record mode vs Playback mode
    @Published public var isMuted: Bool
    @Published public var isSoloed: Bool
    @Published public var volume: Float         // 0.0 ... 1.5 (1.0 = 0dB)
    @Published public var pan: Float            // -1.0 ... 1.0 (0.0 = Center)
    @Published public var trackHeight: CGFloat
    @Published public var color: Color
    @Published public var audioFileURL: URL?
    @Published public private(set) var clips: [AudioClip] = []
    @Published public var plugins: [TrackPluginDescriptor] = []
    @Published public var fxSends: [FXSend] = []
    @Published public var selectedClipId: UUID?
    @Published public var currentInputPeak: Float = 0.0
    @Published public var currentOutputPeak: Float = 0.0

    public init(
        id: UUID = UUID(),
        name: String,
        channelMode: ChannelMode = .stereo,
        inputChannelIndex: Int = 0,
        isRecordArmed: Bool = false,
        isMuted: Bool = false,
        isSoloed: Bool = false,
        volume: Float = 1.0,
        pan: Float = 0.0,
        trackHeight: CGFloat = 170.0,
        color: Color = Color.cyan,
        audioFileURL: URL? = nil,
        plugins: [TrackPluginDescriptor] = [],
        fxSends: [FXSend] = []
    ) {
        self.id = id
        self.name = name
        self.channelMode = channelMode
        self.inputChannelIndex = inputChannelIndex
        self.isRecordArmed = isRecordArmed
        self.isMuted = isMuted
        self.isSoloed = isSoloed
        self.volume = volume
        self.pan = pan
        self.trackHeight = max(120.0, trackHeight)
        self.color = color
        self.audioFileURL = audioFileURL
        self.plugins = plugins
        self.fxSends = fxSends
        self.selectedClipId = nil
        if let audioFileURL {
            let clip = AudioClip(startTime: 0.0, fileURL: audioFileURL)
            self.clips = [clip]
            clip.loadMetadata()
        }
    }

    public var isRecordingMode: Bool {
        return isRecordArmed
    }

    public func addClip(startTime: Double, fileURL: URL) -> AudioClip {
        let clip = AudioClip(startTime: startTime, fileURL: fileURL)
        clips.append(clip)
        audioFileURL = fileURL
        return clip
    }

    public func appendLivePeaks(_ points: [(min: Float, max: Float)]) {
        clips.last?.appendLivePeaks(points)
    }

    public func appendLiveChannelPeaks(_ channelPoints: [[(min: Float, max: Float)]]) {
        clips.last?.appendLiveChannelPeaks(channelPoints)
    }

    public func moveClip(id: UUID, to startTime: Double) {
        clips.first(where: { $0.id == id })?.startTime = max(0.0, startTime)
    }

    @discardableResult
    public func removeClipForTransfer(id: UUID) -> AudioClip? {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return nil }
        let clip = clips.remove(at: index)
        selectedClipId = nil
        audioFileURL = clips.last?.fileURL
        return clip
    }

    public func deleteClip(id: UUID, removeFile: Bool = true) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        let clip = clips.remove(at: index)
        let fileIsStillReferenced = clips.contains { $0.fileURL == clip.fileURL }
        if removeFile && !fileIsStillReferenced {
            try? FileManager.default.removeItem(at: clip.fileURL)
        }
        selectedClipId = nil
        audioFileURL = clips.last?.fileURL
    }

    public func duplicateClip(id: UUID) -> AudioClip? {
        guard let source = clips.first(where: { $0.id == id }) else { return nil }
        let copy = source.duplicate(at: source.startTime + source.duration)
        clips.append(copy)
        selectedClipId = copy.id
        return copy
    }

    public func splitClip(id: UUID, at timelineTime: Double) -> Bool {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return false }
        let source = clips[index]
        let splitOffset = timelineTime - source.startTime
        guard splitOffset > 0.02, splitOffset < source.duration - 0.02 else { return false }
        let originalFadeOutDuration = source.fadeOutDuration

        let rightClip = AudioClip(
            startTime: timelineTime,
            fileURL: source.fileURL
        )
        rightClip.loadMetadata()
        rightClip.setTrim(
            startTime: timelineTime,
            sourceStartTime: source.sourceStartTime + splitOffset,
            duration: source.duration - splitOffset
        )
        rightClip.setGainDB(source.gainDB)
        rightClip.setFadeOutDuration(originalFadeOutDuration)
        source.setTrim(
            startTime: source.startTime,
            sourceStartTime: source.sourceStartTime,
            duration: splitOffset
        )
        source.setFadeOutDuration(0.0)
        clips.insert(rightClip, at: index + 1)
        selectedClipId = rightClip.id
        return true
    }

    public func insertPlugin(_ descriptor: TrackPluginDescriptor) {
        if plugins.contains(where: { $0.id == descriptor.id }) {
            if let index = plugins.firstIndex(where: { $0.id == descriptor.id }) {
                plugins[index].enabled = true
            }
            return
        }
        plugins.append(descriptor)
    }

    public func removePlugin(id: UUID) {
        plugins.removeAll { $0.id == id }
    }

    public func movePlugin(id: UUID, before targetID: UUID) {
        guard id != targetID,
              let sourceIndex = plugins.firstIndex(where: { $0.id == id }),
              let targetIndex = plugins.firstIndex(where: { $0.id == targetID }) else { return }
        let plugin = plugins.remove(at: sourceIndex)
        let adjustedTargetIndex = targetIndex > sourceIndex ? targetIndex - 1 : targetIndex
        plugins.insert(plugin, at: adjustedTargetIndex)
    }

    public func restoreClip(_ clip: AudioClip) {
        clips.append(clip)
    }

    public func replaceClips(_ restoredClips: [AudioClip]) {
        clips = restoredClips
        audioFileURL = clips.last?.fileURL
        selectedClipId = clips.contains { $0.id == selectedClipId } ? selectedClipId : nil
    }
}

