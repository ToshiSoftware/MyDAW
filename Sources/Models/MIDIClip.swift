import Foundation
import Combine

/// MIDI positions are whole ticks of a beat, so notes stay on the bar grid
/// when the tempo changes (audio clips are kept in seconds).
public enum MIDITiming {
    public static let ticksPerBeat = 960
    /// Far past any song (hundreds of years at 120 BPM), and
    /// small enough that adding positions and lengths cannot overflow, which
    /// would end the app.
    public static let maximumTicks = 1 << 45

    /// A position or length from a file, within what arithmetic can take.
    static func clamped(_ ticks: Int) -> Int {
        max(-maximumTicks, min(maximumTicks, ticks))
    }

    public static func seconds(ticks: Int, bpm: Double) -> Double {
        Double(ticks) / Double(ticksPerBeat) * 60.0 / max(20.0, min(400.0, bpm))
    }

    public static func ticks(seconds: Double, bpm: Double) -> Int {
        clamped(Int(Int64(saturating: (seconds * max(20.0, min(400.0, bpm)) / 60.0 * Double(ticksPerBeat)).rounded())))
    }
}

/// The project's time signature, one for the whole timeline. The tempo stays
/// in quarter notes whatever the meter, so changing it moves nothing: only
/// the bars, the beats and the clicks fall elsewhere.
public struct MusicalMeter: Hashable, Sendable, Codable {
    public var beatsPerBar: Int
    /// Note value of one beat (4: quarter, 8: eighth).
    public var beatUnit: Int

    public static let common = MusicalMeter(beatsPerBar: 4, beatUnit: 4)
    /// What the transport bar offers.
    public static let selectableBeatsPerBar = Array(1...16)
    public static let selectableBeatUnits = [4, 8]

    public init(beatsPerBar: Int, beatUnit: Int) {
        self.beatsPerBar = max(1, beatsPerBar)
        self.beatUnit = max(1, beatUnit)
    }

    /// Ticks in one beat of this meter (an eighth-note beat is half a
    /// quarter-note tick count).
    public var ticksPerBeat: Int { MIDITiming.ticksPerBeat * 4 / beatUnit }
    public var ticksPerBar: Int { ticksPerBeat * beatsPerBar }
    public var quarterNotesPerBar: Double { Double(beatsPerBar) * 4.0 / Double(beatUnit) }
    public var isSelectable: Bool {
        Self.selectableBeatsPerBar.contains(beatsPerBar) && Self.selectableBeatUnits.contains(beatUnit)
    }
    public var text: String { "\(beatsPerBar)/\(beatUnit)" }

    public func secondsPerBeat(bpm: Double) -> Double {
        60.0 / max(20.0, min(400.0, bpm)) * 4.0 / Double(beatUnit)
    }

    public func secondsPerBar(bpm: Double) -> Double {
        secondsPerBeat(bpm: bpm) * Double(beatsPerBar)
    }

    /// Zero-based bar, beat in the bar, and tick in the beat of `tick`.
    public func position(ofTick tick: Int) -> (bar: Int, beat: Int, tick: Int) {
        let tick = max(0, tick)
        return (tick / ticksPerBar, tick % ticksPerBar / ticksPerBeat, tick % ticksPerBeat)
    }
}

/// One note, its start counted from the clip's content origin.
/// Saved as [startTick, lengthTicks, pitch, velocity, channel, muted] to keep
/// projects with thousands of notes small.
public struct MIDINote: Hashable, Sendable, Codable {
    public var startTick: Int
    public var lengthTicks: Int
    public var pitch: UInt8
    public var velocity: UInt8
    /// 0 ... 15 (shown as 1 ... 16).
    public var channel: UInt8
    public var isMuted: Bool

    public var endTick: Int { startTick + lengthTicks }

    /// Removing overlaps among `notes`: each note overlapping the next note
    /// of the same pitch and channel ends where that one starts. Of two
    /// starting together the shorter is dropped (it would have no length).
    /// Returns new lengths and dropped notes, by index into `notes`.
    public static func overlapFixes(_ notes: [MIDINote]) -> (lengths: [Int: Int], removed: Set<Int>) {
        var lengths: [Int: Int] = [:]
        var removed: Set<Int> = []
        let byKey = Dictionary(grouping: notes.indices) { Int(notes[$0].channel) << 7 | Int(notes[$0].pitch) }
        for indices in byKey.values {
            // Earlier first; of two starting together, the longer first.
            let order = indices.sorted {
                (notes[$0].startTick, -notes[$0].lengthTicks) < (notes[$1].startTick, -notes[$1].lengthTicks)
            }
            var kept: Int?
            for index in order {
                guard let previous = kept else {
                    kept = index
                    continue
                }
                if notes[index].startTick == notes[previous].startTick {
                    removed.insert(index)
                    continue
                }
                let previousEnd = notes[previous].startTick + (lengths[previous] ?? notes[previous].lengthTicks)
                if previousEnd > notes[index].startTick {
                    lengths[previous] = notes[index].startTick - notes[previous].startTick
                }
                kept = index
            }
        }
        return (lengths, removed)
    }

    public init(startTick: Int, lengthTicks: Int, pitch: UInt8, velocity: UInt8, channel: UInt8 = 0, isMuted: Bool = false) {
        self.startTick = MIDITiming.clamped(max(0, startTick))
        self.lengthTicks = MIDITiming.clamped(max(1, lengthTicks))
        self.pitch = min(127, pitch)
        self.velocity = max(1, min(127, velocity))
        self.channel = min(15, channel)
        self.isMuted = isMuted
    }

    public init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        let startTick = try values.decode(Int.self)
        let lengthTicks = try values.decode(Int.self)
        let pitch = try values.decode(Int.self)
        let velocity = try values.decode(Int.self)
        let channel = values.isAtEnd ? 0 : try values.decode(Int.self)
        let muted = values.isAtEnd ? 0 : try values.decode(Int.self)
        self.init(
            startTick: startTick,
            lengthTicks: lengthTicks,
            pitch: UInt8(clamping: pitch),
            velocity: UInt8(clamping: velocity),
            channel: UInt8(clamping: channel),
            isMuted: muted != 0
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode(startTick)
        try values.encode(lengthTicks)
        try values.encode(Int(pitch))
        try values.encode(Int(velocity))
        try values.encode(Int(channel))
        try values.encode(isMuted ? 1 : 0)
    }
}

/// A channel message other than a note (control change, pitch bend, program
/// change, pressure), kept as its raw bytes so every kind plays back even
/// before it can be edited. Saved as [tick, status, data1, data2].
public struct MIDIChannelEvent: Hashable, Sendable, Codable {
    public var tick: Int
    /// Status byte including the channel (0x80 ... 0xEF, notes excluded).
    public var status: UInt8
    public var data1: UInt8
    public var data2: UInt8

    public var channel: UInt8 { status & 0x0F }
    public var kind: UInt8 { status & 0xF0 }
    /// Program change and channel pressure carry one data byte.
    public var byteCount: Int { kind == 0xC0 || kind == 0xD0 ? 2 : 3 }

    public init(tick: Int, status: UInt8, data1: UInt8, data2: UInt8 = 0) {
        self.tick = MIDITiming.clamped(max(0, tick))
        self.status = status
        self.data1 = data1 & 0x7F
        self.data2 = data2 & 0x7F
    }

    public init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        let tick = try values.decode(Int.self)
        let status = try values.decode(Int.self)
        let data1 = try values.decode(Int.self)
        let data2 = values.isAtEnd ? 0 : try values.decode(Int.self)
        self.init(tick: tick, status: UInt8(clamping: status), data1: UInt8(clamping: data1), data2: UInt8(clamping: data2))
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.unkeyedContainer()
        try values.encode(tick)
        try values.encode(Int(status))
        try values.encode(Int(data1))
        try values.encode(Int(data2))
    }
}

/// A MIDI clip on an instrument track. Notes and events are in content
/// ticks; the clip shows the content from `contentOffsetTicks` for
/// `lengthTicks`, so trimming and splitting keep the notes where they are.
@MainActor
public final class MIDIClip: Identifiable, ObservableObject {
    public let id: UUID
    /// Position of the clip's left edge on the timeline.
    @Published public var startTick: Int
    @Published public var lengthTicks: Int
    /// Content tick at the clip's left edge.
    @Published public var contentOffsetTicks: Int
    @Published public var isMuted: Bool
    @Published public var notes: [MIDINote]
    @Published public var events: [MIDIChannelEvent]

    public var endTick: Int { startTick + lengthTicks }

    public init(
        id: UUID = UUID(),
        startTick: Int,
        lengthTicks: Int,
        contentOffsetTicks: Int = 0,
        isMuted: Bool = false,
        notes: [MIDINote] = [],
        events: [MIDIChannelEvent] = []
    ) {
        self.id = id
        self.startTick = MIDITiming.clamped(max(0, startTick))
        self.lengthTicks = MIDITiming.clamped(max(1, lengthTicks))
        // Negative when the clip's start was trimmed out before its first
        // content (an empty lead-in).
        self.contentOffsetTicks = MIDITiming.clamped(contentOffsetTicks)
        self.isMuted = isMuted
        self.notes = notes
        self.events = events
    }

    /// Timeline tick of a content tick.
    public func timelineTick(ofContentTick tick: Int) -> Int {
        startTick + tick - contentOffsetTicks
    }

    /// Notes that start inside the visible part of the clip.
    public var audibleNotes: [MIDINote] {
        let range = contentOffsetTicks..<(contentOffsetTicks + lengthTicks)
        return notes.filter { range.contains($0.startTick) }
    }

    public func duplicate(at startTick: Int) -> MIDIClip {
        MIDIClip(
            startTick: startTick,
            lengthTicks: lengthTicks,
            contentOffsetTicks: contentOffsetTicks,
            isMuted: isMuted,
            notes: notes,
            events: events
        )
    }
}

public struct MIDIClipDocument: Codable {
    public let id: UUID
    public let startTick: Int
    public let lengthTicks: Int
    public let contentOffsetTicks: Int
    public let isMuted: Bool
    public let notes: [MIDINote]
    public let events: [MIDIChannelEvent]

    private enum CodingKeys: String, CodingKey {
        case id, startTick, lengthTicks, contentOffsetTicks, isMuted, notes, events
    }

    @MainActor
    public init(clip: MIDIClip) {
        id = clip.id
        startTick = clip.startTick
        lengthTicks = clip.lengthTicks
        contentOffsetTicks = clip.contentOffsetTicks
        isMuted = clip.isMuted
        notes = clip.notes
        events = clip.events
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        startTick = try values.decode(Int.self, forKey: .startTick)
        lengthTicks = try values.decode(Int.self, forKey: .lengthTicks)
        contentOffsetTicks = try values.decodeIfPresent(Int.self, forKey: .contentOffsetTicks) ?? 0
        isMuted = try values.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        notes = try values.decodeIfPresent([MIDINote].self, forKey: .notes) ?? []
        events = try values.decodeIfPresent([MIDIChannelEvent].self, forKey: .events) ?? []
    }

    @MainActor
    public func makeClip() -> MIDIClip {
        MIDIClip(
            id: id,
            startTick: startTick,
            lengthTicks: lengthTicks,
            contentOffsetTicks: contentOffsetTicks,
            isMuted: isMuted,
            notes: notes,
            events: events
        )
    }
}
