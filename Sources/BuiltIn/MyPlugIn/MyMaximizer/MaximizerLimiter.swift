import Foundation

/// The limiter, stereo linked, with a fixed look-ahead of D samples (10 ms,
/// the longest ATTACK) and an ATTACK of A samples (0...D):
///
///     wanted gain  g = soft knee from THRESHOLD to the ceiling   per frame
///     hold         minimum of g over frames t-D ... t-D+A
///     release      rises back toward the hold (RELEASE), drops at once
///     smooth       mean over the last A+1 frames (a straight ramp of A)
///     output       the frame from D frames ago, times the smoothed gain
///
/// Soft knee (`curve`): peaks up to THRESHOLD pass; above it they are
/// pressed smoothly toward the ceiling, which they approach but never
/// reach. With THRESHOLD at the ceiling it is a plain brickwall.
///
/// Every value the mean takes in is at most the wanted gain of the frame
/// being output, so the ramp ends exactly at the peak and the output never
/// exceeds the ceiling. ATTACK 0 changes the gain right at the peak.
/// The look-ahead stays D whatever the ATTACK, so the latency the host
/// compensates for never changes. A final clip at the ceiling only catches
/// rounding (and a moment after ATTACK is lengthened); `safetyClips` counts it.
///
/// Render thread only after `prepare`.
final class MaximizerLimiter {
    static let lookAheadSeconds = 0.01
    static let margin: Float = 0.999_99

    private(set) var lookAhead = 0
    /// ATTACK in frames (0 ... lookAhead).
    private(set) var attack = 0
    /// Current gain reduction as a gain (<= 1).
    private(set) var gain: Float = 1
    private(set) var safetyClips = 0

    /// Ring size: D + 1 frames; the frame at `time` sits at `time % size`.
    private var size = 1
    private var index = 0
    private var time = 0
    // Rings over the last D+1 frames: the audio and the ceiling it is
    // limited to, the wanted gains, and the released gains.
    private var delayLeft: [Float] = [0]
    private var delayRight: [Float] = [0]
    private var delayCeiling: [Float] = [1]
    private var wantedRing: [Float] = [1]
    private var releasedRing: [Double] = [1]
    // Sliding minimum over the hold window (monotonic deque).
    private var dequeValues: [Float] = [1]
    private var dequeTimes: [Int] = [0]
    private var dequeHead = 0
    private var dequeCount = 0
    // Release and smoothing.
    private var released: Float = 1
    private var releaseCoefficient: Float = 1
    private var releaseMilliseconds: Float = -1
    private var smoothSum = 1.0
    private var sampleRate = 48_000.0

    func prepare(sampleRate: Double) {
        self.sampleRate = sampleRate
        lookAhead = Self.lookAhead(sampleRate: sampleRate)
        size = lookAhead + 1
        delayLeft = [Float](repeating: 0, count: size)
        delayRight = [Float](repeating: 0, count: size)
        delayCeiling = [Float](repeating: 1, count: size)
        wantedRing = [Float](repeating: 1, count: size)
        releasedRing = [Double](repeating: 1, count: size)
        dequeValues = [Float](repeating: 1, count: size)
        dequeTimes = [Int](repeating: 0, count: size)
        releaseMilliseconds = -1
        attack = min(attack, lookAhead)
        reset()
    }

    /// Output peak (dB) for input peak `x` (dB): unchanged up to `threshold`,
    /// then bending (slope 1 at the knee, no corner) toward `ceiling`.
    static func curve(_ x: Float, threshold: Float, ceiling: Float) -> Float {
        let threshold = min(threshold, ceiling)
        guard x > threshold else { return x }
        let gap = ceiling - threshold
        guard gap > 1e-3 else { return ceiling }
        return threshold + gap * (1 - exp(-(x - threshold) / gap))
    }

    static func lookAhead(sampleRate: Double) -> Int {
        max(1, Int((lookAheadSeconds * sampleRate).rounded()))
    }

    func reset() {
        for slot in 0..<size {
            delayLeft[slot] = 0
            delayRight[slot] = 0
            delayCeiling[slot] = 1
            wantedRing[slot] = 1
            releasedRing[slot] = 1
        }
        index = 0
        time = 0
        dequeHead = 0
        dequeCount = 0
        released = 1
        smoothSum = Double(attack + 1)
        gain = 1
    }

    /// RELEASE in ms (cheap when unchanged).
    func setRelease(milliseconds: Float) {
        guard milliseconds != releaseMilliseconds else { return }
        releaseMilliseconds = milliseconds
        releaseCoefficient = Float(1 - exp(-1 / (Double(max(milliseconds, 0.01)) / 1_000 * sampleRate)))
    }

    /// ATTACK in ms (0 ... the look-ahead). A change rebuilds the hold and
    /// the mean from the rings, so it takes effect at once.
    func setAttack(milliseconds: Float) {
        let frames = min(max(Int((Double(milliseconds) / 1_000 * sampleRate).rounded()), 0), lookAhead)
        guard frames != attack else { return }
        attack = frames
        // The hold window of the last frame: times last-D ... last-D+A.
        dequeHead = 0
        dequeCount = 0
        let last = time - 1
        let first = max(0, last - lookAhead)
        let end = last - lookAhead + attack
        if end >= first {
            for frameTime in first...end { push(wantedRing[frameTime % size], at: frameTime) }
        }
        smoothSum = 0
        for back in 0...attack { smoothSum += releasedRing[Self.slot(last - back, size)] }
    }

    @inline(__always)
    private static func slot(_ frameTime: Int, _ size: Int) -> Int {
        (frameTime % size + size) % size
    }

    @inline(__always)
    private func push(_ value: Float, at frameTime: Int) {
        while dequeCount > 0 {
            let lastSlot = (dequeHead + dequeCount - 1) % size
            guard dequeValues[lastSlot] >= value else { break }
            dequeCount -= 1
        }
        let slot = (dequeHead + dequeCount) % size
        dequeValues[slot] = value
        dequeTimes[slot] = frameTime
        dequeCount += 1
    }

    /// Takes one frame in and gives back the frame from `lookAhead` frames
    /// ago, limited to the ceiling it came in with. `threshold` and
    /// `ceiling` are linear; a threshold above the ceiling counts as the
    /// ceiling.
    @inline(__always)
    func process(_ left: inout Float, _ right: inout Float, ceiling: Float, threshold: Float) {
        let peak = max(abs(left), abs(right))
        // A hair under the ceiling (0.0001 dB), so rounding in the mean
        // below cannot push a peak over it.
        let limit = ceiling * Self.margin
        var wanted: Float = 1
        if peak > threshold && threshold < limit {
            let x = 20 * log10(peak)
            let y = Self.curve(x, threshold: 20 * log10(threshold), ceiling: 20 * log10(ceiling))
            wanted = min(exp((y - x) * Float(M_LN10 / 20)), limit / peak)
        } else if peak > limit {
            wanted = limit / peak
        }

        // Rings: this frame in; the next slot holds the frame from D ago.
        let readIndex = index + 1 == size ? 0 : index + 1
        delayLeft[index] = left
        delayRight[index] = right
        delayCeiling[index] = ceiling
        wantedRing[index] = wanted

        // Hold: minimum of the wanted gain over times t-D ... t-D+A.
        if dequeCount > 0 && dequeTimes[dequeHead] < time - lookAhead {
            dequeHead = dequeHead + 1 == size ? 0 : dequeHead + 1
            dequeCount -= 1
        }
        let entering = time - lookAhead + attack
        if entering >= 0 {
            push(wantedRing[entering % size], at: entering)
        }
        let hold = dequeCount > 0 ? dequeValues[dequeHead] : 1

        // Release: down at once, back up over RELEASE.
        if hold < released {
            released = hold
        } else if released < hold {
            released += (hold - released) * releaseCoefficient
            if hold - released < 1e-6 { released = hold }
        }

        // Mean over the last A+1 frames: a ramp that ends at the peak.
        // (The frame leaving is read before this one is written: at A = D
        // they share a slot.)
        smoothSum -= releasedRing[Self.slot(time - attack - 1, size)]
        releasedRing[index] = Double(released)
        smoothSum += Double(released)
        if index == 0 {
            // Clear the running sum's rounding drift once per ring.
            smoothSum = 0
            for back in 0...attack { smoothSum += releasedRing[Self.slot(-back, size)] }
        }
        gain = min(1, Float(smoothSum / Double(attack + 1)))

        index = readIndex
        time += 1
        let clip = delayCeiling[readIndex]
        var outLeft = delayLeft[readIndex] * gain
        var outRight = delayRight[readIndex] * gain
        if abs(outLeft) > clip {
            outLeft = outLeft > 0 ? clip : -clip
            safetyClips += 1
        }
        if abs(outRight) > clip {
            outRight = outRight > 0 ? clip : -clip
            safetyClips += 1
        }
        left = outLeft
        right = outRight
    }
}
