import Foundation
import SwiftUI

/// A readout that is easy to read: it jumps up to a new peak, holds it for
/// 1 s, then glides toward the current value with a 0.2 s time constant.
/// Values are magnitudes (>= 0).
struct MaximizerPeakHold: Equatable {
    static let holdSeconds = 1.0
    static let releaseSeconds = 0.2

    private(set) var value: Float = 0
    private var age = 0.0

    mutating func update(_ current: Float, interval: Double) {
        if current >= value {
            value = current
            age = 0
            return
        }
        age += interval
        guard age > Self.holdSeconds else { return }
        value += (current - value) * Float(1 - exp(-interval / Self.releaseSeconds))
        if abs(value - current) < 0.005 { value = current }
    }
}

/// The editor's live readings beyond the IN/OUT meters: the history
/// columns and the GR / UP readouts. Polled 30 times a second while the
/// editor is visible. Main thread only.
final class MaximizerDisplayModel: ObservableObject {
    /// The newest columns, oldest first (at most the ring's capacity).
    @Published private(set) var columns: [MaximizerColumn] = []
    /// The kernel's number for `columns[0]` (columns are numbered from the
    /// first one written), so merged points always group the same columns.
    private(set) var firstIndex = 0
    /// Gain reduction in dB (<= 0), peak-held (`MaximizerPeakHold`).
    @Published private(set) var reduction: Float = 0
    /// UPWARD boost in dB, peak-held.
    @Published private(set) var boost: Float = 0
    @Published private(set) var latencyMilliseconds = 10.0
    /// Index into `MaximizerHistory.spans` (a view setting, not saved).
    @Published var spanIndex = 1

    private static let interval = 1.0 / 30

    private weak var kernel: MaximizerKernel?
    private let isVisible: () -> Bool
    private var readCount = 0
    private var reductionHold = MaximizerPeakHold()
    private var boostHold = MaximizerPeakHold()
    private var timer: Timer?

    init(kernel: MaximizerKernel, isVisible: @escaping () -> Bool) {
        self.kernel = kernel
        self.isVisible = isVisible
        // The past seconds show at once when the editor opens.
        readHistory(kernel)
        let readings = kernel.takeReadings()
        reductionHold.update(-readings.reduction, interval: Self.interval)
        boostHold.update(readings.boost, interval: Self.interval)
        reduction = -reductionHold.value
        boost = boostHold.value
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit {
        timer?.invalidate()
    }

    var span: Double { MaximizerHistory.spans[spanIndex] }

    func nextSpan() {
        spanIndex = (spanIndex + 1) % MaximizerHistory.spans.count
    }

    private func poll() {
        guard let kernel, isVisible() else { return }
        let readings = kernel.takeReadings()
        reductionHold.update(-readings.reduction, interval: Self.interval)
        boostHold.update(readings.boost, interval: Self.interval)
        let reduction = -reductionHold.value
        let boost = boostHold.value
        let latency = Double(kernel.latencySamples) / kernel.sampleRate * 1_000

        readHistory(kernel)
        // Publish only changes: an idle display costs no redraw.
        if reduction != self.reduction { self.reduction = reduction }
        if boost != self.boost { self.boost = boost }
        if abs(latency - latencyMilliseconds) > 0.01 { latencyMilliseconds = latency }
    }

    private func readHistory(_ kernel: MaximizerKernel) {
        let (newColumns, count) = kernel.history.read(since: readCount)
        defer { readCount = count }
        guard !newColumns.isEmpty else { return }
        var columns = self.columns
        var firstIndex = self.firstIndex
        let newFirst = count - newColumns.count
        if newFirst != firstIndex + columns.count {
            // Fell behind the ring (or first read): start over from what it has.
            columns = []
            firstIndex = newFirst
        }
        columns.append(contentsOf: newColumns)
        if columns.count > MaximizerHistory.capacity {
            let dropped = columns.count - MaximizerHistory.capacity
            columns.removeFirst(dropped)
            firstIndex += dropped
        }
        self.firstIndex = firstIndex
        self.columns = columns
    }
}
