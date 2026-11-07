import AudioToolbox
import Foundation
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

/// What an EQ band does.
public enum ChannelStripFilterType: Int, CaseIterable, Sendable {
    case lowCut = 0
    case lowShelf = 1
    case bell = 2
    case highShelf = 3
    case highCut = 4

    public var displayName: String {
        switch self {
        case .lowCut: return "Low Cut"
        case .lowShelf: return "Low Shelf"
        case .bell: return "Bell"
        case .highShelf: return "High Shelf"
        case .highCut: return "High Cut"
        }
    }

    /// Cuts change the sound whatever the gain, and ignore it.
    public var isCut: Bool { self == .lowCut || self == .highCut }
}

/// The order of the two processing sections.
public enum ChannelStripOrder: Int, CaseIterable, Sendable {
    case eqFirst = 0
    case compFirst = 1

    public var displayName: String {
        switch self {
        case .eqFirst: return "EQ > COMP"
        case .compFirst: return "COMP > EQ"
        }
    }
}

/// The settings of one EQ band, by its parameter's offset from the band's base.
public enum ChannelStripBandField: Int, CaseIterable, Sendable {
    case on = 0
    case type = 1
    case frequency = 2
    case gain = 3
    case q = 4
    /// 12 or 24 dB/oct; cuts only.
    case slope = 5
}

/// MyChannelStrip's controls. The raw value is the AU parameter address, so
/// it must never change once projects have been saved. Band n (1-4) uses
/// 10 (n - 1) + field; the compressor 100s; output and routing 200s.
public enum ChannelStripParameter: Int, CaseIterable, Sendable, MyFXParameter {
    case band1On = 0, band1Type = 1, band1Frequency = 2, band1Gain = 3, band1Q = 4, band1Slope = 5
    case band2On = 10, band2Type = 11, band2Frequency = 12, band2Gain = 13, band2Q = 14, band2Slope = 15
    case band3On = 20, band3Type = 21, band3Frequency = 22, band3Gain = 23, band3Q = 24, band3Slope = 25
    case band4On = 30, band4Type = 31, band4Frequency = 32, band4Gain = 33, band4Q = 34, band4Slope = 35
    case eqOn = 90
    case compOn = 100
    case compThreshold = 101
    case compRatio = 102
    case compKnee = 103
    case compAttack = 104
    case compRelease = 105
    case compMakeup = 106
    case compAutoMakeup = 107
    case compLink = 108
    case compMix = 109
    case outputGain = 200
    case order = 201

    public static let bandCount = 4
    /// One more than the largest address, for arrays indexed by address.
    public static let addressCount = 202

    /// The parameter for `field` of band `index` (0-based).
    public static func band(_ index: Int, _ field: ChannelStripBandField) -> ChannelStripParameter {
        ChannelStripParameter(rawValue: index * 10 + field.rawValue)!
    }

    /// Band index (0-based) and field, for band parameters.
    public var bandField: (band: Int, field: ChannelStripBandField)? {
        guard rawValue < 90 else { return nil }
        return (rawValue / 10, ChannelStripBandField(rawValue: rawValue % 10)!)
    }

    public var identifier: String {
        if let (band, field) = bandField {
            let name: String
            switch field {
            case .on: name = "on"
            case .type: name = "type"
            case .frequency: name = "freq"
            case .gain: name = "gain"
            case .q: name = "q"
            case .slope: name = "slope"
            }
            return "band\(band + 1)_\(name)"
        }
        switch self {
        case .eqOn: return "eq_on"
        case .compOn: return "comp_on"
        case .compThreshold: return "comp_threshold"
        case .compRatio: return "comp_ratio"
        case .compKnee: return "comp_knee"
        case .compAttack: return "comp_attack"
        case .compRelease: return "comp_release"
        case .compMakeup: return "comp_makeup"
        case .compAutoMakeup: return "comp_auto_makeup"
        case .compLink: return "comp_link"
        case .compMix: return "comp_mix"
        case .outputGain: return "output_gain"
        case .order: return "order"
        default: return ""
        }
    }

    public var displayName: String {
        if let (_, field) = bandField {
            switch field {
            case .on: return "ON"
            case .type: return "TYPE"
            case .frequency: return "FREQ"
            case .gain: return "GAIN"
            case .q: return "Q"
            case .slope: return "SLOPE"
            }
        }
        switch self {
        case .eqOn: return "EQ"
        case .compOn: return "COMP"
        case .compThreshold: return "THR"
        case .compRatio: return "RATIO"
        case .compKnee: return "KNEE"
        case .compAttack: return "ATK"
        case .compRelease: return "REL"
        case .compMakeup: return "MAKE"
        case .compAutoMakeup: return "AUTO GAIN"
        case .compLink: return "STEREO LINK"
        case .compMix: return "MIX"
        case .outputGain: return "GAIN"
        case .order: return "ORDER"
        default: return ""
        }
    }

    public var hostName: String {
        if let (band, field) = bandField {
            let name: String
            switch field {
            case .on: name = "On"
            case .type: name = "Type"
            case .frequency: name = "Freq"
            case .gain: name = "Gain"
            case .q: name = "Q"
            case .slope: name = "Slope"
            }
            return "Band \(band + 1) \(name)"
        }
        switch self {
        case .eqOn: return "EQ On"
        case .compOn: return "Comp On"
        case .compThreshold: return "Comp Threshold"
        case .compRatio: return "Comp Ratio"
        case .compKnee: return "Comp Knee"
        case .compAttack: return "Comp Attack"
        case .compRelease: return "Comp Release"
        case .compMakeup: return "Comp Makeup"
        case .compAutoMakeup: return "Comp Auto Gain"
        case .compLink: return "Comp Stereo Link"
        case .compMix: return "Comp Mix"
        case .outputGain: return "Output Gain"
        case .order: return "Order"
        default: return ""
        }
    }

    public var range: ClosedRange<Float> {
        if let (_, field) = bandField {
            switch field {
            case .on, .slope: return 0...1
            case .type: return 0...Float(ChannelStripFilterType.allCases.count - 1)
            case .frequency: return 20...20_000
            case .gain: return -18...18
            case .q: return 0.1...10
            }
        }
        switch self {
        case .compThreshold: return -60...0
        case .compRatio: return 1...20
        case .compKnee: return 0...24
        case .compAttack: return 0.1...200
        case .compRelease: return 5...2_000
        case .compMakeup: return 0...24
        case .compMix: return 0...100
        case .outputGain: return -24...24
        default: return 0...1
        }
    }

    public var defaultValue: Float {
        if let (band, field) = bandField {
            let defaults: [(type: ChannelStripFilterType, frequency: Float, q: Float)] = [
                (.lowShelf, 100, 0.71), (.bell, 400, 1), (.bell, 2_500, 1), (.highShelf, 8_000, 0.71)
            ]
            switch field {
            case .on: return 1
            case .type: return Float(defaults[band].type.rawValue)
            case .frequency: return defaults[band].frequency
            case .gain: return 0
            case .q: return defaults[band].q
            case .slope: return 0
            }
        }
        switch self {
        case .eqOn: return 1
        case .compOn: return 0
        case .compThreshold: return -10
        case .compRatio: return 2
        case .compKnee: return 6
        case .compAttack: return 15
        case .compRelease: return 120
        case .compMakeup: return 0
        case .compAutoMakeup: return 0
        case .compLink: return 1
        case .compMix: return 100
        case .outputGain: return 0
        case .order: return Float(ChannelStripOrder.eqFirst.rawValue)
        default: return 0
        }
    }

    public var unit: AudioUnitParameterUnit {
        if let (_, field) = bandField {
            switch field {
            case .on: return .boolean
            case .type, .slope: return .indexed
            case .frequency: return .hertz
            case .gain: return .decibels
            case .q: return .generic
            }
        }
        switch self {
        case .eqOn, .compOn, .compAutoMakeup, .compLink: return .boolean
        case .order: return .indexed
        case .compThreshold, .compKnee, .compMakeup, .outputGain: return .decibels
        case .compRatio: return .ratio
        case .compAttack, .compRelease: return .milliseconds
        case .compMix: return .percent
        default: return .generic
        }
    }

    /// Switches and indexes jump; continuous values ramp.
    public var isStepped: Bool {
        switch unit {
        case .boolean, .indexed: return true
        default: return false
        }
    }

    public var flags: AudioUnitParameterOptions {
        if isStepped { return [] }
        switch self {
        case .compRatio, .compAttack, .compRelease: return [.flag_CanRamp, .flag_DisplayLogarithmic]
        default:
            if let (_, field) = bandField, field == .frequency || field == .q {
                return [.flag_CanRamp, .flag_DisplayLogarithmic]
            }
            return [.flag_CanRamp]
        }
    }

    public var valueStrings: [String]? {
        if let (_, field) = bandField {
            switch field {
            case .type: return ChannelStripFilterType.allCases.map(\.displayName)
            case .slope: return ["12 dB/oct", "24 dB/oct"]
            default: return nil
            }
        }
        return self == .order ? ChannelStripOrder.allCases.map(\.displayName) : nil
    }

    public func clamped(_ value: Float) -> Float {
        guard value.isFinite else { return defaultValue }
        let inRange = min(max(value, range.lowerBound), range.upperBound)
        return isStepped ? inRange.rounded() : inRange
    }

    public func displayString(for value: Float) -> String {
        if let strings = valueStrings {
            let index = Int(clamped(value))
            return strings.indices.contains(index) ? strings[index] : ""
        }
        if unit == .boolean { return value >= 0.5 ? "On" : "Off" }
        switch unit {
        case .hertz:
            return value >= 1_000 ? String(format: value >= 10_000 ? "%.1fk" : "%.2fk", value / 1_000)
                                  : String(format: "%.0f", value)
        case .decibels:
            return String(format: self == .compThreshold || self == .compKnee ? "%.1f" : "%+.1f", value)
        case .ratio:
            return String(format: value >= 10 ? "%.0f:1" : "%.1f:1", value)
        case .milliseconds:
            return String(format: value < 10 ? "%.1f" : "%.0f", value)
        case .percent:
            return String(format: "%.0f%%", value)
        default:
            return String(format: value < 10 ? "%.2f" : "%.1f", value)
        }
    }

    /// Parses what `displayString` produces; "2.5k" is 2500 Hz; switches
    /// and indexes also by name.
    public func value(fromDisplayString string: String) -> Float? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if let strings = valueStrings,
           let index = strings.firstIndex(where: { $0.lowercased() == trimmed.lowercased() }) {
            return Float(index)
        }
        if unit == .boolean {
            switch trimmed.lowercased() {
            case "on": return 1
            case "off": return 0
            default: break
            }
        }
        let number = trimmed.prefix { "0123456789.-+".contains($0) }
        guard var parsed = Float(number) else { return nil }
        if unit == .hertz, trimmed.dropFirst(number.count).trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("k") {
            parsed *= 1_000
        }
        return clamped(parsed)
    }
}
