import AudioToolbox
import Foundation

/// Note lengths a tempo-synced control can choose, shortest first. The raw
/// value is a saved parameter value, so it must never change.
public enum MyFXNoteLength: Int, CaseIterable, Sendable {
    case sixtyFourth = 0
    case thirtySecond = 1
    case sixteenth = 2
    case eighth = 3
    case quarter = 4
    case half = 5
    case oneBar = 6
    case twoBars = 7
    case fourBars = 8

    /// Short enough for a fader's value field with a type suffix ("4 barD").
    public var displayName: String {
        switch self {
        case .sixtyFourth: return "1/64"
        case .thirtySecond: return "1/32"
        case .sixteenth: return "1/16"
        case .eighth: return "1/8"
        case .quarter: return "1/4"
        case .half: return "1/2"
        case .oneBar: return "1 bar"
        case .twoBars: return "2 bar"
        case .fourBars: return "4 bar"
        }
    }

    /// Length in quarter notes; a bar is `beatsPerBar` of them.
    public func quarterNotes(beatsPerBar: Double) -> Double {
        switch self {
        case .oneBar: return beatsPerBar
        case .twoBars: return 2 * beatsPerBar
        case .fourBars: return 4 * beatsPerBar
        default: return 4 / Double(64 >> rawValue)
        }
    }
}

/// Normal, triplet (2/3 of the length) or dotted (1.5 times). The raw value
/// is a saved parameter value, so it must never change.
public enum MyFXNoteType: Int, CaseIterable, Sendable {
    case normal = 0
    case triplet = 1
    case dotted = 2

    public var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .triplet: return "Triplet"
        case .dotted: return "Dotted"
        }
    }

    /// Appended to a note length: "1/8T", "1/8D".
    public var suffix: String {
        switch self {
        case .normal: return ""
        case .triplet: return "T"
        case .dotted: return "D"
        }
    }

    public var factor: Double {
        switch self {
        case .normal: return 1
        case .triplet: return 2.0 / 3.0
        case .dotted: return 1.5
        }
    }
}

/// A note length with its type, as a synced control shows and parses it.
public enum MyFXNoteValue {
    public static func displayString(_ length: MyFXNoteLength, _ type: MyFXNoteType) -> String {
        length.displayName + type.suffix
    }

    /// "1/8", "1/8T", "1/8 D", "1/8.", "2 bars", "1BarT"; nil when unknown.
    public static func parse(_ string: String) -> (MyFXNoteLength, MyFXNoteType)? {
        var text = string.lowercased().replacingOccurrences(of: " ", with: "")
        var type = MyFXNoteType.normal
        if text.hasSuffix("t") {
            type = .triplet
            text.removeLast()
        } else if text.hasSuffix("d") || text.hasSuffix(".") {
            type = .dotted
            text.removeLast()
        }
        if text.hasSuffix("bars") { text.removeLast() }
        guard let length = MyFXNoteLength.allCases.first(where: {
            $0.displayName.replacingOccurrences(of: " ", with: "") == text
        }) else { return nil }
        return (length, type)
    }
}

/// The host's tempo for a kernel: taken from the host's musical context at
/// the start of each render, read from any thread (single 64-bit words).
/// Without a host tempo it stays at 120 BPM in 4/4.
///
/// While the host's transport moves, it also holds the song position at the
/// start of the current render (in quarter notes), so an LFO can lock its
/// phase to the bars. `renderCount` tells a kernel that a new render started.
public final class MyFXTempo {
    public static let defaultBeatsPerMinute = 120.0
    private static let tempoRange = 1.0...999.0

    /// [beats per minute, quarter notes per bar, beat position, moving (0 / 1)].
    private let storage = UnsafeMutablePointer<Double>.allocate(capacity: 4)
    /// Render thread only: counts renders, so a kernel split into segments
    /// (parameter events) locks to the position once, at the buffer start.
    public private(set) var renderCount = 0

    public init() {
        storage[0] = Self.defaultBeatsPerMinute
        storage[1] = 4
        storage[2] = 0
        storage[3] = 0
    }

    deinit { storage.deallocate() }

    public var beatsPerMinute: Double { storage[0] }
    public var beatsPerBar: Double { storage[1] }
    /// The song position at the start of the current render, in quarter notes.
    public var beatPosition: Double { storage[2] }
    /// The host's transport is playing (or recording); `beatPosition` is valid.
    public var isMoving: Bool { storage[3] != 0 }

    /// Render thread. A time signature of 3/4 makes a bar 3 quarter notes, 6/8 makes it 3.
    public func update(beatsPerMinute: Double, numerator: Double, denominator: Int) {
        if beatsPerMinute.isFinite, Self.tempoRange.contains(beatsPerMinute) {
            storage[0] = beatsPerMinute
        }
        if numerator > 0, denominator > 0 {
            storage[1] = numerator * 4 / Double(denominator)
        }
    }

    /// Render thread, once per render after `update`: where the song is,
    /// nil when the host does not say or its transport stands still.
    public func updatePosition(beatPosition: Double?) {
        renderCount &+= 1
        if let beatPosition, beatPosition.isFinite {
            storage[2] = beatPosition
            storage[3] = 1
        } else {
            storage[3] = 0
        }
    }

    /// `length` / `type` in quarter notes (the bar from the host's time signature).
    public func quarterNotes(_ length: MyFXNoteLength, _ type: MyFXNoteType) -> Double {
        length.quarterNotes(beatsPerBar: beatsPerBar) * type.factor
    }

    /// Where a cycle of `length` / `type` stands at the current render's
    /// start (0 ..< 1, 0 on each multiple of the length from the song's
    /// start); nil while the transport stands still.
    public func cyclePhase(_ length: MyFXNoteLength, _ type: MyFXNoteType) -> Double? {
        guard isMoving else { return nil }
        let cycle = beatPosition / quarterNotes(length, type)
        return cycle - floor(cycle)
    }

    /// The length of `length` / `type` at the current tempo.
    public func seconds(_ length: MyFXNoteLength, _ type: MyFXNoteType) -> Double {
        length.quarterNotes(beatsPerBar: beatsPerBar) * type.factor * 60 / beatsPerMinute
    }
}

/// The musical context of a host that runs MyFX units in its own process
/// (MyDAW), for every unit at once. AVAudioEngine clears each Audio Unit's
/// `musicalContextBlock` and `transportStateBlock` when it stops (and does
/// not restore them), so a unit reallocated after a stop would lose the
/// tempo. Set once at launch, before any unit is allocated; units take
/// these in place of their own blocks. Hosts in other processes leave them nil.
public enum MyFXHostContext {
    public static var musicalContextBlock: AUHostMusicalContextBlock?
    public static var transportStateBlock: AUHostTransportStateBlock?
}
