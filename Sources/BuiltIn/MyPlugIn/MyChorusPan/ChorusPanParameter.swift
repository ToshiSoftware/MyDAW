import AudioToolbox
import Foundation
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

/// The four effects, chosen in the header menu (one at a time).
public enum ChorusPanMode: Int, CaseIterable, Sendable {
    case chorus = 0
    case dimension = 1
    case flanger = 2
    case autoPan = 3

    public var displayName: String {
        switch self {
        case .chorus: return "Chorus Pedal"
        case .dimension: return "Dimension"
        case .flanger: return "Flanger Pedal"
        case .autoPan: return "Auto Pan"
        }
    }

    /// This mode's own parameters: what INIT resets.
    public var parameters: [ChorusPanParameter] {
        ChorusPanParameter.allCases.filter { $0.mode == self }
    }
}

/// LFO waveforms.
public enum ChorusPanWave: Int, CaseIterable, Sendable {
    case sine = 0
    case triangle = 1
    case saw = 2
    case square = 3

    public var displayName: String {
        switch self {
        case .sine: return "Sine"
        case .triangle: return "Triangle"
        case .saw: return "Saw"
        case .square: return "Square"
        }
    }
}

/// Dimension (Docs/MyChorusPan.md §2.3, §3.3), after the Roland SDD-320 as
/// Arturia's Chorus DIMENSION-D manual describes it: buttons 1 to 3 choose
/// the delay and the swing (1 softest; 2 deeper with half of 1's delay; 3
/// between them with twice the swing), all at the same slow triangle LFO.
/// Button 4 works with them: louder effect, quieter input.
public enum ChorusPanDimensionSetting {
    public static let delaysMilliseconds: [Float] = [6, 3, 4.5]
    public static let swingsMilliseconds: [Float] = [0.6, 0.8, 1.2]
    public static let speed = 0.25
    /// Each side is its own line minus this much of the other (inverted):
    /// left = A - cross x B, right = B - cross x A. 1 made the two sides
    /// fully anti-phase (a phasey width); 0.5 keeps them apart.
    public static let cross: Float = 0.5
    /// BOOST (the SDD-320's button 4): the effect up 3 dB, the input down 3 dB.
    public static let boostWetGain = Float(2).squareRoot()
    public static let boostDryGain = 1 / Float(2).squareRoot()
}

/// MyChorusPan's controls (Docs/MyChorusPan.md §2), each mode with its own
/// in its own block of ten. The raw value is the AU parameter address, so it
/// must never change once projects have been saved.
public enum ChorusPanParameter: Int, CaseIterable, Sendable, MyFXParameter {
    case mode = 0

    case chorusDelay = 10
    case chorusDepth = 11
    case chorusLFOType = 12
    case chorusSpeed = 13
    case chorusLFOWidth = 14
    case chorusStereoWidth = 15
    case chorusMix = 16

    case dimensionMode = 20
    case dimensionStereoWidth = 21
    case dimensionMix = 22
    case dimensionBoost = 23

    case flangerDelay = 30
    case flangerDepth = 31
    case flangerFeedback = 32
    case flangerLFOType = 33
    case flangerSpeed = 34
    case flangerLFOWidth = 35
    case flangerStereoWidth = 36
    case flangerMix = 37

    case panType = 40
    case panSpeed = 41
    case panWidth = 42

    /// One more than the largest address, for arrays indexed by address.
    public static let addressCount = 43

    /// The mode this parameter belongs to (nil: MODE itself).
    public var mode: ChorusPanMode? {
        switch rawValue {
        case 10..<20: return .chorus
        case 20..<30: return .dimension
        case 30..<40: return .flanger
        case 40..<50: return .autoPan
        default: return nil
        }
    }

    private enum Kind {
        case mode, delay, depth, feedback, wave, speed, percent, dimensionMode, toggle
    }

    private var kind: Kind {
        switch self {
        case .mode: return .mode
        case .chorusDelay, .flangerDelay: return .delay
        case .chorusDepth, .flangerDepth: return .depth
        case .flangerFeedback: return .feedback
        case .chorusLFOType, .flangerLFOType, .panType: return .wave
        case .chorusSpeed, .flangerSpeed, .panSpeed: return .speed
        case .dimensionMode: return .dimensionMode
        case .dimensionBoost: return .toggle
        default: return .percent
        }
    }

    public var identifier: String {
        switch self {
        case .mode: return "mode"
        case .chorusDelay: return "chorus_delay"
        case .chorusDepth: return "chorus_depth"
        case .chorusLFOType: return "chorus_lfo_type"
        case .chorusSpeed: return "chorus_speed"
        case .chorusLFOWidth: return "chorus_lfo_width"
        case .chorusStereoWidth: return "chorus_stereo_width"
        case .chorusMix: return "chorus_mix"
        case .dimensionMode: return "dimension_mode"
        case .dimensionStereoWidth: return "dimension_stereo_width"
        case .dimensionMix: return "dimension_mix"
        case .dimensionBoost: return "dimension_boost"
        case .flangerDelay: return "flanger_delay"
        case .flangerDepth: return "flanger_depth"
        case .flangerFeedback: return "flanger_feedback"
        case .flangerLFOType: return "flanger_lfo_type"
        case .flangerSpeed: return "flanger_speed"
        case .flangerLFOWidth: return "flanger_lfo_width"
        case .flangerStereoWidth: return "flanger_stereo_width"
        case .flangerMix: return "flanger_mix"
        case .panType: return "pan_type"
        case .panSpeed: return "pan_speed"
        case .panWidth: return "pan_width"
        }
    }

    /// Fader labels, short enough for seven faders in 300 px.
    public var displayName: String {
        switch self {
        case .mode: return "MODE"
        case .chorusDelay, .flangerDelay: return "DELAY"
        case .chorusDepth, .flangerDepth: return "DEPTH"
        case .flangerFeedback: return "FDBK"
        case .chorusLFOType, .flangerLFOType: return "LFO"
        case .chorusSpeed, .flangerSpeed, .panSpeed: return "SPEED"
        case .chorusLFOWidth, .flangerLFOWidth: return "L.WID"
        case .chorusStereoWidth, .dimensionStereoWidth, .flangerStereoWidth: return "ST.WID"
        case .chorusMix, .dimensionMix, .flangerMix: return "MIX"
        case .dimensionMode: return "MODE"
        case .dimensionBoost: return "BOOST"
        case .panType: return "PAN"
        case .panWidth: return "WIDTH"
        }
    }

    /// Name in hosts' generic views and automation lanes: mode, then control.
    public var hostName: String {
        let control: String
        switch kind {
        case .mode: return "Mode"
        case .delay: control = "Delay Time"
        case .depth: control = "Depth"
        case .feedback: control = "Feedback"
        case .wave: control = self == .panType ? "Type" : "LFO Type"
        case .speed: control = "Speed"
        case .dimensionMode: control = "Mode"
        case .toggle: control = "Boost"
        case .percent:
            switch self {
            case .chorusLFOWidth, .flangerLFOWidth: control = "LFO Width"
            case .chorusStereoWidth, .dimensionStereoWidth, .flangerStereoWidth: control = "Stereo Width"
            case .panWidth: control = "Width"
            default: control = "Mix"
            }
        }
        return "\(mode?.displayName ?? "") \(control)"
    }

    /// DELAY in ms, FEEDBACK -95 to +95 %, speeds in Hz, the rest in %.
    public var range: ClosedRange<Float> {
        switch self {
        case .mode: return 0...Float(ChorusPanMode.allCases.count - 1)
        case .chorusDelay: return 3...30
        case .flangerDelay: return 0.1...10
        case .flangerFeedback: return -95...95
        case .chorusLFOType, .flangerLFOType, .panType: return 0...Float(ChorusPanWave.allCases.count - 1)
        case .chorusSpeed: return 0.05...5
        case .flangerSpeed: return 0.02...5
        case .panSpeed: return 0.05...10
        case .dimensionMode: return 0...Float(ChorusPanDimensionSetting.delaysMilliseconds.count - 1)
        case .dimensionBoost: return 0...1
        default: return 0...100
        }
    }

    /// The recommended setting, which INIT restores.
    public var defaultValue: Float {
        switch self {
        case .mode: return Float(ChorusPanMode.chorus.rawValue)
        case .chorusDelay: return 8
        case .chorusDepth: return 30
        case .chorusLFOType, .flangerLFOType: return Float(ChorusPanWave.triangle.rawValue)
        case .chorusSpeed: return 0.6
        case .chorusLFOWidth: return 100
        case .chorusMix, .dimensionMix, .flangerMix: return 50
        case .dimensionMode, .dimensionBoost: return 0
        case .flangerDelay: return 2
        case .flangerDepth: return 80
        case .flangerFeedback: return 60
        case .flangerSpeed: return 0.2
        case .flangerLFOWidth: return 0
        case .panType: return Float(ChorusPanWave.sine.rawValue)
        case .panSpeed: return 1
        default: return 100
        }
    }

    public var unit: AudioUnitParameterUnit {
        switch kind {
        case .mode, .wave, .dimensionMode: return .indexed
        case .toggle: return .boolean
        case .delay: return .milliseconds
        case .speed: return .hertz
        default: return .percent
        }
    }

    public var flags: AudioUnitParameterOptions {
        switch kind {
        case .mode, .wave, .dimensionMode, .toggle: return []
        case .delay, .speed: return [.flag_CanRamp, .flag_DisplayLogarithmic]
        default: return [.flag_CanRamp]
        }
    }

    public var isIndexed: Bool {
        kind == .mode || kind == .wave || kind == .dimensionMode || kind == .toggle
    }

    public var isLogarithmic: Bool {
        kind == .delay || kind == .speed
    }

    public var valueStrings: [String]? {
        switch kind {
        case .mode: return ChorusPanMode.allCases.map(\.displayName)
        case .wave: return ChorusPanWave.allCases.map(\.displayName)
        case .dimensionMode: return ChorusPanDimensionSetting.delaysMilliseconds.indices.map { "\($0 + 1)" }
        case .toggle: return ["Off", "On"]
        default: return nil
        }
    }

    public func clamped(_ value: Float) -> Float {
        guard value.isFinite else { return defaultValue }
        let inRange = min(max(value, range.lowerBound), range.upperBound)
        return isIndexed ? inRange.rounded() : inRange
    }

    public func displayString(for value: Float) -> String {
        let value = clamped(value)
        switch kind {
        case .mode, .wave, .dimensionMode, .toggle:
            return valueStrings?[Int(value)] ?? ""
        // At most 6 characters: seven faders share 300 px.
        case .delay:
            if value < 1 { return String(format: "%.2fms", value) }
            if value < 10 { return String(format: "%.1f ms", value) }
            return String(format: "%.0f ms", value)
        case .speed:
            return value < 1 ? String(format: "%.2fHz", value) : String(format: "%.1fHz", value)
        case .feedback:
            return value.rounded() == 0 ? "0%" : String(format: "%+.0f%%", value)
        case .depth, .percent:
            return String(format: "%.0f%%", value)
        }
    }

    /// Parses what `displayString` produces, bare numbers in the display
    /// unit, and an indexed value by name (Dimension: "1" to "4").
    public func value(fromDisplayString string: String) -> Float? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if isIndexed {
            if let index = valueStrings?.firstIndex(where: { $0.lowercased() == trimmed.lowercased() }) {
                return Float(index)
            }
            return kind == .dimensionMode ? nil : Float(trimmed).map(clamped)
        }
        let number = trimmed.prefix { "0123456789.-+".contains($0) }
        return Float(number).map(clamped)
    }
}
