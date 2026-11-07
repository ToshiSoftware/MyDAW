import Foundation

/// The compressor's static curve (soft knee, Giannoulis / Massberg / Reiss
/// 2012), shared by the kernel and the editor's transfer curve.
public enum ChannelStripCompressorCurve {
    /// Output level in dB for an input level `x` in dB, before makeup.
    @inline(__always)
    public static func output(_ x: Float, threshold: Float, ratio: Float, knee: Float) -> Float {
        let slope = 1 / ratio - 1
        let overshoot = x - threshold
        if 2 * overshoot < -knee { return x }
        if knee > 0 && 2 * abs(overshoot) <= knee {
            let into = overshoot + knee / 2
            return x + slope * into * into / (2 * knee)
        }
        return threshold + overshoot / ratio
    }

    /// The makeup AUTO adds: half the reduction a 0 dB input would get.
    public static func autoMakeup(threshold: Float, ratio: Float) -> Float {
        -threshold * (1 - 1 / ratio) / 2
    }
}

/// The compressor's settings for one chunk.
struct ChannelStripCompressorSettings {
    var isOn: Bool
    var threshold: Float
    var ratio: Float
    var knee: Float
    var attackSeconds: Float
    var releaseSeconds: Float
    /// Makeup in dB, AUTO included.
    var makeup: Float
    var isLinked: Bool
    var mix: Float
}

/// Feed-forward compressor working in dB. The gain reduction follows the
/// static curve through attack/release smoothing; ON/OFF fades over 10 ms,
/// and once off it computes nothing but the level the editor shows.
final class ChannelStripCompressor {
    private var sampleRate = 48_000.0
    private var smoothing: Float = 0
    private var fadeStep: Float = 0
    private var attack: (seconds: Float, coefficient: Float) = (0, 0)
    private var release: (seconds: Float, coefficient: Float) = (0, 0)

    /// Gain reduction (dB, <= 0) per channel.
    private var envelopeLeft: Float = 0
    private var envelopeRight: Float = 0
    /// 0 off ... 1 on.
    private var amount: Float = 0
    private var mix: Float = 1
    private var makeup: Float = 0

    /// Of the last `process` call (render thread): the deepest gain
    /// reduction (dB) and the highest detector input (linear).
    private(set) var deepestReduction: Float = 0
    private(set) var detectorPeak: Float = 0

    func prepare(sampleRate: Double, smoothingSeconds: Double, fadeSeconds: Double) {
        self.sampleRate = sampleRate
        smoothing = Float(1 - exp(-1 / (smoothingSeconds * sampleRate)))
        fadeStep = Float(1 / (fadeSeconds * sampleRate))
        attack = (0, 0)
        release = (0, 0)
    }

    func reset(_ settings: ChannelStripCompressorSettings) {
        clearState()
        amount = settings.isOn ? 1 : 0
        mix = settings.mix
        makeup = settings.makeup
    }

    /// Forgets the envelope (order changes, resets).
    func clearState() {
        envelopeLeft = 0
        envelopeRight = 0
    }

    var isActive: Bool { amount > 0 }

    /// Compresses one chunk in place.
    func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>?, _ count: Int,
                 _ settings: ChannelStripCompressorSettings) {
        if !settings.isOn && amount == 0 {
            // Off: only the level for the editor's marker.
            var peak: Float = 0
            for i in 0..<count { peak = max(peak, abs(left[i])) }
            if let right { for i in 0..<count { peak = max(peak, abs(right[i])) } }
            detectorPeak = peak
            deepestReduction = 0
            return
        }

        if attack.seconds != settings.attackSeconds {
            attack = (settings.attackSeconds, Float(exp(-1 / (Double(settings.attackSeconds) * sampleRate))))
        }
        if release.seconds != settings.releaseSeconds {
            release = (settings.releaseSeconds, Float(exp(-1 / (Double(settings.releaseSeconds) * sampleRate))))
        }
        let attackCoefficient = attack.coefficient
        let releaseCoefficient = release.coefficient
        let threshold = settings.threshold
        let ratio = settings.ratio
        let knee = settings.knee
        let linked = settings.isLinked || right == nil
        let fadeTarget: Float = settings.isOn ? 1 : 0
        var peak: Float = 0
        var deepest: Float = 0
        var envelopeLeft = self.envelopeLeft
        var envelopeRight = self.envelopeRight
        var amount = self.amount
        var mix = self.mix
        var makeup = self.makeup

        @inline(__always)
        func follow(_ envelope: Float, _ level: Float) -> Float {
            let x = 20 * log10(max(level, 1e-6))
            let reduction = ChannelStripCompressorCurve.output(x, threshold: threshold, ratio: ratio, knee: knee) - x
            // Attack while the reduction deepens, release while it recovers.
            let coefficient = reduction < envelope ? attackCoefficient : releaseCoefficient
            return reduction + coefficient * (envelope - reduction)
        }

        for i in 0..<count {
            amount = fadeTarget > amount ? min(fadeTarget, amount + fadeStep) : max(fadeTarget, amount - fadeStep)
            mix += (settings.mix - mix) * smoothing
            makeup += (settings.makeup - makeup) * smoothing
            let dryLeft = left[i]
            let dryRight = right?[i] ?? dryLeft
            let levelLeft = abs(dryLeft)
            let levelRight = abs(dryRight)
            peak = max(peak, max(levelLeft, levelRight))
            if linked {
                envelopeLeft = follow(envelopeLeft, max(levelLeft, levelRight))
                envelopeRight = envelopeLeft
            } else {
                envelopeLeft = follow(envelopeLeft, levelLeft)
                envelopeRight = follow(envelopeRight, levelRight)
            }
            deepest = min(deepest, min(envelopeLeft, envelopeRight) * amount)
            let wet = amount * mix
            let gainLeft = pow(10, (envelopeLeft + makeup) / 20)
            left[i] = dryLeft + wet * (dryLeft * gainLeft - dryLeft)
            if let right {
                let gainRight = linked ? gainLeft : pow(10, (envelopeRight + makeup) / 20)
                right[i] = dryRight + wet * (dryRight * gainRight - dryRight)
            }
        }

        if amount == 0 {
            envelopeLeft = 0
            envelopeRight = 0
        }
        self.envelopeLeft = envelopeLeft
        self.envelopeRight = envelopeRight
        self.amount = amount
        self.mix = mix
        self.makeup = makeup
        detectorPeak = peak
        deepestReduction = deepest
    }
}
