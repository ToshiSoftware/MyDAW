import AudioToolbox
import Foundation
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

/// MyMaximizer's controls. The raw value is the AU parameter address, so it
/// must never change once projects have been saved. Gaps leave room for
/// later controls next to their section (11 and 21 stay unused: the UPWARD
/// threshold is fixed, and there is no true peak). Cases are in fader order.
public enum MaximizerParameter: Int, CaseIterable, Sendable, MyFXParameter {
    case inputGain = 0
    case upward = 10
    case threshold = 22
    case attack = 31
    case release = 30
    case outputLevel = 20

    /// Size of an array indexed by raw value.
    static let addressCount = 32

    public var identifier: String {
        switch self {
        case .inputGain: return "input_gain"
        case .upward: return "upward"
        case .threshold: return "threshold"
        case .attack: return "attack"
        case .release: return "release"
        case .outputLevel: return "output_level"
        }
    }

    public var displayName: String {
        switch self {
        case .inputGain: return "INPUT"
        case .upward: return "UPWARD"
        case .threshold: return "THRESH"
        case .attack: return "ATTACK"
        case .release: return "RELEASE"
        case .outputLevel: return "OUTPUT"
        }
    }

    public var hostName: String {
        switch self {
        case .inputGain: return "Input Gain"
        case .upward: return "Upward Compress"
        case .threshold: return "Threshold"
        case .attack: return "Attack"
        case .release: return "Release"
        case .outputLevel: return "Output Level"
        }
    }

    public var range: ClosedRange<Float> {
        switch self {
        case .inputGain: return -12...24
        case .upward: return 0...12
        case .threshold: return -30...0
        case .attack: return 0...10
        case .release: return 10...500
        case .outputLevel: return -12...0
        }
    }

    public var defaultValue: Float {
        switch self {
        case .inputGain: return 0
        case .upward: return 2
        case .threshold: return -0.1
        case .attack: return 0
        case .release: return 50
        case .outputLevel: return -0.1
        }
    }

    public var unit: AudioUnitParameterUnit {
        switch self {
        case .attack, .release: return .milliseconds
        default: return .decibels
        }
    }

    public func displayString(for value: Float) -> String {
        switch self {
        case .attack: return String(format: "%.1f ms", value)
        case .release: return String(format: "%.0f ms", value)
        case .inputGain, .upward: return String(format: "%+.1f dB", value)
        case .threshold, .outputLevel: return String(format: "%.1f dB", value)
        }
    }

    public func value(fromDisplayString string: String) -> Float? {
        let number = string.trimmingCharacters(in: .whitespaces).prefix { "0123456789.-+".contains($0) }
        return Float(number).map(clamped)
    }
}
