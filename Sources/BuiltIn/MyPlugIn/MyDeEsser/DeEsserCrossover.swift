import Foundation

/// Coefficients of a 2nd-order Butterworth (Q = 1/√2) state variable filter
/// in the TPT form (Zavalishin / Simper): pre-warped to the exact cutoff,
/// and stable while the cutoff moves, so FREQ can glide sample by sample.
struct DeEsserFilterCoefficients {
    static let damping = 2.0.squareRoot() // 1 / Q

    var a1 = 1.0
    var a2 = 0.0
    var a3 = 0.0

    init() {}

    init(frequency: Double, sampleRate: Double) {
        let g = tan(Double.pi * min(frequency, sampleRate * 0.49) / sampleRate)
        a1 = 1 / (1 + g * (g + Self.damping))
        a2 = g * a1
        a3 = g * a2
    }
}

/// One state variable filter stage: low-pass and high-pass of the same input.
struct DeEsserFilterStage {
    private var ic1 = 0.0
    private var ic2 = 0.0

    mutating func reset() {
        ic1 = 0
        ic2 = 0
    }

    @inline(__always)
    mutating func process(_ x: Double, _ c: DeEsserFilterCoefficients) -> (low: Double, high: Double) {
        let v3 = x - ic2
        let v1 = c.a1 * ic1 + c.a2 * v3
        let v2 = ic2 + c.a2 * ic1 + c.a3 * v3
        ic1 = 2 * v1 - ic1
        ic2 = 2 * v2 - ic2
        return (v2, x - DeEsserFilterCoefficients.damping * v1 - v2)
    }
}

/// A Linkwitz-Riley 4th-order (24 dB/oct) crossover for one channel: the
/// first stage splits, a second low-pass and a second high-pass finish
/// each band. The bands are in phase at every frequency and |L| + |H| = 1,
/// so L + g·H dips smoothly above the crossover with no bump near it, and
/// L + H is flat (an all-pass).
struct DeEsserCrossover {
    private var split = DeEsserFilterStage()
    private var low = DeEsserFilterStage()
    private var high = DeEsserFilterStage()

    mutating func reset() {
        split.reset()
        low.reset()
        high.reset()
    }

    @inline(__always)
    mutating func process(_ x: Double, _ c: DeEsserFilterCoefficients) -> (low: Double, high: Double) {
        let first = split.process(x, c)
        return (low.process(first.low, c).low, high.process(first.high, c).high)
    }

    /// |L + g·H| at `frequency` for a crossover at `crossover`: (1 + g·r⁴) / (1 + r⁴)
    /// with the bilinear transform's frequency warping, as the filters run.
    static func response(at frequency: Double, crossover: Double, gain: Double, sampleRate: Double) -> Double {
        let nyquist = sampleRate * 0.4999
        let r = tan(Double.pi * min(frequency, nyquist) / sampleRate)
            / tan(Double.pi * min(crossover, sampleRate * 0.49) / sampleRate)
        let r4 = r * r * r * r
        return (1 + gain * r4) / (1 + r4)
    }
}
