import Foundation

/// One blue dot on a track's volume automation line. `level` is the dot's
/// height (see `VolumeAutomationScale`), so the file never has to hold an
/// infinite number of decibels.
public struct VolumeAutomationPoint: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var time: Double
    public var level: Double

    public init(id: UUID = UUID(), time: Double, level: Double) {
        self.id = id
        self.time = time
        self.level = level
    }
}

/// What has a volume automation line: a track, or the master.
@MainActor
public protocol VolumeAutomationOwner: ObservableObject {
    var isVolumeAutomationEnabled: Bool { get set }
    var volumeAutomation: [VolumeAutomationPoint] { get set }
}

extension AudioTrack: VolumeAutomationOwner {}

/// The master's line (see `AudioEngineManager.masterAutomation`).
@MainActor
public final class MasterVolumeAutomation: ObservableObject, VolumeAutomationOwner {
    @Published public var isVolumeAutomationEnabled = false
    @Published public var volumeAutomation: [VolumeAutomationPoint] = []

    public init() {}
}

/// The automation lane's vertical scale. Level 1 is the top of the lane
/// (+12 dB) and level 0 its bottom (-∞). Decibels are linear from +12 down to
/// -60 dB; the short band below that fades to silence. Dots are joined
/// straight in level, so what the line shows is what is heard.
public enum VolumeAutomationScale {
    public static let maximumDB = 12.0
    private static let floorDB = -60.0
    private static let silenceBand = 0.06
    private static let floorGain = 0.001 // -60 dB
    /// Numeric entries at or below this mean silence.
    private static let silenceDB = -120.0

    public static let unityLevel = level(forDB: 0.0)

    public static func clamped(_ level: Double) -> Double {
        min(1.0, max(0.0, level))
    }

    public static func gain(forLevel level: Double) -> Double {
        let level = clamped(level)
        guard level >= silenceBand else { return floorGain * level / silenceBand }
        let fraction = (level - silenceBand) / (1.0 - silenceBand)
        return pow(10.0, (floorDB + fraction * (maximumDB - floorDB)) / 20.0)
    }

    public static func level(forDB db: Double) -> Double {
        guard db > silenceDB else { return 0.0 }
        if db < floorDB {
            return silenceBand * pow(10.0, db / 20.0) / floorGain
        }
        let fraction = (min(db, maximumDB) - floorDB) / (maximumDB - floorDB)
        return silenceBand + fraction * (1.0 - silenceBand)
    }

    /// "+3.2 dB", "0.0 dB", "-∞ dB".
    public static func text(forLevel level: Double) -> String {
        guard clamped(level) > 0.0 else { return "-∞ dB" }
        let db = 20.0 * log10(gain(forLevel: level))
        let rounded = (db * 10.0).rounded() / 10.0
        return String(format: rounded > 0 ? "+%.1f dB" : "%.1f dB", rounded == 0 ? 0.0 : rounded)
    }

    /// The field's text as a level; nil when it is no value within the range.
    /// "-inf" and "-∞" mean silence.
    public static func level(parsing text: String) -> Double? {
        let cleaned = text.lowercased()
            .replacingOccurrences(of: "db", with: "")
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        if ["-inf", "-∞", "inf", "∞"].contains(cleaned) { return 0.0 }
        guard let db = Double(cleaned), db.isFinite, db <= maximumDB else { return nil }
        return level(forDB: db)
    }

    /// The line's height at `time`: level held before the first dot and after
    /// the last. Without dots the line lies at 0 dB. Also used on the render
    /// thread: it neither allocates nor locks.
    public static func level(at time: Double, in points: UnsafeBufferPointer<VolumeAutomationPoint>) -> Double {
        guard let first = points.first, let last = points.last else { return unityLevel }
        if time <= first.time { return first.level }
        if time >= last.time { return last.level }
        var low = 0
        var high = points.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if points[middle].time <= time {
                low = middle
            } else {
                high = middle
            }
        }
        let span = points[high].time - points[low].time
        guard span > 0.0 else { return points[high].level }
        return points[low].level + (points[high].level - points[low].level) * (time - points[low].time) / span
    }

    public static func level(at time: Double, in points: [VolumeAutomationPoint]) -> Double {
        points.withUnsafeBufferPointer { level(at: time, in: $0) }
    }
}
