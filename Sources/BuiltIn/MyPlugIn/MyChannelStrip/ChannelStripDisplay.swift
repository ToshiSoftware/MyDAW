import Foundation
import SwiftUI

/// The editor's live readings beyond the IN/OUT meters: spectrum, gain
/// reduction, the compressor's input level and which bands are computing.
/// Polled 30 times a second while the editor is visible. Main thread only.
final class ChannelStripDisplayModel: ObservableObject {
    /// Half-octave levels (dB) with a +3 dB/oct tilt about 1 kHz, so pink
    /// noise reads flat.
    @Published var spectrum = [Float](repeating: ChannelStripDisplayModel.floor, count: ChannelStripSpectrum.bandCount)
    /// Gain reduction in dB (<= 0), recovering at 20 dB/s.
    @Published var reduction: Float = 0
    /// Compressor input level in dB, falling at 20 dB/s.
    @Published var detector: Float = ChannelStripDisplayModel.floor
    @Published var activeBands = 0
    @Published var sampleRate = 48_000.0

    static let floor: Float = -120
    private static let interval = 1.0 / 30
    /// 20 dB per second.
    private static let fall = Float(20 * interval)

    private weak var kernel: ChannelStripKernel?
    private let isVisible: () -> Bool
    private let analyser = ChannelStripSpectrum()
    private var timer: Timer?

    init(kernel: ChannelStripKernel, isVisible: @escaping () -> Bool) {
        self.kernel = kernel
        self.isVisible = isVisible
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit {
        timer?.invalidate()
        kernel?.isAnalysing = false
    }

    private func poll() {
        guard let kernel else { return }
        let visible = isVisible()
        kernel.isAnalysing = visible
        guard visible else { return }

        let readings = kernel.takeReadings()
        let reduction = min(readings.reduction, min(0, self.reduction + Self.fall))
        let level = readings.detector > 0 ? 20 * log10(readings.detector) : Self.floor
        let detector = max(level, max(Self.floor, self.detector - Self.fall))
        let rate = kernel.sampleRate
        let measured = analyser.bands(of: kernel.analysis, sampleRate: rate)
        var spectrum = self.spectrum
        for band in spectrum.indices {
            let tilt = Float(3 * log2(ChannelStripSpectrum.bandCentre(band) / 1_000))
            spectrum[band] = max(measured[band] + tilt, spectrum[band] - Self.fall)
        }

        // Publish only changes: an idle display costs no redraw.
        if reduction != self.reduction { self.reduction = reduction }
        if detector != self.detector { self.detector = detector }
        if readings.activeBands != activeBands { activeBands = readings.activeBands }
        if rate != sampleRate { sampleRate = rate }
        if spectrum != self.spectrum { self.spectrum = spectrum }
    }
}
