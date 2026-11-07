import Foundation

/// The consonant limiter's gain for one channel, with a look-ahead of D
/// frames (the kernel delays the high band by D):
///
///     wanted   w = THRESH / level above THRESH, else 1      per frame
///     hold     minimum of w over the last D+1 frames
///     smooth   down with ATTACK, back up with RELEASE (one pole each)
///     mean     over the last D+1 frames (a straight ramp of D)
///
/// With ATTACK 0 every value in the mean is at most the wanted gain of the
/// frame being output (D frames ago), so the gain starts down D frames
/// before a peak and is fully down when the peak comes out: the band never
/// passes THRESH, and the waveform is scaled, not clipped. The hold also
/// bridges the high band's zero crossings (half a period at 2 kHz is
/// 0.25 ms), so the gain does not ripple with the waveform. A longer ATTACK
/// lets the head of a consonant through.
///
/// Render thread only after `prepare`.
struct DeEsserGainChain {
    /// Current gain (<= 1) for the frame from D frames ago.
    private(set) var gain: Float = 1

    private var window = 1
    private var time = 0
    // Ring of the smoothed gains, for the mean.
    private var smoothedRing: [Double] = [1]
    // Sliding minimum of the wanted gain (monotonic deque).
    private var dequeValues: [Float] = [1]
    private var dequeTimes: [Int] = [0]
    private var dequeHead = 0
    private var dequeCount = 0
    private var smoothed = 1.0
    private var sum = 1.0

    /// `lookAhead` frames (D >= 1).
    mutating func prepare(lookAhead: Int) {
        window = lookAhead + 1
        smoothedRing = [Double](repeating: 1, count: window)
        dequeValues = [Float](repeating: 1, count: window)
        dequeTimes = [Int](repeating: 0, count: window)
        reset()
    }

    mutating func reset() {
        for slot in 0..<window { smoothedRing[slot] = 1 }
        time = 0
        dequeHead = 0
        dequeCount = 0
        smoothed = 1
        sum = Double(window)
        gain = 1
    }

    /// `attack` and `release` are one-pole coefficients (1 = at once).
    @inline(__always)
    mutating func process(wanted: Float, attack: Double, release: Double) {
        // Hold: minimum over the last D+1 frames.
        if dequeCount > 0 && dequeTimes[dequeHead] <= time - window {
            dequeHead = dequeHead + 1 == window ? 0 : dequeHead + 1
            dequeCount -= 1
        }
        while dequeCount > 0 {
            let last = (dequeHead + dequeCount - 1) % window
            guard dequeValues[last] >= wanted else { break }
            dequeCount -= 1
        }
        let slot = (dequeHead + dequeCount) % window
        dequeValues[slot] = wanted
        dequeTimes[slot] = time
        dequeCount += 1
        let hold = Double(dequeValues[dequeHead])

        // Down over ATTACK, up over RELEASE.
        if hold < smoothed {
            smoothed += (hold - smoothed) * attack
        } else if hold > smoothed {
            smoothed += (hold - smoothed) * release
            if hold - smoothed < 1e-7 { smoothed = hold }
        }

        // Mean over the last D+1 frames.
        let index = time % window
        sum += smoothed - smoothedRing[index]
        smoothedRing[index] = smoothed
        if index == 0 {
            // Clear the running sum's rounding drift once per ring.
            sum = smoothedRing.reduce(0, +)
        }
        gain = min(1, Float(sum / Double(window)))
        time += 1
    }
}
