import AudioToolbox
import Foundation
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

/// The whole MyReverb signal path, independent of Audio Unit APIs:
///
///     input ─┬─ pre-delay ─ diffusion ─ tank ─ HPF ─ LPF ─┐ (wet)
///            └───────────────────────────────────────────┴─ mix ─ output
///
/// Threading: `prepare` and `reset` run while not rendering. `process` runs
/// on the render thread. `setTarget`, `requestReset` and `isBypassed` may be
/// called from any thread; their values are single aligned 32-bit words, so
/// the render thread sees either the old or the new value.
public final class ReverbKernel: MyFXKernel {
    public static let maximumPreDelaySeconds = 1.0
    /// Coefficients (RT, filter cutoffs) are updated once per chunk.
    private static let chunkSize = 32
    /// Wet level: a 2 s tail of white noise comes out at about input RMS.
    private static let wetGain: Float = 0.6
    private static let mixSmoothingSeconds = 0.02
    private static let preDelayFadeSeconds = 0.03
    private static let cutoffSmoothingSeconds = 0.03
    private static let reverbTimeSmoothingSeconds = 0.05

    public private(set) var sampleRate = 48_000.0
    public private(set) var maximumFrames = 0

    private let targets = UnsafeMutablePointer<Float>.allocate(capacity: ReverbParameter.allCases.count)
    private let resetRequests = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private let bypassFlag = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private let meterPeaks = MyFXMeterPeaks()
    private var handledResets: Int32 = 0
    private var wasBypassed = false
    private var isPrepared = false

    private let preDelay = ReverbPreDelay()
    private let tank = ReverbTank()
    private var highPassLeft = Butterworth3State()
    private var highPassRight = Butterworth3State()
    private var lowPassLeft = Butterworth3State()
    private var lowPassRight = Butterworth3State()
    private var highPassCoefficients = Butterworth3Coefficients()
    private var lowPassCoefficients = Butterworth3Coefficients()

    // Smoothed values (render thread only).
    private var mix: Float = 1
    private var highPassEngage: Float = 0
    private var lowPassEngage: Float = 0
    private var highPassCutoff = 0.0
    private var lowPassCutoff = 0.0
    private var logReverbTime = 0.0
    private var mixCoefficient: Float = 0

    public init() {
        for parameter in ReverbParameter.allCases {
            (targets + parameter.rawValue).initialize(to: parameter.defaultValue)
        }
        resetRequests.initialize(to: 0)
        bypassFlag.initialize(to: 0)
    }

    deinit {
        targets.deallocate()
        resetRequests.deallocate()
        bypassFlag.deallocate()
    }

    // MARK: Control (any thread)

    public func setTarget(_ parameter: ReverbParameter, _ value: Float) {
        targets[parameter.rawValue] = parameter.clamped(value)
    }

    public func applyParameter(_ address: AUParameterAddress, _ value: AUValue) {
        guard let parameter = ReverbParameter(rawValue: Int(address)) else { return }
        setTarget(parameter, value)
    }

    public func targetValue(_ address: AUParameterAddress) -> AUValue {
        ReverbParameter(rawValue: Int(address)).map(target) ?? 0
    }

    public func target(_ parameter: ReverbParameter) -> Float {
        targets[parameter.rawValue]
    }

    /// Clears the tail at the start of the next `process` call.
    public func requestReset() {
        resetRequests.pointee &+= 1
    }

    /// Bypassed, input passes unchanged; the tail restarts empty afterwards.
    public var isBypassed: Bool {
        get { bypassFlag.pointee != 0 }
        set { bypassFlag.pointee = newValue ? 1 : 0 }
    }

    /// Absolute peaks of input and output since the previous call, then
    /// starts over (for meters; mono reports the same value for L and R).
    public func takeMeterPeaks() -> MyFXPeaks {
        meterPeaks.take()
    }

    /// Pre-delay plus the time for the tail to fall 60 dB.
    public var tailTime: Double {
        Double(target(.preDelay)) + Double(target(.rt))
    }

    /// Nyquist RT as a fraction of RT; 1 makes RT the same at all frequencies.
    var highFrequencyRatio: Double {
        get { tank.highFrequencyRatio }
        set { tank.highFrequencyRatio = newValue }
    }

    /// Gain of the all-pass in each feedback path of the tank (0 = none).
    var loopDiffusion: Float {
        get { tank.loopDiffusion }
        set { tank.loopDiffusion = newValue }
    }

    // MARK: Setup (not while rendering)

    public func prepare(sampleRate: Double, maximumFrames: Int) {
        self.sampleRate = sampleRate
        self.maximumFrames = maximumFrames
        preDelay.prepare(sampleRate: sampleRate, maximumSeconds: Self.maximumPreDelaySeconds,
                         fadeSeconds: Self.preDelayFadeSeconds)
        tank.prepare(sampleRate: sampleRate)
        mixCoefficient = Float(1 - exp(-1 / (Self.mixSmoothingSeconds * sampleRate)))
        isPrepared = true
        reset()
    }

    /// Clears all audio state and jumps every smoothed value to its target.
    public func reset() {
        preDelay.reset(delaySamples: preDelayTargetSamples)
        tank.reset()
        highPassLeft = Butterworth3State()
        highPassRight = Butterworth3State()
        lowPassLeft = Butterworth3State()
        lowPassRight = Butterworth3State()
        handledResets = resetRequests.pointee
        wasBypassed = false

        mix = target(.mix) / 100
        highPassEngage = ReverbParameter.isHighPassThru(target(.hpf)) ? 0 : 1
        lowPassEngage = ReverbParameter.isLowPassThru(target(.lpf)) ? 0 : 1
        highPassCutoff = highPassCutoffTarget
        lowPassCutoff = lowPassCutoffTarget
        logReverbTime = log(Double(target(.rt)))
        highPassCoefficients = Butterworth3Coefficients(cutoff: highPassCutoff, sampleRate: sampleRate)
        lowPassCoefficients = Butterworth3Coefficients(cutoff: lowPassCutoff, sampleRate: sampleRate)
        tank.configure(reverbTime: exp(logReverbTime))
    }

    // MARK: Render

    /// Processes `frameCount` frames (at most `maximumFrames`). Output may be
    /// the same memory as input. Pass `outputRight: nil` for mono: then
    /// `inputLeft` and `inputRight` should be the same channel, and the wet
    /// signal is the mean of the tank's two outputs.
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
        if isBypassed {
            copy(inputLeft, to: outputLeft, frameCount)
            if let outputRight { copy(inputRight, to: outputRight, frameCount) }
            meterPeaks.recordOutput(outputLeft, outputRight ?? outputLeft, frameCount)
            wasBypassed = true
            return
        }
        if wasBypassed {
            reset()
        }

        var highPassLeft = self.highPassLeft
        var highPassRight = self.highPassRight
        var lowPassLeft = self.lowPassLeft
        var lowPassRight = self.lowPassRight
        var mix = self.mix
        var highPassEngage = self.highPassEngage
        var lowPassEngage = self.lowPassEngage
        let mixCoefficient = self.mixCoefficient
        let preDelay = self.preDelay
        let tank = self.tank

        var offset = 0
        while offset < frameCount {
            let count = min(Self.chunkSize, frameCount - offset)
            updateCoefficients(chunkFrames: count)
            let highPass = highPassCoefficients
            let lowPass = lowPassCoefficients
            let wetScale = Self.wetGain * tank.loudnessCompensation
            let mixTarget = target(.mix) / 100
            let preDelayTarget = preDelayTargetSamples
            let highPassEngageTarget: Float = ReverbParameter.isHighPassThru(target(.hpf)) ? 0 : 1
            let lowPassEngageTarget: Float = ReverbParameter.isLowPassThru(target(.lpf)) ? 0 : 1

            for frame in offset..<(offset + count) {
                mix += (mixTarget - mix) * mixCoefficient
                highPassEngage += (highPassEngageTarget - highPassEngage) * mixCoefficient
                lowPassEngage += (lowPassEngageTarget - lowPassEngage) * mixCoefficient

                let dryLeft = inputLeft[frame]
                let dryRight = inputRight[frame]
                let (delayedLeft, delayedRight) = preDelay.process(
                    left: dryLeft, right: dryRight, delaySamples: preDelayTarget)
                var (wetLeft, wetRight) = tank.process(left: delayedLeft, right: delayedRight)
                wetLeft *= wetScale
                wetRight *= wetScale

                // The filters always run (warm state); "Thru" fades them out.
                wetLeft += highPassEngage * (highPassLeft.process(wetLeft, highPass, highPass: true) - wetLeft)
                wetRight += highPassEngage * (highPassRight.process(wetRight, highPass, highPass: true) - wetRight)
                wetLeft += lowPassEngage * (lowPassLeft.process(wetLeft, lowPass, highPass: false) - wetLeft)
                wetRight += lowPassEngage * (lowPassRight.process(wetRight, lowPass, highPass: false) - wetRight)

                if let outputRight {
                    outputLeft[frame] = dryLeft + mix * (wetLeft - dryLeft)
                    outputRight[frame] = dryRight + mix * (wetRight - dryRight)
                } else {
                    outputLeft[frame] = dryLeft + mix * (0.5 * (wetLeft + wetRight) - dryLeft)
                }
            }
            tank.renormalizeModulation()
            offset += count
        }

        self.highPassLeft = highPassLeft
        self.highPassRight = highPassRight
        self.lowPassLeft = lowPassLeft
        self.lowPassRight = lowPassRight
        self.mix = mix
        self.highPassEngage = highPassEngage
        self.lowPassEngage = lowPassEngage
        meterPeaks.recordOutput(outputLeft, outputRight ?? outputLeft, frameCount)
    }

    // MARK: Private

    private var preDelayTargetSamples: Int {
        Int((Double(target(.preDelay)) * sampleRate).rounded())
    }

    /// While "Thru", the filter keeps running at the edge of the range so
    /// that fading it back in starts from a settled state.
    private var highPassCutoffTarget: Double {
        Double(max(target(.hpf), 10))
    }

    private var lowPassCutoffTarget: Double {
        min(Double(target(.lpf)), 0.49 * sampleRate)
    }

    private func updateCoefficients(chunkFrames: Int) {
        let frames = Double(chunkFrames)
        let rtTarget = log(Double(target(.rt)))
        if rtTarget != logReverbTime {
            logReverbTime = Self.approach(logReverbTime, rtTarget, frames: frames,
                                          seconds: Self.reverbTimeSmoothingSeconds, sampleRate: sampleRate,
                                          snapWithin: 1e-4)
            tank.configure(reverbTime: exp(logReverbTime))
        }
        let highTarget = highPassCutoffTarget
        if highTarget != highPassCutoff {
            highPassCutoff = Self.approach(highPassCutoff, highTarget, frames: frames,
                                           seconds: Self.cutoffSmoothingSeconds, sampleRate: sampleRate,
                                           snapWithin: 0.01)
            highPassCoefficients = Butterworth3Coefficients(cutoff: highPassCutoff, sampleRate: sampleRate)
        }
        let lowTarget = lowPassCutoffTarget
        if lowTarget != lowPassCutoff {
            lowPassCutoff = Self.approach(lowPassCutoff, lowTarget, frames: frames,
                                          seconds: Self.cutoffSmoothingSeconds, sampleRate: sampleRate,
                                          snapWithin: 0.01)
            lowPassCoefficients = Butterworth3Coefficients(cutoff: lowPassCutoff, sampleRate: sampleRate)
        }
    }

    /// One-pole step from `current` toward `target` over `frames` samples.
    private static func approach(_ current: Double, _ target: Double, frames: Double,
                                 seconds: Double, sampleRate: Double, snapWithin: Double) -> Double {
        let next = current + (target - current) * (1 - exp(-frames / (seconds * sampleRate)))
        return abs(target - next) < snapWithin ? target : next
    }

    @inline(__always)
    private func copy(_ source: UnsafePointer<Float>, to destination: UnsafeMutablePointer<Float>, _ count: Int) {
        if UnsafePointer(destination) != source {
            destination.update(from: source, count: count)
        }
    }
}
