import Foundation
import SwiftUI
import AppKit

public struct PluginStateDocument: Codable, Hashable {
    public let pluginID: UUID
    public let stateData: Data
    public let format: String

    public init(pluginID: UUID, stateData: Data, format: String = "binary-plist") {
        self.pluginID = pluginID
        self.stateData = stateData
        self.format = format
    }
}

public struct ProjectDocument: Codable {
    public let version: Int
    public let pixelsPerSecond: Double
    public let selectedTrackId: UUID?
    public let currentTime: Double
    public let timelineScrollTime: Double
    public let showsBeats: Bool
    public let bpm: Double
    public let metronomeEnabled: Bool
    public let metronomeTimingOffsetMs: Double
    public let metronomeVolume: Double
    public let masterVolume: Float
    public let manualRecordingCompensationMs: Double
    public let waveformVerticalScale: Double
    public let trackHeightScale: Double
    public let tracks: [TrackDocument]
    public let fxChannels: [FXChannelDocument]
    public let masterPlugins: [TrackPluginDescriptor]
    public let pluginStates: [PluginStateDocument]

    private enum CodingKeys: String, CodingKey {
        case version, pixelsPerSecond, selectedTrackId, currentTime, timelineScrollTime
        case showsBeats, bpm, metronomeEnabled, metronomeTimingOffsetMs, metronomeVolume, masterVolume, manualRecordingCompensationMs, waveformVerticalScale, trackHeightScale, tracks, fxChannels, masterPlugins, pluginStates
    }

    public init(
        pixelsPerSecond: Double,
        selectedTrackId: UUID?,
        currentTime: Double,
        timelineScrollTime: Double,
        showsBeats: Bool,
        bpm: Double,
        metronomeEnabled: Bool,
        metronomeTimingOffsetMs: Double,
        metronomeVolume: Double,
        masterVolume: Float,
        manualRecordingCompensationMs: Double,
        waveformVerticalScale: Double,
        trackHeightScale: Double = 1.0,
        tracks: [TrackDocument],
        fxChannels: [FXChannelDocument] = [],
        masterPlugins: [TrackPluginDescriptor] = [],
        pluginStates: [PluginStateDocument] = []
    ) {
        self.version = 4
        self.pixelsPerSecond = pixelsPerSecond
        self.selectedTrackId = selectedTrackId
        self.currentTime = currentTime
        self.timelineScrollTime = timelineScrollTime
        self.showsBeats = showsBeats
        self.bpm = bpm
        self.metronomeEnabled = metronomeEnabled
        self.metronomeTimingOffsetMs = metronomeTimingOffsetMs
        self.metronomeVolume = metronomeVolume
        self.masterVolume = masterVolume
        self.manualRecordingCompensationMs = manualRecordingCompensationMs
        self.waveformVerticalScale = waveformVerticalScale
        self.trackHeightScale = trackHeightScale
        self.tracks = tracks
        self.fxChannels = fxChannels
        self.masterPlugins = masterPlugins
        self.pluginStates = pluginStates
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        pixelsPerSecond = try values.decodeIfPresent(Double.self, forKey: .pixelsPerSecond) ?? 80.0
        selectedTrackId = try values.decodeIfPresent(UUID.self, forKey: .selectedTrackId)
        currentTime = try values.decodeIfPresent(Double.self, forKey: .currentTime) ?? 0.0
        timelineScrollTime = try values.decodeIfPresent(Double.self, forKey: .timelineScrollTime) ?? 0.0
        showsBeats = try values.decodeIfPresent(Bool.self, forKey: .showsBeats) ?? true
        bpm = try values.decodeIfPresent(Double.self, forKey: .bpm) ?? 120.0
        metronomeEnabled = try values.decodeIfPresent(Bool.self, forKey: .metronomeEnabled) ?? false
        metronomeTimingOffsetMs = try values.decodeIfPresent(Double.self, forKey: .metronomeTimingOffsetMs) ?? 0.0
        metronomeVolume = try values.decodeIfPresent(Double.self, forKey: .metronomeVolume) ?? 1.0
        masterVolume = try values.decodeIfPresent(Float.self, forKey: .masterVolume) ?? 1.0
        manualRecordingCompensationMs = try values.decodeIfPresent(Double.self, forKey: .manualRecordingCompensationMs) ?? 0.0
        waveformVerticalScale = try values.decodeIfPresent(Double.self, forKey: .waveformVerticalScale) ?? 1.0
        trackHeightScale = try values.decodeIfPresent(Double.self, forKey: .trackHeightScale) ?? 1.0
        tracks = try values.decodeIfPresent([TrackDocument].self, forKey: .tracks) ?? []
        fxChannels = try values.decodeIfPresent([FXChannelDocument].self, forKey: .fxChannels) ?? []
        masterPlugins = try values.decodeIfPresent([TrackPluginDescriptor].self, forKey: .masterPlugins) ?? []
        pluginStates = try values.decodeIfPresent([PluginStateDocument].self, forKey: .pluginStates) ?? []
    }
}

public struct TrackDocument: Codable {
    public let id: UUID
    public let name: String
    public let channelMode: ChannelMode
    public let inputChannelIndex: Int
    public let isRecordArmed: Bool
    public let isMuted: Bool
    public let isSoloed: Bool
    public let volume: Float
    public let pan: Float
    public let trackHeight: Double
    public let color: ColorDocument
    public let selectedClipId: UUID?
    public let clips: [ClipDocument]
    public let plugins: [TrackPluginDescriptor]
    public let fxSends: [FXSend]

    private enum CodingKeys: String, CodingKey {
        case id, name, channelMode, inputChannelIndex, isRecordArmed, isMuted, isSoloed
        case volume, pan, trackHeight, color, selectedClipId, clips, plugins, fxSends
    }

    public init(
        id: UUID,
        name: String,
        channelMode: ChannelMode,
        inputChannelIndex: Int,
        isRecordArmed: Bool,
        isMuted: Bool,
        isSoloed: Bool,
        volume: Float,
        pan: Float,
        trackHeight: Double = 170.0,
        color: ColorDocument,
        selectedClipId: UUID?,
        clips: [ClipDocument],
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
        self.trackHeight = trackHeight
        self.color = color
        self.selectedClipId = selectedClipId
        self.clips = clips
        self.plugins = plugins
        self.fxSends = fxSends
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        channelMode = try values.decodeIfPresent(ChannelMode.self, forKey: .channelMode) ?? .stereo
        inputChannelIndex = try values.decodeIfPresent(Int.self, forKey: .inputChannelIndex) ?? 0
        isRecordArmed = try values.decodeIfPresent(Bool.self, forKey: .isRecordArmed) ?? false
        isMuted = try values.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isSoloed = try values.decodeIfPresent(Bool.self, forKey: .isSoloed) ?? false
        volume = try values.decodeIfPresent(Float.self, forKey: .volume) ?? 1.0
        pan = try values.decodeIfPresent(Float.self, forKey: .pan) ?? 0.0
        trackHeight = try values.decodeIfPresent(Double.self, forKey: .trackHeight) ?? 170.0
        color = try values.decode(ColorDocument.self, forKey: .color)
        selectedClipId = try values.decodeIfPresent(UUID.self, forKey: .selectedClipId)
        clips = try values.decodeIfPresent([ClipDocument].self, forKey: .clips) ?? []
        plugins = try values.decodeIfPresent([TrackPluginDescriptor].self, forKey: .plugins) ?? []
        fxSends = try values.decodeIfPresent([FXSend].self, forKey: .fxSends) ?? []
    }
}

public struct FXChannelDocument: Codable {
    public let id: UUID
    public let name: String
    public let volume: Float
    public let pan: Float
    public let color: ColorDocument
    public let plugins: [TrackPluginDescriptor]

    @MainActor
    public init(channel: FXChannel) {
        id = channel.id
        name = channel.name
        volume = channel.volume
        pan = channel.pan
        color = ColorDocument(color: channel.color)
        plugins = channel.plugins
    }
}

public struct ClipDocument: Codable {
    public let id: UUID
    public let startTime: Double
    public let sourceStartTime: Double
    public let duration: Double
    public let originalDuration: Double
    public let gainDB: Double
    public let fadeInDuration: Double
    public let fadeOutDuration: Double
    public let filePath: String

    private enum CodingKeys: String, CodingKey {
        case id, startTime, sourceStartTime, duration, originalDuration, gainDB, fadeInDuration, fadeOutDuration, filePath
    }

    public init(
        id: UUID,
        startTime: Double,
        sourceStartTime: Double,
        duration: Double,
        originalDuration: Double,
        gainDB: Double = 0.0,
        fadeInDuration: Double = 0.0,
        fadeOutDuration: Double = 0.0,
        filePath: String
    ) {
        self.id = id
        self.startTime = startTime
        self.sourceStartTime = sourceStartTime
        self.duration = duration
        self.originalDuration = originalDuration
        self.gainDB = min(24.0, max(-24.0, gainDB))
        self.fadeInDuration = max(0.0, fadeInDuration)
        self.fadeOutDuration = max(0.0, fadeOutDuration)
        self.filePath = filePath
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        startTime = try values.decode(Double.self, forKey: .startTime)
        sourceStartTime = try values.decodeIfPresent(Double.self, forKey: .sourceStartTime) ?? 0.0
        duration = try values.decode(Double.self, forKey: .duration)
        originalDuration = try values.decodeIfPresent(Double.self, forKey: .originalDuration) ?? duration
        gainDB = min(24.0, max(-24.0, try values.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0.0))
        fadeInDuration = max(0.0, try values.decodeIfPresent(Double.self, forKey: .fadeInDuration) ?? 0.0)
        fadeOutDuration = max(0.0, try values.decodeIfPresent(Double.self, forKey: .fadeOutDuration) ?? 0.0)
        filePath = try values.decode(String.self, forKey: .filePath)
    }
}

public struct ColorDocument: Codable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let opacity: Double

    public init(color: Color) {
        let resolved = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor.white
        var red: CGFloat = 1
        var green: CGFloat = 1
        var blue: CGFloat = 1
        var opacity: CGFloat = 1
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &opacity)
        self.red = Double(red)
        self.green = Double(green)
        self.blue = Double(blue)
        self.opacity = Double(opacity)
    }

    public var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}
