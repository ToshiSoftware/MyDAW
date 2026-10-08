import AudioToolbox
import Foundation
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

/// One delay line. A new delay time is reached by crossfading from the old
/// read position to the new one, so changing the time neither clicks nor
/// sweeps the pitch. Per sample: `read` once, then `write` once.
final class DelayLine {
    private var buffer = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private var size = 1
    private var mask = 0
    private var writeIndex = 0
    private var currentDelay = 1
    private var previousDelay = 1
    private var fadeLength = 1
    private var fadeRemaining = 0
    private(set) var maximumDelay = 1

    func prepare(maximumDelay: Int, fadeLength: Int) {
        buffer.deallocate()
        self.maximumDelay = max(maximumDelay, 1)
        var size = 1
        while size < self.maximumDelay + 2 { size <<= 1 }
        self.size = size
        mask = size - 1
        buffer = .allocate(capacity: size)
        self.fadeLength = max(fadeLength, 1)
        reset(delay: 1)
    }

    func reset(delay: Int) {
        buffer.update(repeating: 0, count: size)
        writeIndex = 0
        currentDelay = clamp(delay)
        previousDelay = currentDelay
        fadeRemaining = 0
    }

    /// Starts moving to `delay` unless a move is still fading; the latest
    /// target is taken up when that fade ends.
    @inline(__always)
    func read(delay: Int) -> Float {
        if fadeRemaining == 0 {
            let target = clamp(delay)
            if target != currentDelay {
                previousDelay = currentDelay
                currentDelay = target
                fadeRemaining = fadeLength
            }
        }
        let current = buffer[(writeIndex - currentDelay) & mask]
        guard fadeRemaining > 0 else { return current }
        let previous = buffer[(writeIndex - previousDelay) & mask]
        let previousWeight = Float(fadeRemaining) / Float(fadeLength)
        fadeRemaining -= 1
        return current + previousWeight * (previous - current)
    }

    @inline(__always)
    func write(_ value: Float) {
        buffer[writeIndex] = value
        writeIndex = (writeIndex + 1) & mask
    }

    @inline(__always)
    private func clamp(_ delay: Int) -> Int {
        min(max(delay, 1), maximumDelay)
    }

    deinit { buffer.deallocate() }
}

/// The whole MyDelay signal path, independent of Audio Unit APIs:
///
///     input ─┬─ mode routing ─ delay lines (feedback) ─ width ─┐ (wet)
///            └──────────────────────────────────────────────────┴─ mix ─ output
///
/// Threading as in ReverbKernel: `prepare` and `reset` while not rendering,
/// `process` on the render thread, targets and flags from any thread.
public final class DelayKernel: MyFXKernel {
    public static let maximumDelaySeconds = 10.0
    private static let timeFadeSeconds = 0.04
    private static let modeFadeSeconds = 0.01
    private static let smoothingSeconds = 0.02
    private static let chunkSize = 32

    public private(set) var sampleRate = 48_000.0
    public private(set) var maximumFrames = 0

    private let targets = UnsafeMutablePointer<Float>.allocate(capacity: DelayParameter.allCases.count)
    private let resetRequests = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private let bypassFlag = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private let meterPeaks = MyFXMeterPeaks()
    private var handledResets: Int32 = 0
    private var wasBypassed = false
    private var isPrepared = false

    private let left = DelayLine()
    private let right = DelayLine()

    // Render-thread state.
    private var mode = DelayMode.stereo
    /// Wet level and line input while switching modes: fades to 0, the
    /// routing changes and the lines are cleared, then it fades back to 1.
    private var gate: Float = 1
    private var gateStep: Float = 0
    private var feedback: Float = 0
    private var width: Float = 1
    private var mix: Float = 1
    private var smoothing: Float = 0

    public init() {
        for parameter in DelayParameter.allCases {
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

    public func setTarget(_ parameter: DelayParameter, _ value: Float) {
        targets[parameter.rawValue] = parameter.clamped(value)
    }

    public func targetValue(_ address: AUParameterAddress) -> AUValue {
        DelayParameter(rawValue: Int(address)).map(target) ?? 0
    }

    public func target(_ parameter: DelayParameter) -> Float {
        targets[parameter.rawValue]
    }

    public func applyParameter(_ address: AUParameterAddress, _ value: AUValue) {
        guard let parameter = DelayParameter(rawValue: Int(address)) else { return }
        setTarget(parameter, value)
    }

    public var targetMode: DelayMode {
        DelayMode(rawValue: Int(target(.mode))) ?? .stereo
    }

    public func requestReset() {
        resetRequests.pointee &+= 1
    }

    public var isBypassed: Bool {
        get { bypassFlag.pointee != 0 }
        set { bypassFlag.pointee = newValue ? 1 : 0 }
    }

    public func takeMeterPeaks() -> MyFXPeaks {
        meterPeaks.take()
    }

    /// Until the echoes fall 60 dB (capped at 60 s past the longest delay).
    public var tailTime: Double {
        let mode = targetMode
        let time = Double(target(.time)) * (mode == .doubler ? DelayMode.doublerRightRatio : 1)
        let feedback = mode.usesFeedback ? Double(target(.feedback)) / 100 : 0
        guard feedback > 0.001 else { return time }
        guard feedback < 0.999 else { return time + 60 }
        // Ping-pong: each line echoes every 2 x time.
        let period = mode == .pingPong ? 2 * time : time
        let repeats = (log(0.001) / log(feedback)).rounded(.up)
        return min(time + period * repeats, time + 60)
    }

    // MARK: Setup (not while rendering)

    public func prepare(sampleRate: Double, maximumFrames: Int) {
        self.sampleRate = sampleRate
        self.maximumFrames = maximumFrames
        let maximumDelay = Int(sampleRate * Self.maximumDelaySeconds)
        let fade = Int(sampleRate * Self.timeFadeSeconds)
        left.prepare(maximumDelay: maximumDelay, fadeLength: fade)
        right.prepare(maximumDelay: maximumDelay, fadeLength: fade)
        smoothing = Float(1 - exp(-1 / (Self.smoothingSeconds * sampleRate)))
        gateStep = Float(1 / (Self.modeFadeSeconds * sampleRate))
        isPrepared = true
        reset()
    }

    /// Clears the echoes and jumps every smoothed value to its target.
    public func reset() {
        mode = targetMode
        let (leftDelay, rightDelay) = delays(for: mode)
        left.reset(delay: leftDelay)
        right.reset(delay: rightDelay)
        gate = 1
        feedback = mode.usesFeedback ? target(.feedback) / 100 : 0
        width = mode.usesWidth ? target(.width) / 100 : 0
        mix = target(.mix) / 100
        handledResets = resetRequests.pointee
        wasBypassed = false
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
            wasBypassed = true
            return
        }
        if wasBypassed {
            reset()
        }

        let left = self.left
        let right = self.right
        var gate = self.gate
        var feedback = self.feedback
        var width = self.width
        var mix = self.mix
        let smoothing = self.smoothing

        var offset = 0
        while offset < frameCount {
            let count = min(Self.chunkSize, frameCount - offset)
            let mode = self.mode
            let wantedMode = targetMode
            let (leftDelay, rightDelay) = delays(for: mode)
            let feedbackTarget = mode.usesFeedback ? target(.feedback) / 100 : 0
            let widthTarget = mode.usesWidth ? target(.width) / 100 : 0
            let mixTarget = target(.mix) / 100

            for frame in offset..<(offset + count) {
                feedback += (feedbackTarget - feedback) * smoothing
                width += (widthTarget - width) * smoothing
                mix += (mixTarget - mix) * smoothing
                gate = wantedMode == mode ? min(1, gate + gateStep) : max(0, gate - gateStep)

                let dryLeft = inputLeft[frame]
                let dryRight = inputRight[frame]
                // The gate fades what enters the lines too, so the first
                // echoes after a mode change fade in instead of clicking.
                let feedLeft = dryLeft * gate
                let feedRight = dryRight * gate
                let mono = 0.5 * (feedLeft + feedRight)
                let readLeft = left.read(delay: leftDelay)
                let readRight = right.read(delay: rightDelay)
                var wetLeft = readLeft
                var wetRight = readRight
                switch mode {
                case .mono:
                    left.write(Self.limit(mono + feedback * readLeft))
                    right.write(0)
                    wetRight = readLeft
                case .stereo:
                    left.write(Self.limit(feedLeft + feedback * readLeft))
                    right.write(Self.limit(feedRight + feedback * readRight))
                case .doubler:
                    left.write(mono)
                    right.write(mono)
                case .pingPong:
                    left.write(Self.limit(mono + feedback * readRight))
                    right.write(Self.limit(feedback * readLeft))
                }

                // Width: 0 folds the echoes to the centre, 1 keeps them apart.
                let mid = 0.5 * (wetLeft + wetRight)
                let side = 0.5 * (wetLeft - wetRight) * width
                wetLeft = (mid + side) * gate
                wetRight = (mid - side) * gate

                if let outputRight {
                    outputLeft[frame] = dryLeft + mix * (wetLeft - dryLeft)
                    outputRight[frame] = dryRight + mix * (wetRight - dryRight)
                } else {
                    outputLeft[frame] = dryLeft + mix * (0.5 * (wetLeft + wetRight) - dryLeft)
                }
            }
            offset += count

            // Faded out for a mode change: switch, starting from empty lines.
            if gate == 0 && wantedMode != mode {
                self.mode = wantedMode
                let (newLeft, newRight) = delays(for: wantedMode)
                left.reset(delay: newLeft)
                right.reset(delay: newRight)
            }
        }

        self.gate = gate
        self.feedback = feedback
        self.width = width
        self.mix = mix
        meterPeaks.recordOutput(outputLeft, outputRight ?? outputLeft, frameCount)
    }

    // MARK: Private

    private func delays(for mode: DelayMode) -> (Int, Int) {
        let time = Double(target(.time)) * sampleRate
        let leftDelay = Int(time.rounded())
        let rightDelay = mode == .doubler ? Int((time * DelayMode.doublerRightRatio).rounded()) : leftDelay
        return (leftDelay, rightDelay)
    }

    /// Soft ceiling on what is written into a line: untouched up to full
    /// scale (1.0), then easing toward `ceiling`, so with high feedback the
    /// repeats stop building up instead of growing without bound.
    static let ceiling: Float = 1.25

    @inline(__always)
    private static func limit(_ value: Float) -> Float {
        let magnitude = abs(value)
        guard magnitude > 1 else { return value }
        let knee = ceiling - 1
        let limited = 1 + knee * tanh((magnitude - 1) / knee)
        return value < 0 ? -limited : limited
    }
}
