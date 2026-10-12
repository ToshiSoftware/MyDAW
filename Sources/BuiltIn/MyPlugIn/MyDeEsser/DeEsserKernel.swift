import AudioToolbox
import Foundation
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

/// What the SIB and GR meters show, since the editor last asked.
public struct DeEsserReadings: Equatable, Sendable {
    /// Highest high-band (consonant) peak per channel, linear.
    public var sibilanceLeft: Float = 0
    public var sibilanceRight: Float = 0
    /// Deepest consonant gain reduction per channel in dB (<= 0).
    public var reductionLeft: Float = 0
    public var reductionRight: Float = 0

    public init(sibilanceLeft: Float = 0, sibilanceRight: Float = 0,
                reductionLeft: Float = 0, reductionRight: Float = 0) {
        self.sibilanceLeft = sibilanceLeft
        self.sibilanceRight = sibilanceRight
        self.reductionLeft = reductionLeft
        self.reductionRight = reductionRight
    }
}

/// The whole MyDeEsser signal path, independent of Audio Unit APIs:
///
///     input ─ INPUT GAIN ─ LR4 crossover at FREQ ─┬─ low ─────────────── delay D ─┬─ + ─ output
///                                                 └─ high ─┬─────────── delay D ─ × g ┘
///                                                          └─ level ─ gain chain (THRESH, ATTACK, RELEASE) ─ g
///
/// Only the consonant band (above FREQ) is limited to THRESH, with a 2 ms
/// look-ahead D so the gain is down before a consonant arrives. STEREO
/// LINK gives both channels the gain of the louder; off, each channel has
/// its own. LISTEN outputs the delayed high band before the limiter.
///
/// The output lags the input by D, reported as latency, also while
/// bypassed (then the input comes out delayed), so switching bypass does
/// not shift the sound in time. Bypass and LISTEN crossfade in 10 ms.
/// INPUT GAIN at 0 dB multiplies nothing. The IN meter reads the signal
/// after INPUT GAIN, which is what THRESH is compared with.
///
/// Threading: `prepare` and `reset` while not rendering, `process` on the
/// render thread; targets, flags and readings are single aligned words
/// written from either side.
public final class DeEsserKernel: MyFXKernel {
    static let lookAheadSeconds = 0.002
    private static let glideSeconds = 0.02
    private static let fadeSeconds = 0.01

    public private(set) var sampleRate = 48_000.0

    private let targets = UnsafeMutablePointer<Float>.allocate(capacity: DeEsserParameter.addressCount)
    private let resetRequests = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private let bypassFlag = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    /// SIB left, SIB right (linear peaks), lowest gain left, right (linear).
    private let readings = UnsafeMutablePointer<Float>.allocate(capacity: 4)
    private let meterPeaks = MyFXMeterPeaks()
    private var handledResets: Int32 = 0
    private var isPrepared = false

    // Render-thread state.
    private var crossoverLeft = DeEsserCrossover()
    private var crossoverRight = DeEsserCrossover()
    private var chainLeft = DeEsserGainChain()
    private var chainRight = DeEsserGainChain()
    private var coefficients = DeEsserFilterCoefficients()
    /// Look-ahead rings (D + 1 frames): low band, high band, raw input.
    private var lowLeft: [Float] = [0]
    private var lowRight: [Float] = [0]
    private var highLeft: [Float] = [0]
    private var highRight: [Float] = [0]
    private var dryLeft: [Float] = [0]
    private var dryRight: [Float] = [0]
    private var ringIndex = 0
    /// The input after INPUT GAIN, for the IN meter.
    private var gainedLeft: [Float] = []
    private var gainedRight: [Float] = []
    private var lookAhead = 1
    private var inputGain: Float = 1
    private var threshold: Float = 1
    private var logFrequency = log(6_500.0)
    /// 0 = processing, 1 = bypassed / listening.
    private var bypassMix: Float = 0
    private var listenMix: Float = 0
    private var smoothing: Float = 0
    private var frequencySmoothing = 0.0
    private var fadeStep: Float = 0

    public init() {
        targets.initialize(repeating: 0, count: DeEsserParameter.addressCount)
        for parameter in DeEsserParameter.allCases {
            targets[parameter.rawValue] = parameter.defaultValue
        }
        resetRequests.initialize(to: 0)
        bypassFlag.initialize(to: 0)
        readings.initialize(repeating: 0, count: 4)
        clearReadings()
    }

    deinit {
        targets.deallocate()
        resetRequests.deallocate()
        bypassFlag.deallocate()
        readings.deallocate()
    }

    // MARK: Control (any thread)

    public func setTarget(_ parameter: DeEsserParameter, _ value: Float) {
        targets[parameter.rawValue] = parameter.clamped(value)
    }

    public func target(_ parameter: DeEsserParameter) -> Float {
        targets[parameter.rawValue]
    }

    public func applyParameter(_ address: AUParameterAddress, _ value: AUValue) {
        guard let parameter = DeEsserParameter(rawValue: Int(address)) else { return }
        setTarget(parameter, value)
    }

    public func targetValue(_ address: AUParameterAddress) -> AUValue {
        DeEsserParameter(rawValue: Int(address)).map(target) ?? 0
    }

    public func requestReset() {
        resetRequests.pointee &+= 1
    }

    public var isBypassed: Bool {
        get { bypassFlag.pointee != 0 }
        set { bypassFlag.pointee = newValue ? 1 : 0 }
    }

    public var tailTime: Double { 0 }

    public var latencySamples: Int { Self.lookAhead(sampleRate: sampleRate) }

    static func lookAhead(sampleRate: Double) -> Int {
        max(1, Int((lookAheadSeconds * sampleRate).rounded()))
    }

    public func takeMeterPeaks() -> MyFXPeaks {
        meterPeaks.take()
    }

    /// SIB peaks and deepest reductions since the last call.
    public func takeReadings() -> DeEsserReadings {
        let taken = DeEsserReadings(
            sibilanceLeft: readings[0], sibilanceRight: readings[1],
            reductionLeft: Self.decibels(gain: readings[2]), reductionRight: Self.decibels(gain: readings[3]))
        clearReadings()
        return taken
    }

    private func clearReadings() {
        readings[0] = 0
        readings[1] = 0
        readings[2] = 1
        readings[3] = 1
    }

    // MARK: Setup (not while rendering)

    public func prepare(sampleRate: Double, maximumFrames: Int) {
        self.sampleRate = sampleRate
        lookAhead = Self.lookAhead(sampleRate: sampleRate)
        let window = lookAhead + 1
        lowLeft = [Float](repeating: 0, count: window)
        lowRight = lowLeft
        highLeft = lowLeft
        highRight = lowLeft
        dryLeft = lowLeft
        dryRight = lowLeft
        gainedLeft = [Float](repeating: 0, count: max(1, maximumFrames))
        gainedRight = gainedLeft
        chainLeft.prepare(lookAhead: lookAhead)
        chainRight.prepare(lookAhead: lookAhead)
        smoothing = Float(1 - exp(-1 / (Self.glideSeconds * sampleRate)))
        frequencySmoothing = 1 - exp(-1 / (Self.glideSeconds * sampleRate))
        fadeStep = Float(1 / (Self.fadeSeconds * sampleRate))
        isPrepared = true
        reset()
    }

    /// Clears the audio state and jumps every smoothed value to its target.
    public func reset() {
        crossoverLeft.reset()
        crossoverRight.reset()
        chainLeft.reset()
        chainRight.reset()
        for index in lowLeft.indices {
            lowLeft[index] = 0
            lowRight[index] = 0
            highLeft[index] = 0
            highRight[index] = 0
            dryLeft[index] = 0
            dryRight[index] = 0
        }
        ringIndex = 0
        inputGain = Self.linear(target(.inputGain))
        threshold = Self.linear(target(.threshold))
        logFrequency = log(Double(target(.frequency)))
        coefficients = DeEsserFilterCoefficients(frequency: exp(logFrequency), sampleRate: sampleRate)
        bypassMix = isBypassed ? 1 : 0
        listenMix = target(.listen) >= 0.5 ? 1 : 0
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
        // Longer blocks than prepared for go through in pieces (tests only;
        // the renderer never sends more).
        if frameCount > gainedLeft.count {
            var start = 0
            while start < frameCount {
                let count = min(gainedLeft.count, frameCount - start)
                process(inputLeft: inputLeft + start, inputRight: inputRight + start,
                        outputLeft: outputLeft + start, outputRight: outputRight.map { $0 + start },
                        frameCount: count)
                start += count
            }
            return
        }

        let isStereo = outputRight != nil
        let gainTarget = Self.linear(target(.inputGain))
        let thresholdTarget = Self.linear(target(.threshold))
        let logFrequencyTarget = log(Double(target(.frequency)))
        let isLinked = target(.stereoLink) >= 0.5
        let bypassTarget: Float = isBypassed ? 1 : 0
        let listenTarget: Float = target(.listen) >= 0.5 ? 1 : 0
        let attack = Self.coefficient(milliseconds: target(.attack), sampleRate: sampleRate)
        let release = Self.coefficient(milliseconds: target(.release), sampleRate: sampleRate)
        let window = lowLeft.count

        var inputGain = self.inputGain
        var threshold = self.threshold
        var logFrequency = self.logFrequency
        var coefficients = self.coefficients
        var bypassMix = self.bypassMix
        var listenMix = self.listenMix
        var ringIndex = self.ringIndex
        var sibilanceLeft = readings[0]
        var sibilanceRight = readings[1]
        var lowestLeft = readings[2]
        var lowestRight = readings[3]

        for frame in 0..<frameCount {
            let inLeft = inputLeft[frame]
            let inRight = isStereo ? inputRight[frame] : inLeft

            // INPUT GAIN (nothing to do at exactly 0 dB).
            if inputGain != gainTarget {
                inputGain += (gainTarget - inputGain) * smoothing
                if abs(gainTarget - inputGain) < 1e-6 { inputGain = gainTarget }
            }
            let left = inputGain == 1 ? inLeft : inLeft * inputGain
            let right = inputGain == 1 ? inRight : inRight * inputGain
            gainedLeft[frame] = left
            gainedRight[frame] = right

            // Crossover (coefficients follow FREQ only while it moves).
            if logFrequency != logFrequencyTarget {
                logFrequency += (logFrequencyTarget - logFrequency) * frequencySmoothing
                if abs(logFrequencyTarget - logFrequency) < 1e-6 { logFrequency = logFrequencyTarget }
                coefficients = DeEsserFilterCoefficients(frequency: exp(logFrequency), sampleRate: sampleRate)
            }
            let bandsLeft = crossoverLeft.process(Double(left), coefficients)
            let bandsRight = isStereo ? crossoverRight.process(Double(right), coefficients) : bandsLeft

            // Consonant limiter: the wanted gain from the high band's level.
            if threshold != thresholdTarget {
                threshold += (thresholdTarget - threshold) * smoothing
                if abs(thresholdTarget - threshold) < 1e-7 { threshold = thresholdTarget }
            }
            let levelLeft = Float(abs(bandsLeft.high))
            let levelRight = Float(abs(bandsRight.high))
            sibilanceLeft = max(sibilanceLeft, levelLeft)
            sibilanceRight = max(sibilanceRight, levelRight)
            let detectedLeft = isLinked ? max(levelLeft, levelRight) : levelLeft
            let detectedRight = isLinked ? max(levelLeft, levelRight) : levelRight
            chainLeft.process(wanted: detectedLeft > threshold ? threshold / detectedLeft : 1,
                              attack: attack, release: release)
            let gainLeft = chainLeft.gain
            var gainRight = gainLeft
            if isStereo {
                chainRight.process(wanted: detectedRight > threshold ? threshold / detectedRight : 1,
                                   attack: attack, release: release)
                gainRight = chainRight.gain
            }

            // Look-ahead rings: this frame in; the next slot is the frame from D ago.
            let readIndex = ringIndex + 1 == window ? 0 : ringIndex + 1
            lowLeft[ringIndex] = Float(bandsLeft.low)
            highLeft[ringIndex] = Float(bandsLeft.high)
            dryLeft[ringIndex] = inLeft
            lowRight[ringIndex] = Float(bandsRight.low)
            highRight[ringIndex] = Float(bandsRight.high)
            dryRight[ringIndex] = inRight
            ringIndex = readIndex

            var outLeft = lowLeft[readIndex] + gainLeft * highLeft[readIndex]
            var outRight = lowRight[readIndex] + gainRight * highRight[readIndex]

            // LISTEN: the consonant band alone, before the limiter.
            if listenMix != listenTarget {
                listenMix = listenTarget > listenMix ? min(1, listenMix + fadeStep) : max(0, listenMix - fadeStep)
            }
            if listenMix > 0 {
                outLeft += (highLeft[readIndex] - outLeft) * listenMix
                outRight += (highRight[readIndex] - outRight) * listenMix
            }

            // Bypass: the input, delayed as much as the look-ahead.
            if bypassMix != bypassTarget {
                bypassMix = bypassTarget > bypassMix ? min(1, bypassMix + fadeStep) : max(0, bypassMix - fadeStep)
            }
            if bypassMix > 0 {
                outLeft += (dryLeft[readIndex] - outLeft) * bypassMix
                outRight += (dryRight[readIndex] - outRight) * bypassMix
            }

            outputLeft[frame] = outLeft
            outputRight?[frame] = outRight
            if bypassMix < 0.5 {
                lowestLeft = min(lowestLeft, gainLeft)
                lowestRight = min(lowestRight, gainRight)
            }
        }

        self.inputGain = inputGain
        self.threshold = threshold
        self.logFrequency = logFrequency
        self.coefficients = coefficients
        self.bypassMix = bypassMix
        self.listenMix = listenMix
        self.ringIndex = ringIndex
        readings[0] = sibilanceLeft
        readings[1] = sibilanceRight
        readings[2] = lowestLeft
        readings[3] = lowestRight
        gainedLeft.withUnsafeBufferPointer { left in
            gainedRight.withUnsafeBufferPointer { right in
                meterPeaks.recordInput(left.baseAddress!, isStereo ? right.baseAddress! : left.baseAddress!,
                                       frameCount)
            }
        }
        meterPeaks.recordOutput(outputLeft, outputRight ?? outputLeft, frameCount)
    }

    /// One-pole coefficient for a time constant (0 ms = at once).
    static func coefficient(milliseconds: Float, sampleRate: Double) -> Double {
        guard milliseconds > 0 else { return 1 }
        return 1 - exp(-1 / (Double(milliseconds) / 1_000 * sampleRate))
    }

    private static func linear(_ decibels: Float) -> Float {
        pow(10, decibels / 20)
    }

    private static func decibels(gain: Float) -> Float {
        gain < 1 ? 20 * log10(max(gain, 1e-6)) : 0
    }
}
