import AudioToolbox
import Foundation
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

/// What the editor's readouts show, since it last asked.
public struct MaximizerReadings: Equatable, Sendable {
    /// Deepest limiter gain reduction in dB (<= 0).
    public var reduction: Float = 0
    /// Mean UPWARD boost in dB (>= 0).
    public var boost: Float = 0

    public init(reduction: Float = 0, boost: Float = 0) {
        self.reduction = reduction
        self.boost = boost
    }
}

/// The whole MyMaximizer signal path, independent of Audio Unit APIs:
///
///     input ─ INPUT GAIN ─ UPWARD ─ look-ahead limiter (ceiling = OUTPUT) ─ output
///
/// INPUT GAIN drives the music into the limiter (the loudness); peaks above
/// THRESHOLD are pressed through a soft knee toward OUTPUT, which nothing
/// exceeds. THRESHOLD at OUTPUT (the default) is a plain brickwall.
///
/// The output lags the input by the look-ahead (10 ms), reported as
/// latency, also while bypassed (then the input comes out delayed), so
/// switching bypass does not shift the sound in time; it crossfades in
/// 10 ms. INPUT GAIN at 0 dB multiplies nothing, UPWARD at 0 dB computes
/// nothing; the limiter always runs.
///
/// Threading: `prepare` and `reset` while not rendering, `process` on the
/// render thread; targets, flags and readings are single aligned words
/// written from either side.
public final class MaximizerKernel: MyFXKernel {
    private static let glideSeconds = 0.02
    private static let fadeSeconds = 0.01

    public private(set) var sampleRate = 48_000.0
    public let history = MaximizerHistoryRing()

    private let targets = UnsafeMutablePointer<Float>.allocate(capacity: MaximizerParameter.addressCount)
    private let resetRequests = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private let bypassFlag = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    /// Deepest reduction, boost sum, boost frames.
    private let readings = UnsafeMutablePointer<Float>.allocate(capacity: 3)
    private let meterPeaks = MyFXMeterPeaks()
    private var handledResets: Int32 = 0
    private var isPrepared = false

    // Render-thread state.
    private let upward = MaximizerUpward()
    private let limiter = MaximizerLimiter()
    private var column = MaximizerColumnBuilder()
    /// The input delayed by the look-ahead, for bypass.
    private var dryLeft: [Float] = [0]
    private var dryRight: [Float] = [0]
    private var dryIndex = 0
    private var inputGain: Float = 1
    private var ceiling: Float = 1
    private var threshold: Float = 1
    /// 0 = processing, 1 = bypassed.
    private var bypassMix: Float = 0
    private var smoothing: Float = 0
    private var fadeStep: Float = 0

    public init() {
        targets.initialize(repeating: 0, count: MaximizerParameter.addressCount)
        for parameter in MaximizerParameter.allCases {
            targets[parameter.rawValue] = parameter.defaultValue
        }
        resetRequests.initialize(to: 0)
        bypassFlag.initialize(to: 0)
        readings.initialize(repeating: 0, count: 3)
    }

    deinit {
        targets.deallocate()
        resetRequests.deallocate()
        bypassFlag.deallocate()
        readings.deallocate()
    }

    // MARK: Control (any thread)

    public func setTarget(_ parameter: MaximizerParameter, _ value: Float) {
        targets[parameter.rawValue] = parameter.clamped(value)
    }

    public func target(_ parameter: MaximizerParameter) -> Float {
        targets[parameter.rawValue]
    }

    public func applyParameter(_ address: AUParameterAddress, _ value: AUValue) {
        guard let parameter = MaximizerParameter(rawValue: Int(address)) else { return }
        setTarget(parameter, value)
    }

    public func targetValue(_ address: AUParameterAddress) -> AUValue {
        MaximizerParameter(rawValue: Int(address)).map(target) ?? 0
    }

    public func requestReset() {
        resetRequests.pointee &+= 1
    }

    public var isBypassed: Bool {
        get { bypassFlag.pointee != 0 }
        set { bypassFlag.pointee = newValue ? 1 : 0 }
    }

    public var tailTime: Double { 0 }

    public var latencySamples: Int { MaximizerLimiter.lookAhead(sampleRate: sampleRate) }

    public func takeMeterPeaks() -> MyFXPeaks {
        meterPeaks.take()
    }

    /// Deepest reduction and mean boost since the last call.
    public func takeReadings() -> MaximizerReadings {
        let frames = readings[2]
        let taken = MaximizerReadings(reduction: readings[0], boost: frames > 0 ? readings[1] / frames : 0)
        readings[0] = 0
        readings[1] = 0
        readings[2] = 0
        return taken
    }

    /// Times the final clip had to catch a sample (should stay 0).
    var safetyClips: Int { limiter.safetyClips }

    // MARK: Setup (not while rendering)

    public func prepare(sampleRate: Double, maximumFrames: Int) {
        self.sampleRate = sampleRate
        upward.prepare(sampleRate: sampleRate)
        limiter.prepare(sampleRate: sampleRate)
        let window = limiter.lookAhead + 1
        dryLeft = [Float](repeating: 0, count: window)
        dryRight = [Float](repeating: 0, count: window)
        smoothing = Float(1 - exp(-1 / (Self.glideSeconds * sampleRate)))
        fadeStep = Float(1 / (Self.fadeSeconds * sampleRate))
        isPrepared = true
        reset()
    }

    /// Clears the audio state and jumps every smoothed value to its target.
    public func reset() {
        limiter.setAttack(milliseconds: target(.attack))
        limiter.setRelease(milliseconds: target(.release))
        upward.setTimes(attackMilliseconds: target(.attack), releaseMilliseconds: target(.release))
        upward.reset()
        limiter.reset()
        for index in dryLeft.indices {
            dryLeft[index] = 0
            dryRight[index] = 0
        }
        dryIndex = 0
        inputGain = Self.linear(target(.inputGain))
        threshold = Self.linear(target(.threshold))
        ceiling = Self.linear(target(.outputLevel))
        bypassMix = isBypassed ? 1 : 0
        column.reset(length: MaximizerHistory.columnFrames(sampleRate: sampleRate))
        handledResets = resetRequests.pointee
    }

    // MARK: Render

    public func process(
        inputLeft: UnsafePointer<Float>,
        inputRight: UnsafePointer<Float>,
        outputLeft: UnsafeMutablePointer<Float>,
        outputRight: UnsafeMutablePointer<Float>?,
        frameCount: Int
    ) {
        guard isPrepared, frameCount > 0 else { return }
        if resetRequests.pointee != handledResets {
            reset()
        }
        // Before processing: output may be the same memory as input.
        meterPeaks.recordInput(inputLeft, inputRight, frameCount)

        let gainTarget = Self.linear(target(.inputGain))
        let thresholdTarget = Self.linear(target(.threshold))
        let ceilingTarget = Self.linear(target(.outputLevel))
        let amount = target(.upward)
        let bypassTarget: Float = isBypassed ? 1 : 0
        limiter.setAttack(milliseconds: target(.attack))
        limiter.setRelease(milliseconds: target(.release))
        upward.setTimes(attackMilliseconds: target(.attack), releaseMilliseconds: target(.release))
        let runsUpward = !upward.isIdle(amount: amount)
        let window = dryLeft.count

        var inputGain = self.inputGain
        var ceiling = self.ceiling
        var threshold = self.threshold
        var bypassMix = self.bypassMix
        var lowestGain: Float = 1
        var boostSum: Float = 0

        for frame in 0..<frameCount {
            let inLeft = inputLeft[frame]
            let inRight = inputRight[frame]

            // INPUT GAIN (nothing to do at exactly 0 dB).
            if inputGain != gainTarget {
                inputGain += (gainTarget - inputGain) * smoothing
                if abs(gainTarget - inputGain) < 1e-6 { inputGain = gainTarget }
            }
            var left = inLeft * inputGain
            var right = inRight * inputGain

            // UPWARD.
            var boost: Float = 0
            if runsUpward {
                let gain = upward.gain(level: max(abs(left), abs(right)), amount: amount)
                left *= gain
                right *= gain
                boost = upward.boost
            }

            // Limiter.
            ceiling += (ceilingTarget - ceiling) * smoothing
            threshold += (thresholdTarget - threshold) * smoothing
            limiter.process(&left, &right, ceiling: ceiling, threshold: threshold)
            let gain = limiter.gain

            // Bypass: the input, delayed as much as the limiter delays.
            let readIndex = dryIndex + 1 == window ? 0 : dryIndex + 1
            dryLeft[dryIndex] = inLeft
            dryRight[dryIndex] = inRight
            dryIndex = readIndex
            if bypassMix != bypassTarget {
                bypassMix = bypassTarget > bypassMix ? min(1, bypassMix + fadeStep) : max(0, bypassMix - fadeStep)
            }
            if bypassMix > 0 {
                left += (dryLeft[readIndex] - left) * bypassMix
                right += (dryRight[readIndex] - right) * bypassMix
            }

            outputLeft[frame] = left
            outputRight?[frame] = right

            let bypassed = bypassMix >= 0.5
            if !bypassed {
                lowestGain = min(lowestGain, gain)
                boostSum += boost
            }
            if let finished = column.add(peak: max(abs(left), abs(right)), gain: bypassed ? 1 : gain,
                                         boost: bypassed ? 0 : boost, bypassed: bypassed) {
                history.write(finished)
            }
        }

        self.inputGain = inputGain
        self.ceiling = ceiling
        self.threshold = threshold
        self.bypassMix = bypassMix
        if lowestGain < 1 { readings[0] = min(readings[0], 20 * log10(lowestGain)) }
        readings[1] += boostSum
        readings[2] += Float(frameCount)
        meterPeaks.recordOutput(outputLeft, outputRight ?? outputLeft, frameCount)
    }

    private static func linear(_ decibels: Float) -> Float {
        pow(10, decibels / 20)
    }
}
