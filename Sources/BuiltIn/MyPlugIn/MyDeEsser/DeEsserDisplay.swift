import Foundation
import SwiftUI
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

/// Gain reduction with the level meters' ballistics: it jumps to a deeper
/// reduction at once and falls back at about 20 dB/s, as the IN/OUT bars
/// do (MyFXMeterState). Values are magnitudes in dB (>= 0).
struct DeEsserFallingReading: Equatable {
    static let fallDecibelsPerSecond: Float = 20

    private(set) var value: Float = 0

    mutating func update(_ current: Float, interval: Double) {
        value = max(current, value - Self.fallDecibelsPerSecond * Float(interval))
    }
}

/// The editor's live readings beyond the IN/OUT meters: the SIB meter, the
/// GR meter and the gain the band graph draws. Polled 30 times a second
/// while the editor is visible. Main thread only.
final class DeEsserDisplayModel: ObservableObject {
    /// High-band level per channel, as a meter (falls, holds, maximum).
    @Published var sibilance = MyFXMeterState()
    /// Gain reduction per channel in dB (<= 0), falling like the level meters.
    @Published private(set) var reductionLeft: Float = 0
    @Published private(set) var reductionRight: Float = 0
    /// Deepest reduction since the readout was last clicked (dB, <= 0).
    @Published private(set) var maximumReduction: Float = 0
    @Published private(set) var isBypassed = false
    @Published private(set) var sampleRate = 48_000.0

    private static let interval = 1.0 / 30

    private weak var kernel: DeEsserKernel?
    private let isVisible: () -> Bool
    private var fallingLeft = DeEsserFallingReading()
    private var fallingRight = DeEsserFallingReading()
    private var timer: Timer?

    init(kernel: DeEsserKernel, isVisible: @escaping () -> Bool) {
        self.kernel = kernel
        self.isVisible = isVisible
        sampleRate = kernel.sampleRate
        _ = kernel.takeReadings()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit {
        timer?.invalidate()
    }

    /// The deeper of the two reductions as a gain, for the band graph.
    var graphGain: Double {
        pow(10, Double(min(reductionLeft, reductionRight)) / 20)
    }

    func clearSibilance() {
        sibilance.clearPeaks()
    }

    func clearReduction() {
        maximumReduction = 0
    }

    /// Takes the kernel's readings (also used by snapshots).
    func update(_ readings: DeEsserReadings) {
        var sibilance = self.sibilance
        sibilance.update(left: readings.sibilanceLeft, right: readings.sibilanceRight, interval: Self.interval)
        fallingLeft.update(-readings.reductionLeft, interval: Self.interval)
        fallingRight.update(-readings.reductionRight, interval: Self.interval)
        let reductionLeft = -fallingLeft.value
        let reductionRight = -fallingRight.value
        let maximum = min(maximumReduction, readings.reductionLeft, readings.reductionRight)
        // Publish only changes: an idle display costs no redraw.
        if sibilance != self.sibilance { self.sibilance = sibilance }
        if reductionLeft != self.reductionLeft { self.reductionLeft = reductionLeft }
        if reductionRight != self.reductionRight { self.reductionRight = reductionRight }
        if maximum != maximumReduction { maximumReduction = maximum }
    }

    private func poll() {
        guard let kernel, isVisible() else { return }
        update(kernel.takeReadings())
        if kernel.isBypassed != isBypassed { isBypassed = kernel.isBypassed }
        if kernel.sampleRate != sampleRate { sampleRate = kernel.sampleRate }
    }
}
