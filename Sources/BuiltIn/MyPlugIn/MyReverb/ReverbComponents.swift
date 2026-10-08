import Foundation

// Building blocks of ReverbKernel. All memory is allocated in prepare(),
// never on the render thread; process calls only touch preallocated buffers.

@inline(__always)
private func nextPowerOfTwo(_ value: Int) -> Int {
    var size = 1
    while size < value { size <<= 1 }
    return size
}

// MARK: - Pre-delay

/// Stereo delay of 0 to `maximumSeconds`. A new delay time is reached by
/// crossfading from the old read position to the new one, so changes neither
/// click nor sweep the pitch. Always written, also at 0 s, so raising the
/// delay never replays stale audio.
final class ReverbPreDelay {
    private var left = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private var right = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private var size = 1
    private var mask = 0
    private var writeIndex = 0
    private var currentDelay = 0
    private var previousDelay = 0
    private var fadeLength = 1
    private var fadeRemaining = 0
    private(set) var maximumDelaySamples = 0

    func prepare(sampleRate: Double, maximumSeconds: Double, fadeSeconds: Double) {
        release()
        maximumDelaySamples = Int(sampleRate * maximumSeconds)
        size = nextPowerOfTwo(maximumDelaySamples + 4)
        mask = size - 1
        left = .allocate(capacity: size)
        right = .allocate(capacity: size)
        fadeLength = max(Int(sampleRate * fadeSeconds), 1)
        reset(delaySamples: 0)
    }

    func reset(delaySamples: Int) {
        left.update(repeating: 0, count: size)
        right.update(repeating: 0, count: size)
        writeIndex = 0
        currentDelay = min(max(delaySamples, 0), maximumDelaySamples)
        previousDelay = currentDelay
        fadeRemaining = 0
    }

    /// Starts moving to `delaySamples` unless a move is still fading; then
    /// the latest target is taken up when that fade ends.
    @inline(__always)
    func process(left inputLeft: Float, right inputRight: Float, delaySamples: Int) -> (Float, Float) {
        left[writeIndex] = inputLeft
        right[writeIndex] = inputRight
        if fadeRemaining == 0 {
            let target = min(max(delaySamples, 0), maximumDelaySamples)
            if target != currentDelay {
                previousDelay = currentDelay
                currentDelay = target
                fadeRemaining = fadeLength
            }
        }
        let index = (writeIndex - currentDelay) & mask
        var outLeft = left[index]
        var outRight = right[index]
        if fadeRemaining > 0 {
            let oldIndex = (writeIndex - previousDelay) & mask
            let oldWeight = Float(fadeRemaining) / Float(fadeLength)
            outLeft += oldWeight * (left[oldIndex] - outLeft)
            outRight += oldWeight * (right[oldIndex] - outRight)
            fadeRemaining -= 1
        }
        writeIndex = (writeIndex + 1) & mask
        return (outLeft, outRight)
    }

    private func release() {
        left.deallocate()
        right.deallocate()
    }

    deinit { release() }
}

// MARK: - Diffusion

/// Schroeder all-pass used to smear the input before it enters the tank.
final class ReverbAllpass {
    private var buffer = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private var size = 1
    private var mask = 0
    private var delay = 1
    private var writeIndex = 0
    private let gain: Float

    init(gain: Float) {
        self.gain = gain
    }

    func prepare(delaySamples: Int) {
        buffer.deallocate()
        delay = max(delaySamples, 1)
        size = nextPowerOfTwo(delay + 1)
        mask = size - 1
        buffer = .allocate(capacity: size)
        reset()
    }

    func reset() {
        buffer.update(repeating: 0, count: size)
        writeIndex = 0
    }

    @inline(__always)
    func process(_ input: Float) -> Float {
        let delayed = buffer[(writeIndex - delay) & mask]
        let v = input - gain * delayed
        buffer[writeIndex] = v
        writeIndex = (writeIndex + 1) & mask
        return delayed + gain * v
    }

    deinit { buffer.deallocate() }
}

// MARK: - Tank

/// Eight-line feedback delay network with a Hadamard feedback matrix.
/// Each line has its own absorbent one-pole filter whose DC gain gives the
/// requested RT exactly for that line's length (so RT does not depend on
/// which line the energy is in) and whose Nyquist gain gives
/// `highFrequencyRatio` x RT, a plate's darker tail. Slow, small delay
/// modulation keeps long tails from ringing metallic; it is read through
/// all-pass interpolation, which (unlike linear) loses no treble per pass
/// and so leaves RT as set. The output also taps each line part way along,
/// so the tail starts within a few milliseconds instead of after the
/// shortest line.
final class ReverbTank {
    static let lineCount = 8
    /// Line lengths in samples at 44.1 kHz (mutually prime, 34 to 85 ms).
    private static let baseLengths: [Double] = [1499, 1723, 2111, 2357, 2633, 2971, 3413, 3761]
    private static let modulationRates: [Double] = [0.31, 0.47, 0.53, 0.67, 0.71, 0.83, 0.97, 1.09]
    private static let modulationDepthSeconds = 0.000_17
    /// Output tap positions as fractions of each line's length.
    private static let tapFractions: [Double] = [0.11, 0.29, 0.17, 0.37, 0.23, 0.41, 0.13, 0.31]
    private static let tapGain: Float = 0.3
    /// Lengths of the all-passes inside the feedback loop, at 44.1 kHz
    /// (primes, 2.6 to 9.5 ms; none shares a factor with a line length).
    private static let loopAllpassLengths: [Double] = [241, 113, 373, 167, 421, 199, 331, 283]

    /// Nyquist RT as a fraction of the set RT. 1 disables damping (tests).
    var highFrequencyRatio: Double = 0.5 {
        didSet { configuredRT = -1 }
    }

    /// Gain of the all-pass in each line's feedback path; 0 leaves it out.
    /// Each pass through the loop then smears every echo into a burst, so
    /// echo density keeps rising with each reflection, as in a room. 0.5
    /// cut the time to full density from 152 to 116 ms (RT 2 s); higher
    /// gains added no density, only longer ringing at multiples of 1/length.
    var loopDiffusion: Float = 0.5 {
        didSet { configuredRT = -1 }
    }

    private var sampleRate = 48_000.0
    private var buffer = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private var lineSize = 1
    private var lineMask = 0
    private var writeIndex = 0
    private var modulationDepth: Float = 0
    private let delays = UnsafeMutablePointer<Float>.allocate(capacity: lineCount)
    private let lfoSin = UnsafeMutablePointer<Float>.allocate(capacity: lineCount)
    private let lfoCos = UnsafeMutablePointer<Float>.allocate(capacity: lineCount)
    private let lfoStepSin = UnsafeMutablePointer<Float>.allocate(capacity: lineCount)
    private let lfoStepCos = UnsafeMutablePointer<Float>.allocate(capacity: lineCount)
    private let feedbackA = UnsafeMutablePointer<Float>.allocate(capacity: lineCount)
    private let feedbackB = UnsafeMutablePointer<Float>.allocate(capacity: lineCount)
    private let filterState = UnsafeMutablePointer<Float>.allocate(capacity: lineCount)
    private let lines = UnsafeMutablePointer<Float>.allocate(capacity: lineCount)
    private let interpolatorState = UnsafeMutablePointer<Float>.allocate(capacity: lineCount)
    private let taps = UnsafeMutablePointer<Int>.allocate(capacity: lineCount)
    private let loopAllpassDelays = UnsafeMutablePointer<Int>.allocate(capacity: lineCount)
    private var loopAllpassBuffer = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private var loopAllpassSize = 1
    private var loopAllpassMask = 0
    private var loopAllpassIndex = 0
    // Separate properties, not an array: no retain or bounds check per sample.
    private let diffuserLeft1 = ReverbAllpass(gain: 0.75)
    private let diffuserLeft2 = ReverbAllpass(gain: 0.625)
    private let diffuserRight1 = ReverbAllpass(gain: 0.75)
    private let diffuserRight2 = ReverbAllpass(gain: 0.625)
    /// Keeps long tails from growing louder than a 2 s tail (<= 1).
    private(set) var loudnessCompensation: Float = 1
    private var configuredRT = -1.0

    init() {
        for pointer in [delays, lfoSin, lfoCos, lfoStepSin, lfoStepCos, feedbackA, feedbackB, filterState, lines,
                        interpolatorState] {
            pointer.initialize(repeating: 0, count: Self.lineCount)
        }
        taps.initialize(repeating: 1, count: Self.lineCount)
        loopAllpassDelays.initialize(repeating: 1, count: Self.lineCount)
    }

    func prepare(sampleRate: Double) {
        self.sampleRate = sampleRate
        let scale = sampleRate / 44_100
        modulationDepth = Float(Self.modulationDepthSeconds * sampleRate)
        var longest = 0.0
        var longestAllpass = 0
        for index in 0..<Self.lineCount {
            loopAllpassDelays[index] = max(Int(Self.loopAllpassLengths[index] * scale), 1)
            longestAllpass = max(longestAllpass, loopAllpassDelays[index])
            let length = Self.baseLengths[index] * scale
            delays[index] = Float(length)
            taps[index] = max(Int(length * Self.tapFractions[index]), 1)
            longest = max(longest, length)
            let step = 2 * Double.pi * Self.modulationRates[index] / sampleRate
            lfoStepSin[index] = Float(sin(step))
            lfoStepCos[index] = Float(cos(step))
        }
        buffer.deallocate()
        lineSize = nextPowerOfTwo(Int(longest) + Int(modulationDepth) + 4)
        lineMask = lineSize - 1
        buffer = .allocate(capacity: lineSize * Self.lineCount)
        loopAllpassBuffer.deallocate()
        loopAllpassSize = nextPowerOfTwo(longestAllpass + 1)
        loopAllpassMask = loopAllpassSize - 1
        loopAllpassBuffer = .allocate(capacity: loopAllpassSize * Self.lineCount)
        let diffuserLengths: [Double] = [142, 379, 107, 277]
        diffuserLeft1.prepare(delaySamples: Int(diffuserLengths[0] * scale))
        diffuserLeft2.prepare(delaySamples: Int(diffuserLengths[1] * scale))
        diffuserRight1.prepare(delaySamples: Int(diffuserLengths[2] * scale))
        diffuserRight2.prepare(delaySamples: Int(diffuserLengths[3] * scale))
        configuredRT = -1
        reset()
    }

    func reset() {
        buffer.update(repeating: 0, count: lineSize * Self.lineCount)
        filterState.update(repeating: 0, count: Self.lineCount)
        interpolatorState.update(repeating: 0, count: Self.lineCount)
        loopAllpassBuffer.update(repeating: 0, count: loopAllpassSize * Self.lineCount)
        loopAllpassIndex = 0
        writeIndex = 0
        for index in 0..<Self.lineCount {
            let phase = Double(index) * 2 * Double.pi / Double(Self.lineCount)
            lfoSin[index] = Float(sin(phase))
            lfoCos[index] = Float(cos(phase))
        }
        for diffuser in [diffuserLeft1, diffuserLeft2, diffuserRight1, diffuserRight2] {
            diffuser.reset()
        }
    }

    /// Sets the feedback filters for `reverbTime` (T60 in seconds).
    func configure(reverbTime: Double) {
        guard reverbTime != configuredRT else { return }
        configuredRT = reverbTime
        let ratio = min(max(highFrequencyRatio, 0.05), 1)
        var meanLength = 0.0
        for index in 0..<Self.lineCount {
            // An all-pass delays by its length on average over frequency.
            let length = Double(delays[index]) + (loopDiffusion != 0 ? Double(loopAllpassDelays[index]) : 0)
            meanLength += length / Double(Self.lineCount)
            let dcGain = pow(10, -3 * length / (reverbTime * sampleRate))
            let nyquistGain = pow(10, -3 * length / (reverbTime * ratio * sampleRate))
            // One-pole y = a*x + b*y1: DC gain a/(1-b), Nyquist gain a/(1+b).
            let b = (dcGain - nyquistGain) / (dcGain + nyquistGain)
            feedbackA[index] = Float(dcGain * (1 - b))
            feedbackB[index] = Float(b)
        }
        // Steady-state energy grows as 1/(1-g^2); hold it at the 2 s level.
        let gain = pow(10, -3 * meanLength / (reverbTime * sampleRate))
        let referenceGain = pow(10, -3 * meanLength / (2 * sampleRate))
        loudnessCompensation = Float(min(1, ((1 - gain * gain) / (1 - referenceGain * referenceGain)).squareRoot()))
    }

    /// Keeps the quadrature oscillators on the unit circle (call per chunk).
    func renormalizeModulation() {
        for index in 0..<Self.lineCount {
            let magnitude = lfoSin[index] * lfoSin[index] + lfoCos[index] * lfoCos[index]
            let correction = (3 - magnitude) * 0.5
            lfoSin[index] *= correction
            lfoCos[index] *= correction
        }
    }

    @inline(__always)
    func process(left: Float, right: Float) -> (Float, Float) {
        let diffusedLeft = diffuserLeft2.process(diffuserLeft1.process(left))
        let diffusedRight = diffuserRight2.process(diffuserRight1.process(right))

        // Taps part way along the lines (before this sample is written).
        var tapLeft: Float = 0
        var tapRight: Float = 0
        for index in 0..<Self.lineCount {
            let tap = buffer[index * lineSize + ((writeIndex - taps[index]) & lineMask)]
            tapLeft += index & 1 == 0 ? tap : -tap
            tapRight += index & 2 == 0 ? tap : -tap
        }

        // Read (modulated, all-pass interpolated) and absorb.
        for index in 0..<Self.lineCount {
            let sine = lfoSin[index]
            let cosine = lfoCos[index]
            lfoSin[index] = sine * lfoStepCos[index] + cosine * lfoStepSin[index]
            lfoCos[index] = cosine * lfoStepCos[index] - sine * lfoStepSin[index]
            let delay = delays[index] + modulationDepth * sine
            var whole = Int(delay)
            var fraction = delay - Float(whole)
            // Fraction in [0.1, 1.1): keeps the all-pass pole off the unit circle.
            if fraction < 0.1 {
                whole -= 1
                fraction += 1
            }
            let coefficient = (1 - fraction) / (1 + fraction)
            let base = index * lineSize
            let newer = buffer[base + ((writeIndex - whole) & lineMask)]
            let older = buffer[base + ((writeIndex - whole - 1) & lineMask)]
            let read = coefficient * (newer - interpolatorState[index]) + older
            interpolatorState[index] = read
            let filtered = feedbackA[index] * read + feedbackB[index] * filterState[index]
            filterState[index] = filtered
            if loopDiffusion != 0 {
                let slot = index * loopAllpassSize
                let delayed = loopAllpassBuffer[slot + ((loopAllpassIndex - loopAllpassDelays[index]) & loopAllpassMask)]
                let v = filtered - loopDiffusion * delayed
                loopAllpassBuffer[slot + loopAllpassIndex] = v
                lines[index] = delayed + loopDiffusion * v
            } else {
                lines[index] = filtered
            }
        }

        let outLeft = 0.5 * (lines[0] - lines[2] + lines[4] - lines[6]) + Self.tapGain * tapLeft
        let outRight = 0.5 * (lines[1] - lines[3] + lines[5] - lines[7]) + Self.tapGain * tapRight

        // Fast Walsh-Hadamard transform, scaled to be orthonormal.
        var half = 1
        while half < Self.lineCount {
            var start = 0
            while start < Self.lineCount {
                for index in start..<(start + half) {
                    let a = lines[index]
                    let b = lines[index + half]
                    lines[index] = a + b
                    lines[index + half] = a - b
                }
                start += half * 2
            }
            half *= 2
        }

        // A tiny DC bias keeps the decaying tail out of denormals.
        let scale: Float = 0.353_553_39
        let inputLeft = diffusedLeft + 1e-18
        let inputRight = diffusedRight + 1e-18
        for index in 0..<Self.lineCount {
            let input = index & 1 == 0 ? inputLeft : inputRight
            let signed = index & 2 == 0 ? input : -input
            buffer[index * lineSize + writeIndex] = scale * lines[index] + signed
        }
        writeIndex = (writeIndex + 1) & lineMask
        loopAllpassIndex = (loopAllpassIndex + 1) & loopAllpassMask
        return (outLeft, outRight)
    }

    deinit {
        buffer.deallocate()
        for pointer in [delays, lfoSin, lfoCos, lfoStepSin, lfoStepCos, feedbackA, feedbackB, filterState, lines,
                        interpolatorState] {
            pointer.deallocate()
        }
        taps.deallocate()
        loopAllpassDelays.deallocate()
        loopAllpassBuffer.deallocate()
    }
}

// MARK: - Tone filters

/// Coefficients of a 3rd-order Butterworth: a first-order section and a
/// Q = 1 state-variable section, both topology-preserving (TPT), so the
/// cutoff can move while audio runs without resetting state or clicking.
struct Butterworth3Coefficients {
    var onePole: Float = 0
    var a1: Float = 0
    var a2: Float = 0
    var a3: Float = 0

    init() {}

    init(cutoff: Double, sampleRate: Double) {
        let g = tan(Double.pi * min(max(cutoff, 1), 0.49 * sampleRate) / sampleRate)
        onePole = Float(g / (1 + g))
        let k = 1.0 // 1/Q with Q = 1
        let a1 = 1 / (1 + g * (g + k))
        self.a1 = Float(a1)
        a2 = Float(g * a1)
        a3 = Float(g * g * a1)
    }
}

struct Butterworth3State {
    private var onePole: Float = 0
    private var ic1: Float = 0
    private var ic2: Float = 0

    @inline(__always)
    mutating func process(_ input: Float, _ c: Butterworth3Coefficients, highPass: Bool) -> Float {
        let v = (input - onePole) * c.onePole
        let low = v + onePole
        onePole = low + v
        let first = highPass ? input - low : low

        let v3 = first - ic2
        let v1 = c.a1 * ic1 + c.a2 * v3
        let v2 = ic2 + c.a2 * ic1 + c.a3 * v3
        ic1 = 2 * v1 - ic1
        ic2 = 2 * v2 - ic2
        return highPass ? first - v1 - v2 : v2
    }
}
