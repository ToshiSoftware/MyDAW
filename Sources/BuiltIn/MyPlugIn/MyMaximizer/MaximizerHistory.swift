import Foundation

/// One slice of the history graph.
public struct MaximizerColumn: Equatable, Sendable {
    /// Output peak (linear).
    public var peak: Float
    /// Deepest limiter gain reduction in dB (<= 0).
    public var reduction: Float
    /// Mean UPWARD boost in dB (>= 0).
    public var boost: Float
    public var isBypassed: Bool

    public init(peak: Float = 0, reduction: Float = 0, boost: Float = 0, isBypassed: Bool = false) {
        self.peak = peak
        self.reduction = reduction
        self.boost = boost
        self.isBypassed = isBypassed
    }
}

/// The graph's time base: the shortest view (3 s) spans `viewColumns`
/// columns; 6 s and 12 s views merge 2 and 4 columns into one.
public enum MaximizerHistory {
    public static let viewColumns = 284
    public static let spans: [Double] = [3, 6, 12]
    public static let capacity = 1_200

    static func columnFrames(sampleRate: Double) -> Int {
        max(1, Int((sampleRate * spans[0] / Double(viewColumns)).rounded()))
    }
}

/// Columns written on the render thread and read by the editor, without
/// locks: each value is one aligned word, and the count moves on only after
/// a column is complete. A reader that falls more than `capacity` behind
/// loses the oldest columns.
public final class MaximizerHistoryRing {
    private static let fields = 4
    private let values: UnsafeMutablePointer<Float>
    private let written: UnsafeMutablePointer<Int>

    public init() {
        values = .allocate(capacity: MaximizerHistory.capacity * Self.fields)
        values.initialize(repeating: 0, count: MaximizerHistory.capacity * Self.fields)
        written = .allocate(capacity: 1)
        written.initialize(to: 0)
    }

    deinit {
        values.deallocate()
        written.deallocate()
    }

    /// Columns written so far.
    public var count: Int { written.pointee }

    /// Render thread.
    @inline(__always)
    func write(_ column: MaximizerColumn) {
        let count = written.pointee
        let base = (count % MaximizerHistory.capacity) * Self.fields
        values[base] = column.peak
        values[base + 1] = column.reduction
        values[base + 2] = column.boost
        values[base + 3] = column.isBypassed ? 1 : 0
        written.pointee = count + 1
    }

    /// The columns after the first `since`, oldest first, and the count to
    /// pass next time.
    public func read(since: Int) -> (columns: [MaximizerColumn], count: Int) {
        let count = written.pointee
        let first = max(since, count - MaximizerHistory.capacity + 1)
        guard first < count else { return ([], count) }
        var columns: [MaximizerColumn] = []
        columns.reserveCapacity(count - first)
        for index in first..<count {
            let base = (index % MaximizerHistory.capacity) * Self.fields
            columns.append(MaximizerColumn(peak: values[base], reduction: values[base + 1],
                                           boost: values[base + 2], isBypassed: values[base + 3] >= 0.5))
        }
        return (columns, count)
    }
}

/// Gathers frames into columns (render thread).
struct MaximizerColumnBuilder {
    var frames = 0
    var length = 1
    var peak: Float = 0
    var lowestGain: Float = 1
    var boostSum: Float = 0
    var bypassedFrames = 0

    mutating func reset(length: Int) {
        self.length = length
        frames = 0
        peak = 0
        lowestGain = 1
        boostSum = 0
        bypassedFrames = 0
    }

    /// Adds a frame; returns the column when it is complete.
    @inline(__always)
    mutating func add(peak framePeak: Float, gain: Float, boost: Float, bypassed: Bool) -> MaximizerColumn? {
        peak = max(peak, framePeak)
        lowestGain = min(lowestGain, gain)
        boostSum += boost
        if bypassed { bypassedFrames += 1 }
        frames += 1
        guard frames >= length else { return nil }
        let column = MaximizerColumn(
            peak: peak,
            reduction: lowestGain < 1 ? 20 * log10(lowestGain) : 0,
            boost: boostSum / Float(frames),
            isBypassed: bypassedFrames * 2 > frames
        )
        reset(length: length)
        return column
    }
}
