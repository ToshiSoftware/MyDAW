import AudioToolbox
import Foundation
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

/// MyDeEsser's controls. The raw value is the AU parameter address, so it
/// must never change once projects have been saved. Gaps leave room for
/// later controls next to their section. Cases are in fader order, then
/// the two buttons.
public enum DeEsserParameter: Int, CaseIterable, Sendable, MyFXParameter {
    case inputGain = 0
    case frequency = 10
    case threshold = 20
    case attack = 21
    case release = 22
    case stereoLink = 23
    case listen = 30

    /// Size of an array indexed by raw value.
    static let addressCount = 31

    public var identifier: String {
        switch self {
        case .inputGain: return "input_gain"
        case .frequency: return "frequency"
        case .threshold: return "threshold"
        case .attack: return "attack"
        case .release: return "release"
        case .stereoLink: return "stereo_link"
        case .listen: return "listen"
        }
    }

    public var displayName: String {
        switch self {
        case .inputGain: return "INPUT"
        case .frequency: return "FREQ"
        case .threshold: return "THRESH"
        case .attack: return "ATTACK"
        case .release: return "RELEASE"
        case .stereoLink: return "STEREO LINK"
        case .listen: return "LISTEN"
        }
    }

    public var hostName: String {
        switch self {
        case .inputGain: return "Input Gain"
        case .frequency: return "Frequency"
        case .threshold: return "Threshold"
        case .attack: return "Attack"
        case .release: return "Release"
        case .stereoLink: return "Stereo Link"
        case .listen: return "Listen"
        }
    }

    public var range: ClosedRange<Float> {
        switch self {
        case .inputGain: return -24...24
        case .frequency: return 2_000...15_000
        case .threshold: return -60...0
        case .attack: return 0...5
        case .release: return 5...50
        case .stereoLink, .listen: return 0...1
        }
    }

    public var defaultValue: Float {
        switch self {
        case .inputGain: return 0
        case .frequency: return 6_500
        case .threshold: return -12
        case .attack: return 0
        case .release: return 10
        case .stereoLink: return 1
        case .listen: return 0
        }
    }

    public var unit: AudioUnitParameterUnit {
        switch self {
        case .inputGain, .threshold: return .decibels
        case .frequency: return .hertz
        case .attack, .release: return .milliseconds
        case .stereoLink, .listen: return .boolean
        }
    }

    var isSwitch: Bool { unit == .boolean }

    /// Switches jump; continuous values ramp.
    public var flags: AudioUnitParameterOptions {
        switch self {
        case .stereoLink, .listen: return []
        case .frequency, .release: return [.flag_CanRamp, .flag_DisplayLogarithmic]
        default: return [.flag_CanRamp]
        }
    }

    public func clamped(_ value: Float) -> Float {
        guard value.isFinite else { return defaultValue }
        let inRange = min(max(value, range.lowerBound), range.upperBound)
        return isSwitch ? inRange.rounded() : inRange
    }

    public func displayString(for value: Float) -> String {
        switch self {
        case .inputGain: return String(format: "%+.1f dB", value)
        case .threshold: return String(format: "%.1f dB", value)
        case .frequency: return String(format: value >= 10_000 ? "%.1fk" : "%.2fk", value / 1_000)
        case .attack: return String(format: "%.1f ms", value)
        case .release: return String(format: "%.0f ms", value)
        case .stereoLink, .listen: return value >= 0.5 ? "On" : "Off"
        }
    }

    /// Parses what `displayString` produces; "6.5k" is 6500 Hz, and a
    /// frequency typed below 100 counts as kHz ("8" is 8 kHz).
    public func value(fromDisplayString string: String) -> Float? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if isSwitch {
            switch trimmed.lowercased() {
            case "on": return 1
            case "off": return 0
            default: break
            }
        }
        let number = trimmed.prefix { "0123456789.-+".contains($0) }
        guard var parsed = Float(number) else { return nil }
        if self == .frequency {
            let rest = trimmed.dropFirst(number.count).trimmingCharacters(in: .whitespaces).lowercased()
            if rest.hasPrefix("k") || parsed < 100 { parsed *= 1_000 }
        }
        return clamped(parsed)
    }
}
