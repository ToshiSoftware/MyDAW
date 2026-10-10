import Foundation

/// The LFO of both modes (Docs/MyChorusPan.md §3.1): a phase from 0 to 1,
/// advanced each sample, and four shapes from -1 to +1. A value type, so the
/// render loop keeps it in a local.
struct ChorusPanLFO {
    /// Phase, 0 ..< 1.
    private(set) var phase = 0.0
    /// Speed in Hz, smoothed toward the target (no jump when SPEED moves).
    private(set) var speed = 1.0
    private var speedCoefficient = 0.0
    private var sampleRate = 48_000.0

    init() {}

    init(sampleRate: Double, speed: Double, smoothingSeconds: Double) {
        self.sampleRate = sampleRate
        self.speed = speed
        speedCoefficient = 1 - exp(-1 / (smoothingSeconds * sampleRate))
    }

    mutating func reset(speed: Double) {
        phase = 0
        self.speed = speed
    }

    /// Sets the speed at once (a mode change, where the effect is silent);
    /// the phase goes on.
    mutating func jump(speed: Double) {
        self.speed = speed
    }

    /// Advances one sample toward `targetSpeed`; the phase stays continuous.
    @inline(__always)
    mutating func advance(targetSpeed: Double) {
        speed += (targetSpeed - speed) * speedCoefficient
        phase += speed / sampleRate
        if phase >= 1 { phase -= 1 }
    }

    /// The raw shape at `phase` (any real number; only its fraction counts).
    /// Sine and Triangle start at 0 rising; Saw rises from -1 and drops back;
    /// Square is +1 for the first half. Corners are smoothed by the caller.
    @inline(__always)
    static func value(_ wave: ChorusPanWave, at phase: Double) -> Float {
        let p = phase - floor(phase)
        switch wave {
        case .sine:
            return Float(sin(2 * Double.pi * p))
        case .triangle:
            if p < 0.25 { return Float(4 * p) }
            if p < 0.75 { return Float(2 - 4 * p) }
            return Float(4 * p - 4)
        case .saw:
            return Float(2 * p - 1)
        case .square:
            return p < 0.5 ? 1 : -1
        }
    }
}

/// Smoothing of an LFO output, so Saw's drop and Square's edges do not jump
/// (a delay time or gain jump clicks). Two one-poles in a row: the output
/// moves in an S-curve whose slope is continuous too (one pole alone starts
/// moving at full speed, a corner in the delay time that the read-back
/// turns into a click). Short enough to leave Sine and Triangle all but
/// unchanged at LFO rates (2 ms each: -0.13 dB and about 4 ms late at 10 Hz).
struct ChorusPanCornerSmoother {
    private var first: Float = 0
    private var second: Float = 0
    private var coefficient: Float = 1

    init() {}

    init(sampleRate: Double, seconds: Double) {
        coefficient = Float(1 - exp(-1 / (seconds * sampleRate)))
    }

    mutating func reset(to value: Float) {
        first = value
        second = value
    }

    @inline(__always)
    mutating func process(_ value: Float) -> Float {
        first += (value - first) * coefficient
        second += (first - second) * coefficient
        return second
    }
}
