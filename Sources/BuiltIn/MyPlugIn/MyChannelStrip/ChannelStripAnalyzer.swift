import Accelerate
import Foundation

/// The EQ output as the spectrum display reads it: a ring the render thread
/// writes and the editor copies from. The write position is one aligned
/// word; a copy racing the writer may mix old and new samples, which only
/// blurs one display frame.
public final class ChannelStripAnalysisRing {
    public static let capacity = 8_192
    private let samples = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
    private let writePosition = UnsafeMutablePointer<Int>.allocate(capacity: 1)

    public init() {
        samples.initialize(repeating: 0, count: Self.capacity)
        writePosition.initialize(to: 0)
    }

    deinit {
        samples.deallocate()
        writePosition.deallocate()
    }

    /// Render thread: the mono sum of a chunk.
    @inline(__always)
    func write(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>?, _ count: Int) {
        var position = writePosition.pointee
        for i in 0..<count {
            samples[position] = right.map { 0.5 * (left[i] + $0[i]) } ?? left[i]
            position = (position + 1) & (Self.capacity - 1)
        }
        writePosition.pointee = position
    }

    /// The latest `count` samples, oldest first.
    public func copyLatest(into destination: UnsafeMutablePointer<Float>, count: Int) {
        let end = writePosition.pointee
        for i in 0..<count {
            destination[i] = samples[(end - count + i) & (Self.capacity - 1)]
        }
    }
}

/// Half-octave band levels from 20 Hz to 20 kHz by FFT (Hann window).
public final class ChannelStripSpectrum {
    public static let size = 4_096
    public static let bandCount = 20
    public static let lowestFrequency = 20.0

    /// Lower edge of band `index` (its upper edge is the next band's lower).
    public static func bandEdge(_ index: Int) -> Double {
        lowestFrequency * pow(2, Double(index) / 2)
    }

    public static func bandCentre(_ index: Int) -> Double {
        lowestFrequency * pow(2, (Double(index) + 0.5) / 2)
    }

    private let log2Size = vDSP_Length(12)
    private let setup: FFTSetup
    private var window = [Float](repeating: 0, count: size)
    private var buffer = [Float](repeating: 0, count: size)
    private var real = [Float](repeating: 0, count: size / 2)
    private var imaginary = [Float](repeating: 0, count: size / 2)
    private var power = [Float](repeating: 0, count: size / 2)

    public init() {
        setup = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2))!
        vDSP_hann_window(&window, vDSP_Length(Self.size), Int32(vDSP_HANN_DENORM))
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// Band levels in dB, where a full-scale sine reads about 0 dB in its band.
    public func bands(of ring: ChannelStripAnalysisRing, sampleRate: Double) -> [Float] {
        buffer.withUnsafeMutableBufferPointer { ring.copyLatest(into: $0.baseAddress!, count: Self.size) }
        return bands(sampleRate: sampleRate)
    }

    public func bands(of samples: [Float], sampleRate: Double) -> [Float] {
        for i in 0..<Self.size { buffer[i] = i < samples.count ? samples[samples.count - Self.size + i] : 0 }
        return bands(sampleRate: sampleRate)
    }

    private func bands(sampleRate: Double) -> [Float] {
        let n = Self.size
        vDSP_vmul(buffer, 1, window, 1, &buffer, 1, vDSP_Length(n))
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                buffer.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2Size, FFTDirection(FFT_FORWARD))
                // Bin 0 packs DC and Nyquist; neither is shown.
                split.imagp[0] = 0
                split.realp[0] = 0
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
            }
        }
        // zrip doubles the transform; a Hann-windowed sine of amplitude 1
        // spreads (N/4)^2 x 1.5 over its bins, x 4 for the doubling.
        let scale = 1 / (Float(n * n) / 16 * 1.5 * 4)
        let binWidth = sampleRate / Double(n)
        var levels = [Float](repeating: -120, count: Self.bandCount)
        for band in 0..<Self.bandCount {
            let low = Self.bandEdge(band)
            let high = Self.bandEdge(band + 1)
            var first = Int((low / binWidth).rounded(.up))
            var last = Int((high / binWidth).rounded(.up)) - 1
            if last < first {
                // Narrower than a bin: the nearest one.
                first = Int((Self.bandCentre(band) / binWidth).rounded())
                last = first
            }
            first = max(first, 1)
            last = min(last, n / 2 - 1)
            guard first <= last else { continue }
            var sum: Float = 0
            for bin in first...last { sum += power[bin] }
            levels[band] = 10 * log10(max(sum * scale, 1e-12))
        }
        return levels
    }
}
