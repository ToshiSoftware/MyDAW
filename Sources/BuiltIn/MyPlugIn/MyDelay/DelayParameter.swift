import AudioToolbox
import Foundation
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

/// How the two delay lines are fed and heard.
public enum DelayMode: Int, CaseIterable, Sendable {
    /// L+R into one line; the same echoes on both sides.
    case mono = 0
    /// L and R through their own lines; same settings for both.
    case stereo = 1
    /// L+R, heard at Time on the left and Time x 1.5 on the right; no feedback.
    case doubler = 2
    /// L+R into the left line, whose output feeds the right line and back,
    /// so the echoes alternate sides.
    case pingPong = 3

    /// The right side's delay as a multiple of Time in Doubler mode.
    public static let doublerRightRatio = 1.5

    public var displayName: String {
        switch self {
        case .mono: return "Mono Delay"
        case .stereo: return "Stereo Delay"
        case .doubler: return "Doubler"
        case .pingPong: return "Ping-Pong"
        }
    }

    public var usesFeedback: Bool { self != .doubler }
    /// Mono's echoes are the same on both sides, so width has nothing to do.
    public var usesWidth: Bool { self != .mono }
}

/// MyDelay's controls. The raw value is the AU parameter address, so it must
/// never change once projects have been saved.
public enum DelayParameter: Int, CaseIterable, Sendable, MyFXParameter {
    case mode = 0
    case time = 1
    case feedback = 2
    case width = 3
    case mix = 4
    /// Tempo sync: TIME follows the host's tempo as a note length.
    case sync = 5
    case syncNote = 6
    case syncType = 7

    /// Sync's switch, note length and note type: steps, not a level.
    public var isIndexed: Bool {
        self == .mode || self == .sync || self == .syncNote || self == .syncType
    }

    public var identifier: String {
        switch self {
        case .mode: return "mode"
        case .time: return "time"
        case .feedback: return "feedback"
        case .width: return "width"
        case .mix: return "mix"
        case .sync: return "sync"
        case .syncNote: return "sync_note"
        case .syncType: return "sync_type"
        }
    }

    public var displayName: String {
        switch self {
        case .mode: return "MODE"
        case .time: return "TIME"
        case .feedback: return "FEEDBACK"
        case .width: return "WIDTH"
        case .mix: return "MIX"
        case .sync: return "SYNC"
        case .syncNote: return "NOTE"
        case .syncType: return "TYPE"
        }
    }

    /// Mode and sync are indexes; time in seconds (1 ms to 10 s); the rest in percent.
    public var range: ClosedRange<Float> {
        switch self {
        case .mode: return 0...Float(DelayMode.allCases.count - 1)
        case .sync: return 0...1
        case .syncNote: return 0...Float(MyFXNoteLength.allCases.count - 1)
        case .syncType: return 0...Float(MyFXNoteType.allCases.count - 1)
        case .time: return 0.001...10
        case .feedback, .width, .mix: return 0...100
        }
    }

    public var defaultValue: Float {
        switch self {
        case .mode: return Float(DelayMode.stereo.rawValue)
        case .time: return 0.25
        case .feedback: return 30
        case .width: return 100
        case .mix: return 100
        case .sync: return 0
        case .syncNote: return Float(MyFXNoteLength.quarter.rawValue)
        case .syncType: return Float(MyFXNoteType.normal.rawValue)
        }
    }

    public var hostName: String {
        switch self {
        case .sync: return "Tempo Sync"
        case .syncNote: return "Sync Note"
        case .syncType: return "Sync Note Type"
        default: return displayName.capitalized
        }
    }

    public var unit: AudioUnitParameterUnit {
        switch self {
        case .mode, .syncNote, .syncType: return .indexed
        case .sync: return .boolean
        case .time: return .seconds
        case .feedback, .width, .mix: return .percent
        }
    }

    public var flags: AudioUnitParameterOptions {
        switch self {
        case .mode, .sync, .syncNote, .syncType: return []
        case .time: return [.flag_CanRamp, .flag_DisplayLogarithmic]
        case .feedback, .width, .mix: return [.flag_CanRamp]
        }
    }

    public var valueStrings: [String]? {
        switch self {
        case .mode: return DelayMode.allCases.map(\.displayName)
        case .sync: return ["Off", "On"]
        case .syncNote: return MyFXNoteLength.allCases.map(\.displayName)
        case .syncType: return MyFXNoteType.allCases.map(\.displayName)
        default: return nil
        }
    }

    public func clamped(_ value: Float) -> Float {
        guard value.isFinite else { return defaultValue }
        let inRange = min(max(value, range.lowerBound), range.upperBound)
        return isIndexed ? inRange.rounded() : inRange
    }

    public func displayString(for value: Float) -> String {
        switch self {
        case .mode, .sync, .syncNote, .syncType:
            return valueStrings?[Int(clamped(value))] ?? ""
        case .time:
            if value < 0.1 { return String(format: "%.1f ms", value * 1_000) }
            if value < 1 { return String(format: "%.0f ms", value * 1_000) }
            return String(format: "%.2f s", value)
        case .feedback, .width, .mix:
            return String(format: "%.0f%%", value)
        }
    }

    /// Parses what `displayString` produces. Time is in ms unless the text
    /// ends in "s" ("250", "250 ms", "1.5 s"); an indexed value by name or index.
    public func value(fromDisplayString string: String) -> Float? {
        let trimmed = string.trimmingCharacters(in: .whitespaces)
        if isIndexed {
            if let index = valueStrings?.firstIndex(where: { $0.lowercased() == trimmed.lowercased() }) {
                return Float(index)
            }
            return Float(trimmed).map(clamped)
        }
        let number = trimmed.prefix { "0123456789.-".contains($0) }
        guard var parsed = Float(number) else { return nil }
        if self == .time {
            let unit = trimmed.dropFirst(number.count).trimmingCharacters(in: .whitespaces).lowercased()
            if !unit.hasPrefix("s") { parsed /= 1_000 }
        }
        return clamped(parsed)
    }
}
