import Foundation
import SwiftUI
import AVFoundation
import Combine

/// Linear gain limits shared by every mixer fader and send.
public enum MixerGain {
    public static let unity: Float = 1.0
    public static let maximum: Float = Float(pow(10.0, 6.0 / 20.0)) // +6 dB
}

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
    @Published public var isInputMonitoring: Bool // live input through the mixer while armed
    @Published public var volume: Float         // 0.0 ... MixerGain.maximum (1.0 = 0dB)
    @Published public var pan: Float            // -1.0 ... 1.0 (0.0 = Center)
    @Published public var trackHeight: CGFloat
    /// Height of a track nobody has resized.
    /// A plain constant, so default arguments (evaluated outside the main
    /// actor) can use it.
    public nonisolated static let defaultTrackHeight: CGFloat = 170.0
    @Published public var color: Color
    @Published public var audioFileURL: URL?
    @Published public private(set) var clips: [AudioClip] = [] {
        didSet { observeClips() }
    }
    // Overlap display of one clip depends on its neighbours, so any clip's
    // change must re-render the whole lane.
    private var clipObservers: [AnyCancellable] = []
    @Published public var plugins: [TrackPluginDescriptor] = []
    @Published public var fxSends: [FXSend] = []
    @Published public var selectedClipIDs: Set<UUID> = []
    /// Meter levels, kept in their own object so their 30 Hz updates redraw
    /// only the meters and not every view that observes the track.
    public let meter = TrackMeter()
    public var currentInputPeak: Float { meter.inputPeak }
    public var currentOutputPeak: Float { meter.outputPeak.maximum }
    public var outputStereoPeak: StereoPeak { meter.outputPeak }

    public init(
        id: UUID = UUID(),
        name: String,
        channelMode: ChannelMode = .stereo,
        inputChannelIndex: Int = 0,
        isRecordArmed: Bool = false,
        isMuted: Bool = false,
        isSoloed: Bool = false,
        isInputMonitoring: Bool = false,
        volume: Float = 1.0,
        pan: Float = 0.0,
        trackHeight: CGFloat = AudioTrack.defaultTrackHeight,
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
        self.isInputMonitoring = isInputMonitoring
        self.volume = volume
        self.pan = pan
        self.trackHeight = max(1.0, trackHeight)
        self.color = color
        self.audioFileURL = audioFileURL
        self.plugins = plugins
        self.fxSends = fxSends
        if let audioFileURL {
            let clip = AudioClip(startTime: 0.0, fileURL: audioFileURL)
            self.clips = [clip]
            clip.loadMetadata()
        }
        observeClips()
    }

    private func observeClips() {
        clipObservers = clips.map { clip in
            clip.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }

    /// The first selected clip in layer order; setting it selects only that
    /// clip on this track.
    public var selectedClipId: UUID? {
        get { clips.first(where: { selectedClipIDs.contains($0.id) })?.id }
        set { selectedClipIDs = newValue.map { [$0] } ?? [] }
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
        selectedClipIDs.remove(id)
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
        selectedClipIDs.remove(id)
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
        rightClip.fadeOutCurve = source.fadeOutCurve
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

    /// Inserts `clip` directly below the clip with `id` in layer order
    /// (on top of everything when `id` is not found).
    public func insertClip(_ clip: AudioClip, below id: UUID) {
        let index = clips.firstIndex(where: { $0.id == id }) ?? clips.count
        clips.insert(clip, at: index)
    }

    public func replaceClips(_ restoredClips: [AudioClip]) {
        clips = restoredClips
        audioFileURL = clips.last?.fileURL
        selectedClipIDs.formIntersection(clips.map(\.id))
    }

    /// Replaces the clip with `id` by `pieces`, at its place in layer order.
    public func replaceClip(id: UUID, with pieces: [AudioClip]) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        var rebuilt = clips
        rebuilt.replaceSubrange(index...index, with: pieces)
        replaceClips(rebuilt)
    }

    /// Copies of the audio between two timeline times, in layer order.
    public func clipPieces(from start: Double, to end: Double) -> [AudioClip] {
        clips.compactMap { $0.piece(from: start, to: end) }
    }

    /// Removes the audio between two timeline times, cutting clips that
    /// straddle the edges. Returns true when anything changed.
    @discardableResult
    public func removeAudio(from start: Double, to end: Double) -> Bool {
        rebuildClips { clip, clipEnd in
            [clip.piece(from: clip.startTime, to: start), clip.piece(from: end, to: clipEnd)].compactMap { $0 }
        } overlapping: { clip, clipEnd in
            clip.startTime < end && clipEnd > start
        }
    }

    /// Keeps only the audio between two timeline times.
    @discardableResult
    public func cropAudio(from start: Double, to end: Double) -> Bool {
        rebuildClips { clip, _ in
            [clip.piece(from: start, to: end)].compactMap { $0 }
        } overlapping: { clip, clipEnd in
            clip.startTime < start || clipEnd > end
        }
    }

    /// Splits every clip that spans any of `times`.
    @discardableResult
    public func splitAudio(at times: [Double]) -> Bool {
        func cuts(_ clip: AudioClip, _ clipEnd: Double) -> [Double] {
            times.filter { $0 > clip.startTime + 0.02 && $0 < clipEnd - 0.02 }.sorted()
        }
        return rebuildClips { clip, clipEnd in
            let edges = [clip.startTime] + cuts(clip, clipEnd) + [clipEnd]
            return zip(edges, edges.dropFirst()).compactMap { clip.piece(from: $0, to: $1) }
        } overlapping: { clip, clipEnd in
            !cuts(clip, clipEnd).isEmpty
        }
    }

    /// Replaces each clip matching `overlapping` with `pieces` of it, keeping
    /// layer order. Returns true when any clip was replaced.
    private func rebuildClips(
        _ pieces: (AudioClip, Double) -> [AudioClip],
        overlapping: (AudioClip, Double) -> Bool
    ) -> Bool {
        var changed = false
        var rebuilt: [AudioClip] = []
        for clip in clips {
            let clipEnd = clip.startTime + clip.duration
            if overlapping(clip, clipEnd) {
                changed = true
                rebuilt.append(contentsOf: pieces(clip, clipEnd))
            } else {
                rebuilt.append(clip)
            }
        }
        guard changed else { return false }
        replaceClips(rebuilt)
        return true
    }
}

/// A track's input and output meter levels.
@MainActor
public final class TrackMeter: ObservableObject {
    @Published public private(set) var inputPeak: Float = 0.0
    @Published public private(set) var outputPeak: StereoPeak = .zero

    /// Publishes only what changed, so idle meters cause no redraws. Levels
    /// below -100 dB drop to exactly zero.
    public func update(inputPeak newInput: Float, outputPeak newOutput: StereoPeak) {
        let input = newInput < 1e-5 ? 0 : newInput
        if input != inputPeak { inputPeak = input }
        if newOutput != outputPeak { outputPeak = newOutput }
    }
}
