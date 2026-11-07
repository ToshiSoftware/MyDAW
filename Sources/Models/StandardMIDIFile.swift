import Foundation

/// A Standard MIDI File (format 0 or 1) read into MyDAW's tick resolution.
/// Notes and events keep their absolute positions from the file's start.
struct StandardMIDIFile {
    struct Track {
        var name: String?
        var notes: [MIDINote] = []
        var events: [MIDIChannelEvent] = []

        var isEmpty: Bool { notes.isEmpty && events.isEmpty }
        var firstTick: Int? { (notes.map(\.startTick) + events.map(\.tick)).min() }
        var lastTick: Int? { (notes.map(\.endTick) + events.map(\.tick)).max() }
    }

    enum ReadError: LocalizedError {
        case notMIDI
        case unsupportedTiming
        case damaged

        var errorDescription: String? {
            switch self {
            case .notMIDI: return String(localized: "The file is not a Standard MIDI File.")
            case .unsupportedTiming: return String(localized: "MIDI files timed in SMPTE frames are not supported.")
            case .damaged: return String(localized: "The MIDI file is damaged.")
            }
        }
    }

    var format = 0
    /// Tracks that hold notes or channel events (a format-1 tempo track is
    /// left out). A format-0 file using several channels is split into one
    /// track per channel.
    var tracks: [Track] = []
    /// The first tempo in the file (BPM), if any.
    var tempo: Double?
    var meter: MusicalMeter?

    init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url))
    }

    init(data: Data) throws {
        var reader = ByteReader(bytes: [UInt8](data))
        guard reader.readTag() == "MThd" else { throw ReadError.notMIDI }
        let headerLength = Int(try reader.readUInt32())
        format = Int(try reader.readUInt16())
        let trackCount = Int(try reader.readUInt16())
        let division = Int(try reader.readUInt16())
        guard division & 0x8000 == 0 else { throw ReadError.unsupportedTiming }
        guard division > 0 else { throw ReadError.damaged }
        try reader.skip(headerLength - 6)

        let scale = { (tick: Int) -> Int in
            Int((Double(tick) * Double(MIDITiming.ticksPerBeat) / Double(division)).rounded())
        }
        var parsed: [Track] = []
        for _ in 0..<trackCount {
            // Chunks other than MTrk are skipped, as the format requires.
            guard let tag = reader.readTag() else { break }
            let length = Int(try reader.readUInt32())
            guard tag == "MTrk" else {
                try reader.skip(length)
                continue
            }
            let chunk = try reader.slice(length)
            parsed.append(try Self.readTrack(chunk, scale: scale, tempo: &tempo, meter: &meter))
        }

        if format == 0, let track = parsed.first {
            let channels = Set(track.notes.map(\.channel) + track.events.map(\.channel))
            if channels.count > 1 {
                parsed = channels.sorted().map { channel in
                    Track(
                        name: track.name.map { "\($0) Ch\(channel + 1)" } ?? "Ch\(channel + 1)",
                        notes: track.notes.filter { $0.channel == channel },
                        events: track.events.filter { $0.channel == channel }
                    )
                }
            }
        }
        tracks = parsed.filter { !$0.isEmpty }
    }

    private static func readTrack(
        _ bytes: ByteReader,
        scale: (Int) -> Int,
        tempo: inout Double?,
        meter: inout MusicalMeter?
    ) throws -> Track {
        var reader = bytes
        var track = Track()
        var tick = 0
        var runningStatus: UInt8 = 0
        // Open notes by channel and pitch, oldest first.
        var open: [Int: [(tick: Int, velocity: UInt8)]] = [:]

        func close(channel: UInt8, pitch: UInt8, at endTick: Int) {
            let key = Int(channel) << 7 | Int(pitch)
            guard var starts = open[key], !starts.isEmpty else { return }
            let start = starts.removeFirst()
            open[key] = starts
            track.notes.append(MIDINote(
                startTick: scale(start.tick),
                lengthTicks: max(1, scale(endTick) - scale(start.tick)),
                pitch: pitch,
                velocity: start.velocity,
                channel: channel
            ))
        }

        while !reader.isAtEnd {
            tick += try reader.readVariableLength()
            var status = try reader.readByte()
            if status == 0xFF {
                let type = try reader.readByte()
                let data = try reader.slice(try reader.readVariableLength())
                switch type {
                case 0x03 where track.name == nil:
                    let name = String(decoding: data.remaining, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
                    track.name = name.isEmpty ? nil : name
                case 0x51 where tempo == nil && data.count >= 3:
                    let bytes = Array(data.remaining)
                    let microseconds = Int(bytes[0]) << 16 | Int(bytes[1]) << 8 | Int(bytes[2])
                    if microseconds > 0 { tempo = 60_000_000.0 / Double(microseconds) }
                case 0x58 where meter == nil && data.count >= 2:
                    let bytes = Array(data.remaining)
                    meter = MusicalMeter(beatsPerBar: Int(bytes[0]), beatUnit: 1 << min(6, Int(bytes[1])))
                default:
                    break
                }
                continue
            }
            if status == 0xF0 || status == 0xF7 {
                try reader.skip(try reader.readVariableLength())
                continue
            }
            if status < 0x80 {
                // Running status: this byte is the first data byte.
                guard runningStatus != 0 else { throw ReadError.damaged }
                status = runningStatus
                reader.rewind(1)
            } else {
                runningStatus = status
            }
            let kind = status & 0xF0
            let channel = status & 0x0F
            let data1 = try reader.readByte() & 0x7F
            let data2 = kind == 0xC0 || kind == 0xD0 ? 0 : try reader.readByte() & 0x7F
            switch kind {
            case 0x90 where data2 > 0:
                open[Int(channel) << 7 | Int(data1), default: []].append((tick, data2))
            case 0x80, 0x90:
                close(channel: channel, pitch: data1, at: tick)
            default:
                track.events.append(MIDIChannelEvent(tick: scale(tick), status: status, data1: data1, data2: data2))
            }
        }
        // Notes never released end with the track.
        for key in open.keys.sorted() {
            while open[key]?.isEmpty == false {
                close(channel: UInt8(key >> 7), pitch: UInt8(key & 0x7F), at: tick)
            }
        }
        track.notes.sort { ($0.startTick, $0.pitch) < ($1.startTick, $1.pitch) }
        return track
    }
}

private struct ByteReader {
    private let bytes: [UInt8]
    private var position: Int
    private let end: Int

    init(bytes: [UInt8]) {
        self.bytes = bytes
        position = 0
        end = bytes.count
    }

    private init(bytes: [UInt8], position: Int, end: Int) {
        self.bytes = bytes
        self.position = position
        self.end = end
    }

    var isAtEnd: Bool { position >= end }
    var count: Int { end - position }
    var remaining: ArraySlice<UInt8> { bytes[position..<end] }

    mutating func readByte() throws -> UInt8 {
        guard position < end else { throw StandardMIDIFile.ReadError.damaged }
        defer { position += 1 }
        return bytes[position]
    }

    mutating func readUInt16() throws -> UInt16 {
        UInt16(try readByte()) << 8 | UInt16(try readByte())
    }

    mutating func readUInt32() throws -> UInt32 {
        UInt32(try readUInt16()) << 16 | UInt32(try readUInt16())
    }

    mutating func readVariableLength() throws -> Int {
        var value = 0
        for _ in 0..<4 {
            let byte = try readByte()
            value = value << 7 | Int(byte & 0x7F)
            if byte & 0x80 == 0 { return value }
        }
        throw StandardMIDIFile.ReadError.damaged
    }

    /// The next four bytes as text, or nil at the end.
    mutating func readTag() -> String? {
        guard count >= 4 else { return nil }
        defer { position += 4 }
        return String(decoding: bytes[position..<position + 4], as: UTF8.self)
    }

    mutating func skip(_ length: Int) throws {
        guard length >= 0, length <= count else { throw StandardMIDIFile.ReadError.damaged }
        position += length
    }

    mutating func rewind(_ length: Int) {
        position = max(0, position - length)
    }

    /// The next `length` bytes as their own reader.
    mutating func slice(_ length: Int) throws -> ByteReader {
        guard length >= 0, length <= count else { throw StandardMIDIFile.ReadError.damaged }
        defer { position += length }
        return ByteReader(bytes: bytes, position: position, end: position + length)
    }
}
