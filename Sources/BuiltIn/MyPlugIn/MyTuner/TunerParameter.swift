import AudioToolbox
import Foundation
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

/// What the tuner matches a pitch to (Docs/MyTuner.md §3.3).
public enum TunerMode: Int, CaseIterable, Sendable {
    /// The nearest semitone.
    case chromatic = 0
    /// The nearest open string of a guitar in standard tuning.
    case guitar = 1

    public var displayName: String {
        switch self {
        case .chromatic: return "Chromatic"
        case .guitar: return "Guitar"
        }
    }
}

/// MyTuner's controls (Docs/MyTuner.md §2). The raw value is the AU
/// parameter address, so it must never change once projects have been saved.
public enum TunerParameter: Int, CaseIterable, Sendable, MyFXParameter {
    case calibration = 0
    case mode = 1
    case strobe = 2

    public var identifier: String {
        switch self {
        case .calibration: return "calibration"
        case .mode: return "mode"
        case .strobe: return "strobe"
        }
    }

    public var displayName: String {
        switch self {
        case .calibration: return "Calibration"
        case .mode: return "Mode"
        case .strobe: return "Strobe"
        }
    }

    public var range: ClosedRange<Float> {
        switch self {
        case .calibration: return 430...450
        case .mode: return 0...Float(TunerMode.allCases.count - 1)
        case .strobe: return 0...1
        }
    }

    public var defaultValue: Float {
        switch self {
        case .calibration: return 440
        case .mode: return Float(TunerMode.chromatic.rawValue)
        case .strobe: return 0
        }
    }

    public var unit: AudioUnitParameterUnit {
        switch self {
        case .calibration: return .hertz
        case .mode: return .indexed
        case .strobe: return .boolean
        }
    }

    public var flags: AudioUnitParameterOptions {
        self == .calibration ? [.flag_CanRamp] : []
    }

    public var valueStrings: [String]? {
        switch self {
        case .calibration: return nil
        case .mode: return TunerMode.allCases.map(\.displayName)
        case .strobe: return ["Off", "On"]
        }
    }

    /// Calibration in 0.5 Hz steps; the switches are whole numbers.
    public func clamped(_ value: Float) -> Float {
        guard value.isFinite else { return defaultValue }
        let inRange = min(max(value, range.lowerBound), range.upperBound)
        return self == .calibration ? (inRange * 2).rounded() / 2 : inRange.rounded()
    }

    public func displayString(for value: Float) -> String {
        switch self {
        case .calibration: return String(format: "%.1f Hz", value)
        case .mode: return (TunerMode(rawValue: Int(value.rounded())) ?? .chromatic).displayName
        case .strobe: return value >= 0.5 ? "On" : "Off"
        }
    }

    public func value(fromDisplayString string: String) -> Float? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if let strings = valueStrings,
           let index = strings.firstIndex(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return Float(index)
        }
        let number = trimmed.prefix { "0123456789.-+".contains($0) }
        return Float(number).map(clamped)
    }
}

/// A detected pitch as a note: name, octave and how far off it is
/// (Docs/MyTuner.md §3.3).
public struct TunerNote: Equatable, Sendable {
    /// Guitar strings in standard tuning, 6 (low E) to 1, as MIDI notes.
    public static let guitarStrings = [40, 45, 50, 55, 59, 64]
    public static let names = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]
    /// The needle stops at the ends of the scale.
    public static let centsRange: ClosedRange<Double> = -50...50

    /// MIDI note number of the target (69 = A4).
    public let midiNote: Int
    /// Signed distance from the target, in cents (not clamped).
    public let cents: Double
    /// Guitar mode: 6 (low E) to 1 (high E); nil in Chromatic.
    public let guitarString: Int?

    public var name: String { Self.names[((midiNote % 12) + 12) % 12] }
    /// Scientific octave: A4 = 440 Hz, the guitar's low E is E2.
    public var octave: Int { Int((Double(midiNote) / 12).rounded(.down)) - 1 }

    public init(midiNote: Int, cents: Double, guitarString: Int?) {
        self.midiNote = midiNote
        self.cents = cents
        self.guitarString = guitarString
    }

    /// The note `frequency` is nearest to, with A4 at `calibration` Hz.
    public init?(frequency: Double, calibration: Double, mode: TunerMode) {
        guard frequency > 0, calibration > 0, frequency.isFinite else { return nil }
        let note = 69 + 12 * log2(frequency / calibration)
        switch mode {
        case .chromatic:
            let nearest = Int(note.rounded())
            self.init(midiNote: nearest, cents: (note - Double(nearest)) * 100, guitarString: nil)
        case .guitar:
            let index = Self.guitarStrings.indices.min {
                abs(Double(Self.guitarStrings[$0]) - note) < abs(Double(Self.guitarStrings[$1]) - note)
            } ?? 0
            let target = Self.guitarStrings[index]
            self.init(midiNote: target, cents: (note - Double(target)) * 100,
                      guitarString: Self.guitarStrings.count - index)
        }
    }
}
