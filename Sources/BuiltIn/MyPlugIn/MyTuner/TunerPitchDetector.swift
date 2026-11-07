import Accelerate
import Foundation

/// YIN pitch detection on the kernel's decimated signal (Docs/MyTuner.md
/// §3.2). Not thread-safe: one detector per reader.
public final class TunerPitchDetector {
    public static let lowestFrequency = 30.0
    public static let highestFrequency = 1_500.0
    /// The first dip of the normalized difference below this is the period.
    static let threshold: Float = 0.12
    /// Below about -60 dBFS RMS nothing is detected.
    static let gate: Float = 0.001

    public let sampleRate: Double
    /// Samples compared at each lag.
    public let windowSize: Int
    public let maximumLag: Int
    private let minimumLag: Int
    private var difference: [Float]
    private var normalized: [Float]

    /// Samples `detect` needs, oldest first.
    public var inputSize: Int { windowSize + maximumLag + 1 }

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        windowSize = max(64, Int(sampleRate * 0.085))
        maximumLag = Int(sampleRate / Self.lowestFrequency) + 2
        minimumLag = max(2, Int(sampleRate / Self.highestFrequency))
        difference = [Float](repeating: 0, count: maximumLag + 2)
        normalized = [Float](repeating: 1, count: maximumLag + 2)
    }

    /// A pitch and how clean it was (1 - the normalized difference at the
    /// period; 0.88 or more passes).
    public struct Result: Equatable {
        public let frequency: Double
        public let confidence: Double
    }

    /// The pitch of `samples` (at least `inputSize` of them; the newest
    /// `inputSize` are used), or nil for silence or no clear pitch.
    public func detect(_ samples: UnsafePointer<Float>, count: Int) -> Result? {
        guard count >= inputSize else { return nil }
        let x = samples + (count - inputSize)
        let window = vDSP_Length(windowSize)

        var meanSquare: Float = 0
        vDSP_measqv(x, 1, &meanSquare, window)
        guard meanSquare.squareRoot() >= Self.gate else { return nil }

        // Difference function d(τ) and its cumulative-mean normalization d'(τ).
        difference[0] = 0
        normalized[0] = 1
        var runningSum: Float = 0
        for lag in 1...maximumLag {
            var distance: Float = 0
            vDSP_distancesq(x, 1, x + lag, 1, &distance, window)
            difference[lag] = distance
            runningSum += distance
            normalized[lag] = runningSum > 0 ? distance * Float(lag) / runningSum : 1
        }

        // The first dip below the threshold, followed down to its bottom.
        var lag = minimumLag
        while lag < maximumLag, normalized[lag] >= Self.threshold {
            lag += 1
        }
        guard lag < maximumLag else { return nil }
        while lag + 1 < maximumLag, normalized[lag + 1] < normalized[lag] {
            lag += 1
        }
        let confidence = Double(1 - normalized[lag])
        let coarse = interpolatedMinimum(around: lag)

        // The difference also dips at whole multiples of the period; the
        // furthest one divides the interpolation error by the multiple.
        var period = coarse
        let multiples = Int(Double(maximumLag - 1) / coarse)
        if multiples >= 2 {
            for multiple in stride(from: multiples, through: 2, by: -1) {
                let expected = coarse * Double(multiple)
                guard let bottom = localMinimum(near: Int(expected.rounded())),
                      normalized[bottom] < 2 * Self.threshold else { continue }
                let refined = interpolatedMinimum(around: bottom) / Double(multiple)
                if abs(refined - coarse) < 0.02 * coarse {
                    period = refined
                    break
                }
            }
        }
        return Result(frequency: sampleRate / period, confidence: confidence)
    }

    /// The lowest point of d within ±2 of `center` that is lower than both
    /// neighbours.
    private func localMinimum(near center: Int) -> Int? {
        let lower = max(1, center - 2)
        let upper = min(maximumLag - 1, center + 2)
        guard lower <= upper else { return nil }
        var best = lower
        for lag in lower...upper where difference[lag] < difference[best] {
            best = lag
        }
        guard difference[best] <= difference[best - 1], difference[best] <= difference[best + 1] else { return nil }
        return best
    }

    /// The lag of a parabola's bottom through d at `lag` and its neighbours.
    private func interpolatedMinimum(around lag: Int) -> Double {
        guard lag > 0, lag < maximumLag else { return Double(lag) }
        let before = Double(difference[lag - 1])
        let at = Double(difference[lag])
        let after = Double(difference[lag + 1])
        let curvature = before - 2 * at + after
        guard curvature > 0 else { return Double(lag) }
        let offset = 0.5 * (before - after) / curvature
        return Double(lag) + min(max(offset, -1), 1)
    }
}

/// Reads the kernel's ring and runs the detector whenever enough new
/// samples have arrived; drops a single octave jump (Docs/MyTuner.md §3.2).
/// Main thread (or any one thread).
public final class TunerAnalyzer {
    public enum Update: Equatable {
        /// Not enough new samples since the last detection.
        case none
        /// Detected silence or no clear pitch.
        case silence
        case pitch(Double)
    }

    /// New samples between detections (about 21 ms at 12 kHz).
    static let hopSeconds = 0.021

    private let kernel: TunerKernel
    private var detector: TunerPitchDetector?
    private var buffer: [Float] = []
    private var lastEnd = 0
    private var lastPitch: Double?
    private var pendingOctave: Double?

    public init(kernel: TunerKernel) {
        self.kernel = kernel
    }

    public func update() -> Update {
        let rate = kernel.decimatedSampleRate
        guard rate > 0 else { return .none }
        if detector?.sampleRate != rate {
            let detector = TunerPitchDetector(sampleRate: rate)
            self.detector = detector
            buffer = [Float](repeating: 0, count: detector.inputSize)
            lastEnd = 0
            lastPitch = nil
            pendingOctave = nil
        }
        guard let detector else { return .none }
        let written = kernel.writtenCount
        if written < lastEnd { lastEnd = 0 } // the kernel was prepared again
        guard written - lastEnd >= max(1, Int(rate * Self.hopSeconds)) else { return .none }
        let count = buffer.count
        guard let end = buffer.withUnsafeMutableBufferPointer({ kernel.copyLatest(count, into: $0.baseAddress!) })
        else { return .none }
        lastEnd = end
        let result = buffer.withUnsafeBufferPointer { detector.detect($0.baseAddress!, count: count) }
        guard let frequency = result?.frequency else {
            lastPitch = nil
            pendingOctave = nil
            return .silence
        }
        return .pitch(acceptingOctaveJumps(frequency))
    }

    /// An octave up or down from the last pitch counts only when it comes
    /// twice in a row; once, it is taken for a detection error.
    private func acceptingOctaveJumps(_ frequency: Double) -> Double {
        guard let previous = lastPitch else {
            lastPitch = frequency
            return frequency
        }
        let ratio = frequency / previous
        let isOctaveJump = abs(ratio - 2) < 0.06 || abs(ratio - 0.5) < 0.015
        if isOctaveJump, pendingOctave.map({ abs(frequency / $0 - 1) >= 0.03 }) ?? true {
            // Keep showing the previous pitch until the jump repeats.
            pendingOctave = frequency
            return previous
        }
        pendingOctave = nil
        lastPitch = frequency
        return frequency
    }
}
