import AudioToolbox
import Foundation
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

/// MyChorusPan's signal path (Docs/MyChorusPan.md §3), independent of Audio
/// Unit APIs. Chorus, Dimension and Flanger share the modulated delay lines:
///
///     Chorus / Flanger: in L ─ line L ─┐ (LFO; the right one L.WID behind)
///                       in R ─ line R ─┴─ ST.WID ─ MIX with the input ─ out
///     Dimension:        in L ─ line A ─┐ (one LFO, 180 degrees apart)
///                       in R ─ line B ─┴─ left A - B/2, right B - A/2 ─ MIX with the input
///     Auto Pan:         in ─ equal-power gains from the pan LFO ─ out
///
/// Threading: `prepare` and `reset` while not rendering, `process` on the
/// render thread; targets, flags and the lamp readings are single 32-bit
/// words read and written from any thread.
public final class ChorusPanKernel: MyFXKernel {
    /// DELAY swings up to twice its value (DEPTH 100 %).
    static let maximumDelaySeconds = 0.060
    private static let smoothingSeconds = 0.02
    private static let speedSmoothingSeconds = 0.05
    private static let modeFadeSeconds = 0.01
    private static let delayCornerSeconds = 0.002
    private static let panCornerSeconds = 0.005
    /// Shortest read-back delay in samples: the 4-point interpolation needs
    /// two samples after the read position that are already written.
    private static let minimumDelaySamples: Float = 3
    private static let squareRootTwo = Float(2).squareRoot()

    private let targets = UnsafeMutablePointer<Float>.allocate(capacity: ChorusPanParameter.addressCount)
    private let resetRequests = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private let bypassFlag = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    /// For the editor's SPEED lamp: [phase, wave raw value] of the LFO the
    /// current mode uses, updated at the end of each render.
    private let lampReadings = UnsafeMutablePointer<Float>.allocate(capacity: 2)
    private let meterPeaks = MyFXMeterPeaks()
    private var handledResets: Int32 = 0
    private var isPrepared = false
    public private(set) var sampleRate = 48_000.0

    // Delay lines (allocated in prepare): L and R, or Dimension's A and B.
    private var left = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private var right = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private var size = 1
    private var mask = 0
    private var writeIndex = 0

    // Render-thread state.
    private var mode = ChorusPanMode.chorus
    private var gate: Float = 1
    private var gateStep: Float = 1
    private var smoothing: Float = 0
    private var modulationLFO = ChorusPanLFO()
    private var panLFO = ChorusPanLFO()
    private var cornerLeft = ChorusPanCornerSmoother()
    private var cornerRight = ChorusPanCornerSmoother()
    private var panCorner = ChorusPanCornerSmoother()
    /// DELAY glides through two one-poles (an S-curve): one pole alone
    /// changes the read-back speed at once, a corner heard as a click.
    private var delayGlide: Float = 0
    private var delaySamples: Float = 0
    private var depth: Float = 0
    private var feedback: Float = 0
    private var lfoWidth: Float = 0
    private var stereoWidth: Float = 0
    private var mix: Float = 0
    private var panWidth: Float = 0
    private var wetBoost: Float = 1
    private var dryBoost: Float = 1

    /// What a mode asks of the shared machinery, from its own parameters.
    private struct Settings {
        var delaySamples: Float = 0
        var depth: Float = 0
        var feedback: Float = 0
        var wave = ChorusPanWave.triangle
        var speed = 1.0
        /// 0 to 1: the right (B) LFO is lfoWidth x 180 degrees behind.
        var lfoWidth: Float = 0
        /// Dimension's button 4: the effect's and the input's gains.
        var wetBoost: Float = 1
        var dryBoost: Float = 1
        var stereoWidth: Float = 0
        var mix: Float = 0
        var panWidth: Float = 0
    }

    public init() {
        targets.initialize(repeating: 0, count: ChorusPanParameter.addressCount)
        for parameter in ChorusPanParameter.allCases {
            targets[parameter.rawValue] = parameter.defaultValue
        }
        resetRequests.initialize(to: 0)
        bypassFlag.initialize(to: 0)
        lampReadings.initialize(repeating: 0, count: 2)
    }

    deinit {
        targets.deallocate()
        resetRequests.deallocate()
        bypassFlag.deallocate()
        lampReadings.deallocate()
        left.deallocate()
        right.deallocate()
    }

    // MARK: Control (any thread)

    public func setTarget(_ parameter: ChorusPanParameter, _ value: Float) {
        targets[parameter.rawValue] = parameter.clamped(value)
    }

    public func target(_ parameter: ChorusPanParameter) -> Float {
        targets[parameter.rawValue]
    }

    public func applyParameter(_ address: AUParameterAddress, _ value: AUValue) {
        guard let parameter = ChorusPanParameter(rawValue: Int(address)) else { return }
        setTarget(parameter, value)
    }

    public func targetValue(_ address: AUParameterAddress) -> AUValue {
        ChorusPanParameter(rawValue: Int(address)).map(target) ?? 0
    }

    public func requestReset() {
        resetRequests.pointee &+= 1
    }

    public var isBypassed: Bool {
        get { bypassFlag.pointee != 0 }
        set { bypassFlag.pointee = newValue ? 1 : 0 }
    }

    /// The longest delay plus the feedback's fall to -60 dB; 0 for Auto Pan.
    public var tailTime: Double {
        let mode = targetMode
        guard mode != .autoPan else { return 0 }
        let settings = self.settings(for: mode)
        let longest = Double(settings.delaySamples * (1 + settings.depth)) / sampleRate
        let gain = Double(abs(settings.feedback))
        guard gain > 0.001 else { return longest }
        return longest + longest * log(0.001) / log(gain)
    }

    public func takeMeterPeaks() -> MyFXPeaks {
        meterPeaks.take()
    }

    /// The SPEED lamp's LFO: its phase (0 ..< 1) and waveform.
    public var lamp: (phase: Double, wave: ChorusPanWave) {
        (Double(lampReadings[0]), ChorusPanWave(rawValue: Int(lampReadings[1])) ?? .sine)
    }

    // MARK: Setup (not while rendering)

    public func prepare(sampleRate: Double, maximumFrames: Int) {
        self.sampleRate = sampleRate
        left.deallocate()
        right.deallocate()
        let needed = Int(Self.maximumDelaySeconds * sampleRate) + 8
        size = 1
        while size < needed { size <<= 1 }
        mask = size - 1
        left = .allocate(capacity: size)
        right = .allocate(capacity: size)
        smoothing = Float(1 - exp(-1 / (Self.smoothingSeconds * sampleRate)))
        gateStep = Float(1 / (Self.modeFadeSeconds * sampleRate))
        modulationLFO = ChorusPanLFO(sampleRate: sampleRate, speed: 1, smoothingSeconds: Self.speedSmoothingSeconds)
        panLFO = ChorusPanLFO(sampleRate: sampleRate, speed: 1, smoothingSeconds: Self.speedSmoothingSeconds)
        cornerLeft = ChorusPanCornerSmoother(sampleRate: sampleRate, seconds: Self.delayCornerSeconds)
        cornerRight = ChorusPanCornerSmoother(sampleRate: sampleRate, seconds: Self.delayCornerSeconds)
        panCorner = ChorusPanCornerSmoother(sampleRate: sampleRate, seconds: Self.panCornerSeconds)
        isPrepared = true
        reset()
    }

    /// Clears the lines, restarts the LFOs and jumps every smoothed value
    /// to its target.
    public func reset() {
        mode = targetMode
        gate = 1
        modulationLFO.reset(speed: 1)
        panLFO.reset(speed: 1)
        enter(settings(for: mode))
        handledResets = resetRequests.pointee
    }

    /// Starts `settings` from silence: empty lines, smoothed values and the
    /// LFO speed at their targets, corner smoothers at the LFOs' values.
    private func enter(_ settings: Settings) {
        left.update(repeating: 0, count: size)
        right.update(repeating: 0, count: size)
        writeIndex = 0
        modulationLFO.jump(speed: settings.speed)
        panLFO.jump(speed: settings.speed)
        cornerLeft.reset(to: ChorusPanLFO.value(settings.wave, at: modulationLFO.phase))
        cornerRight.reset(to: ChorusPanLFO.value(settings.wave,
                                                 at: modulationLFO.phase + 0.5 * Double(settings.lfoWidth)))
        panCorner.reset(to: ChorusPanLFO.value(settings.wave, at: panLFO.phase))
        delayGlide = settings.delaySamples
        delaySamples = settings.delaySamples
        depth = settings.depth
        feedback = settings.feedback
        lfoWidth = settings.lfoWidth
        stereoWidth = settings.stereoWidth
        mix = settings.mix
        panWidth = settings.panWidth
        wetBoost = settings.wetBoost
        dryBoost = settings.dryBoost
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
        if isBypassed {
            if UnsafePointer(outputLeft) != inputLeft { outputLeft.update(from: inputLeft, count: frameCount) }
            if let outputRight, UnsafePointer(outputRight) != inputRight {
                outputRight.update(from: inputRight, count: frameCount)
            }
            meterPeaks.recordOutput(outputLeft, outputRight ?? outputLeft, frameCount)
            return
        }

        let wantedMode = targetMode
        var targets = settings(for: mode)
        let smoothing = self.smoothing
        let gateStep = self.gateStep
        let left = self.left
        let right = self.right
        let mask = self.mask

        for frame in 0..<frameCount {
            // A MODE change fades the effect out, switches with empty lines
            // and fades it back in (as MyDelay).
            if wantedMode == mode {
                gate = min(1, gate + gateStep)
            } else {
                gate = max(0, gate - gateStep)
                if gate == 0 {
                    mode = wantedMode
                    targets = settings(for: mode)
                    enter(targets)
                }
            }
            delayGlide += (targets.delaySamples - delayGlide) * smoothing
            delaySamples += (delayGlide - delaySamples) * smoothing
            depth += (targets.depth - depth) * smoothing
            feedback += (targets.feedback - feedback) * smoothing
            lfoWidth += (targets.lfoWidth - lfoWidth) * smoothing
            stereoWidth += (targets.stereoWidth - stereoWidth) * smoothing
            mix += (targets.mix - mix) * smoothing
            panWidth += (targets.panWidth - panWidth) * smoothing

            let dryLeft = inputLeft[frame]
            let dryRight = inputRight[frame]
            var effectLeft: Float
            var effectRight: Float
            if mode == .autoPan {
                panLFO.advance(targetSpeed: targets.speed)
                // Equal power: centre unchanged (1, 1), ends (0, sqrt 2), the
                // two sides' power constant. Sine and cosine, not sqrt(1 -+ p),
                // which turns steeply at the ends and clicks leaving them.
                let position = panWidth * panCorner.process(ChorusPanLFO.value(targets.wave, at: panLFO.phase))
                let angle = Float.pi / 4 * (1 + position)
                effectLeft = dryLeft * Self.squareRootTwo * cos(angle)
                effectRight = dryRight * Self.squareRootTwo * sin(angle)
            } else {
                modulationLFO.advance(targetSpeed: targets.speed)
                let lfoLeft = cornerLeft.process(ChorusPanLFO.value(targets.wave, at: modulationLFO.phase))
                let lfoRight = cornerRight.process(
                    ChorusPanLFO.value(targets.wave, at: modulationLFO.phase + 0.5 * Double(lfoWidth)))
                let delayLeft = max(Self.minimumDelaySamples, delaySamples * (1 + depth * lfoLeft))
                let delayRight = max(Self.minimumDelaySamples, delaySamples * (1 + depth * lfoRight))
                let wetLeft = Self.read(left, mask: mask, writeIndex: writeIndex, delay: delayLeft)
                let wetRight = Self.read(right, mask: mask, writeIndex: writeIndex, delay: delayRight)
                if mode == .dimension {
                    // As the SDD-320: each input through its own line; each
                    // side gets its own line and the other one inverted
                    // (cross-mixed), so the two pitch wobbles partly cancel.
                    left[writeIndex] = gate * dryLeft
                    right[writeIndex] = gate * dryRight
                    let cross = ChorusPanDimensionSetting.cross
                    let ownLeft = wetLeft - cross * wetRight
                    let ownRight = wetRight - cross * wetLeft
                    let wetMid = 0.5 * (ownLeft + ownRight)
                    let wetSide = 0.5 * (ownLeft - ownRight) * stereoWidth
                    // MIX as in the other modes: (dry, wet) = (1, 0) at the
                    // bottom, (0.5, 0.5) in the middle, (0, 1) at the top;
                    // button 4 then raises the effect and lowers the input.
                    wetBoost += (targets.wetBoost - wetBoost) * smoothing
                    dryBoost += (targets.dryBoost - dryBoost) * smoothing
                    let dryGain = (1 - mix) * dryBoost
                    let wetGain = mix * wetBoost
                    effectLeft = dryGain * dryLeft + wetGain * (wetMid + wetSide)
                    effectRight = dryGain * dryRight + wetGain * (wetMid - wetSide)
                } else {
                    // The gate also fades what enters the lines, so after a
                    // MODE change the delayed sound starts from silence.
                    left[writeIndex] = Self.limit(gate * dryLeft + feedback * wetLeft)
                    right[writeIndex] = Self.limit(gate * dryRight + feedback * wetRight)
                    let mid = 0.5 * (wetLeft + wetRight)
                    let side = 0.5 * (wetLeft - wetRight) * stereoWidth
                    effectLeft = dryLeft + mix * (mid + side - dryLeft)
                    effectRight = dryRight + mix * (mid - side - dryRight)
                }
                writeIndex = (writeIndex + 1) & mask
            }
            effectLeft = dryLeft + gate * (effectLeft - dryLeft)
            effectRight = dryRight + gate * (effectRight - dryRight)
            if let outputRight {
                outputLeft[frame] = effectLeft
                outputRight[frame] = effectRight
            } else {
                outputLeft[frame] = 0.5 * (effectLeft + effectRight)
            }
        }

        lampReadings[0] = Float(mode == .autoPan ? panLFO.phase : modulationLFO.phase)
        lampReadings[1] = Float(targets.wave.rawValue)
        meterPeaks.recordOutput(outputLeft, outputRight ?? outputLeft, frameCount)
    }

    // MARK: Private

    private var targetMode: ChorusPanMode {
        ChorusPanMode(rawValue: Int(target(.mode))) ?? .chorus
    }

    private func wave(_ parameter: ChorusPanParameter) -> ChorusPanWave {
        ChorusPanWave(rawValue: Int(target(parameter))) ?? .triangle
    }

    private func samples(milliseconds: Float) -> Float {
        Float(Double(milliseconds) / 1_000 * sampleRate)
    }

    /// The shared machinery's targets for `mode`, from its own parameters.
    private func settings(for mode: ChorusPanMode) -> Settings {
        var settings = Settings()
        switch mode {
        case .chorus:
            settings.delaySamples = samples(milliseconds: target(.chorusDelay))
            settings.depth = target(.chorusDepth) / 100
            settings.wave = wave(.chorusLFOType)
            settings.speed = Double(target(.chorusSpeed))
            settings.lfoWidth = target(.chorusLFOWidth) / 100
            settings.stereoWidth = target(.chorusStereoWidth) / 100
            settings.mix = target(.chorusMix) / 100
        case .dimension:
            let index = min(max(Int(target(.dimensionMode)), 0),
                            ChorusPanDimensionSetting.delaysMilliseconds.count - 1)
            let delay = ChorusPanDimensionSetting.delaysMilliseconds[index]
            settings.delaySamples = samples(milliseconds: delay)
            settings.depth = ChorusPanDimensionSetting.swingsMilliseconds[index] / delay
            settings.wave = .triangle
            settings.speed = ChorusPanDimensionSetting.speed
            settings.lfoWidth = 1
            if target(.dimensionBoost) >= 0.5 {
                settings.wetBoost = ChorusPanDimensionSetting.boostWetGain
                settings.dryBoost = ChorusPanDimensionSetting.boostDryGain
            }
            settings.stereoWidth = target(.dimensionStereoWidth) / 100
            settings.mix = target(.dimensionMix) / 100
        case .flanger:
            settings.delaySamples = samples(milliseconds: target(.flangerDelay))
            settings.depth = target(.flangerDepth) / 100
            settings.feedback = target(.flangerFeedback) / 100
            settings.wave = wave(.flangerLFOType)
            settings.speed = Double(target(.flangerSpeed))
            settings.lfoWidth = target(.flangerLFOWidth) / 100
            settings.stereoWidth = target(.flangerStereoWidth) / 100
            settings.mix = target(.flangerMix) / 100
        case .autoPan:
            settings.wave = wave(.panType)
            settings.speed = Double(target(.panSpeed))
            settings.panWidth = target(.panWidth) / 100
        }
        return settings
    }

    /// The line `delay` samples back from the next write, by 4-point Hermite
    /// interpolation (linear loses treble, and the loss would move with the
    /// modulation).
    @inline(__always)
    private static func read(_ line: UnsafeMutablePointer<Float>, mask: Int, writeIndex: Int, delay: Float) -> Float {
        let position = Float(writeIndex) - delay
        let whole = Int(position.rounded(.down))
        let fraction = position - Float(whole)
        let y0 = line[(whole - 1) & mask]
        let y1 = line[whole & mask]
        let y2 = line[(whole + 1) & mask]
        let y3 = line[(whole + 2) & mask]
        let c1 = 0.5 * (y2 - y0)
        let c2 = y0 - 2.5 * y1 + 2 * y2 - 0.5 * y3
        let c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2)
        return ((c3 * fraction + c2) * fraction + c1) * fraction + y1
    }

    /// Soft ceiling on what is written into a line (as MyDelay): untouched
    /// up to full scale, then easing toward 1.25, so high feedback cannot
    /// grow without bound.
    @inline(__always)
    private static func limit(_ value: Float) -> Float {
        let magnitude = abs(value)
        guard magnitude > 1 else { return value }
        let knee: Float = 0.25
        let limited = 1 + knee * tanh((magnitude - 1) / knee)
        return value < 0 ? -limited : limited
    }
}
