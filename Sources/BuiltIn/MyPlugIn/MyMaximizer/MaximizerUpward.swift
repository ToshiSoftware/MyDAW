import Foundation

/// UPWARD COMPRESS: an AGC that lifts what is quieter than -12 dBFS, by at
/// most `amount` dB, and backs off where the music is loud.
///
/// - Detector: the louder channel's peak, falling over 50 ms.
/// - Wanted boost: threshold minus level, from 0 up to `amount`.
/// - The boost drops with the limiter's ATTACK (loud music arrives: get out
///   of the way; 0 ms = at once) and rises over ten times its RELEASE
///   (slowly, so it does not pump). An overshoot during the drop is caught
///   by the limiter that follows.
/// - Below -60 dBFS (silence, a pause, the end of a fade) the boost is
///   held where it is rather than chased: noise is not lifted further, and
///   the music comes back with the boost it had.
///
/// Render thread only after `prepare`.
final class MaximizerUpward {
    static let threshold: Float = -12
    static let detectorFallSeconds = 0.05
    /// Release = this times the limiter's RELEASE.
    static let releaseFactor = 10.0
    /// Below this the boost is frozen.
    static let silence: Float = -60

    /// Current boost in dB (>= 0).
    private(set) var boost: Float = 0
    private var envelope: Float = 0
    private var detectorFall: Float = 0
    private var attackCoefficient: Float = 1
    private var releaseCoefficient: Float = 0
    private var attackMilliseconds: Float = -1
    private var releaseMilliseconds: Float = -1
    private var sampleRate = 48_000.0

    func prepare(sampleRate: Double) {
        self.sampleRate = sampleRate
        detectorFall = Float(exp(-1 / (Self.detectorFallSeconds * sampleRate)))
        attackMilliseconds = -1
        releaseMilliseconds = -1
        setTimes(attackMilliseconds: 0, releaseMilliseconds: 50)
        reset()
    }

    func reset() {
        boost = 0
        envelope = 0
    }

    /// The limiter's ATTACK and RELEASE (cheap when unchanged).
    func setTimes(attackMilliseconds attack: Float, releaseMilliseconds release: Float) {
        if attack != attackMilliseconds {
            attackMilliseconds = attack
            attackCoefficient = attack <= 0 ? 1 : Float(1 - exp(-1 / (Double(attack) / 1_000 * sampleRate)))
        }
        if release != releaseMilliseconds {
            releaseMilliseconds = release
            let seconds = Double(max(release, 0.01)) / 1_000 * Self.releaseFactor
            releaseCoefficient = Float(1 - exp(-1 / (seconds * sampleRate)))
        }
    }

    /// Whether `process` would leave the signal as it is: no amount and no
    /// boost left to release.
    @inline(__always)
    func isIdle(amount: Float) -> Bool {
        amount <= 0 && boost == 0
    }

    /// The gain (linear) for one frame whose louder channel is `level`.
    @inline(__always)
    func gain(level: Float, amount: Float) -> Float {
        envelope = max(level, envelope * detectorFall)
        let decibels = envelope > 1e-9 ? 20 * log10(envelope) : -180
        if decibels >= Self.silence || boost > amount {
            // (A lowered amount is followed even in silence.)
            let wanted = min(max(Self.threshold - decibels, 0), amount)
            boost += (wanted - boost) * (wanted < boost ? attackCoefficient : releaseCoefficient)
            // Settle exactly, so an amount of 0 dB stops costing anything.
            if wanted == 0 && boost < 1e-4 { boost = 0 }
        }
        return boost == 0 ? 1 : exp(boost * Float(M_LN10 / 20))
    }
}
