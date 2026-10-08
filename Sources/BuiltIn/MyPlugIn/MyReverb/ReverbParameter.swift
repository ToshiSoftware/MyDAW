import AudioToolbox
import Foundation
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

/// The five controls of MyReverb. The raw value is the AU parameter address,
/// so it must never change once projects have been saved.
public enum ReverbParameter: Int, CaseIterable, Sendable, MyFXParameter {
    case hpf = 0
    case lpf = 1
    case rt = 2
    case preDelay = 3
    case mix = 4

    public var identifier: String {
        switch self {
        case .hpf: return "hpf"
        case .lpf: return "lpf"
        case .rt: return "rt"
        case .preDelay: return "preDelay"
        case .mix: return "mix"
        }
    }

    public var displayName: String {
        switch self {
        case .hpf: return "HPF"
        case .lpf: return "LPF"
        case .rt: return "RT"
        case .preDelay: return "PD"
        case .mix: return "MIX"
        }
    }

    /// HPF 0 Hz (Thru) to 1 kHz; LPF 200 Hz to 24 kHz (Thru); RT 0.1 to 60 s;
    /// pre-delay 0 to 1 s; mix 0 to 100 % wet.
    public var range: ClosedRange<Float> {
        switch self {
        case .hpf: return 0...1_000
        case .lpf: return 200...24_000
        case .rt: return 0.1...60
        case .preDelay: return 0...1
        case .mix: return 0...100
        }
    }

    public var defaultValue: Float {
        switch self {
        case .hpf: return 80
        case .lpf: return 8_000
        case .rt: return 2
        case .preDelay: return 0.020
        case .mix: return 100
        }
    }

    public var unit: AudioUnitParameterUnit {
        switch self {
        case .hpf, .lpf: return .hertz
        case .rt, .preDelay: return .seconds
        case .mix: return .percent
        }
    }

    public var flags: AudioUnitParameterOptions {
        self == .lpf ? [.flag_CanRamp, .flag_DisplayLogarithmic] : [.flag_CanRamp]
    }

    /// HPF below 1 Hz and LPF at its top end are "Thru" (filter off).
    public static func isHighPassThru(_ value: Float) -> Bool { value < 1 }
    public static func isLowPassThru(_ value: Float) -> Bool { value >= ReverbParameter.lpf.range.upperBound - 0.5 }

    public func displayString(for value: Float) -> String {
        switch self {
        case .hpf:
            return Self.isHighPassThru(value) ? "Thru" : Self.frequencyString(value)
        case .lpf:
            return Self.isLowPassThru(value) ? "Thru" : Self.frequencyString(value)
        case .rt:
            return value < 10 ? String(format: "%.2f s", value) : String(format: "%.1f s", value)
        case .preDelay:
            return String(format: "%.0f ms", value * 1_000)
        case .mix:
            return String(format: "%.0f%%", value)
        }
    }

    private static func frequencyString(_ value: Float) -> String {
        value < 1_000 ? String(format: "%.0f Hz", value) : String(format: "%.2f kHz", value / 1_000)
    }

    /// Parses what `displayString` produces, plus bare numbers in the
    /// parameter's display unit (Hz, s, ms, %); "k" multiplies by 1000
    /// ("8k", "8 kHz"), and "ms" is accepted for RT.
    public func value(fromDisplayString string: String) -> Float? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased() == "thru" {
            switch self {
            case .hpf: return range.lowerBound
            case .lpf: return range.upperBound
            default: return nil
            }
        }
        let number = trimmed.prefix { "0123456789.-".contains($0) }
        guard var parsed = Float(number) else { return nil }
        let unit = trimmed.dropFirst(number.count).trimmingCharacters(in: .whitespaces).lowercased()
        switch self {
        case .hpf, .lpf:
            if unit.hasPrefix("k") { parsed *= 1_000 }
        case .rt:
            if unit.hasPrefix("ms") { parsed /= 1_000 }
        case .preDelay:
            if !unit.hasPrefix("s") { parsed /= 1_000 } // ms unless "s"
        case .mix:
            break
        }
        return clamped(parsed)
    }
}
