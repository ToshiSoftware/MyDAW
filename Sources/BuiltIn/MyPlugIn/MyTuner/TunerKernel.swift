import AudioToolbox
import Foundation
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

/// MyTuner's audio side (Docs/MyTuner.md §3.1, §3.4): passes the sound
/// through unchanged and, while an editor asks for it, low-passes the mono
/// sum, decimates it to about 12 kHz and keeps it in a ring the editor
/// reads. The pitch detection itself runs in the editor (TunerAnalyzer),
/// so the render thread does only the filter.
///
/// Threading: `prepare` while not rendering, `process` on the render
/// thread; targets, flags and the ring's write count are single words
/// written from one thread and read from another.
public final class TunerKernel: MyFXKernel {
    /// Decimated samples kept; the analyzer reads at most half of them.
    public static let ringCapacity = 8_192
    private static let targetRate = 12_000.0

    private let targets = UnsafeMutablePointer<Float>.allocate(capacity: TunerParameter.allCases.count)
    private let resetRequests = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private let bypassFlag = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private let analysisFlag = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private let ring = UnsafeMutablePointer<Float>.allocate(capacity: TunerKernel.ringCapacity)
    private let written = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    private let rateBits = UnsafeMutablePointer<UInt64>.allocate(capacity: 1)
    private let meterPeaks = MyFXMeterPeaks()
    private var handledResets: Int32 = 0
    private var isPrepared = false

    // Render thread only.
    private var factor = 4
    private var phase = 0
    private var filter = TunerLowPass()

    public init() {
        for parameter in TunerParameter.allCases {
            (targets + parameter.rawValue).initialize(to: parameter.defaultValue)
        }
        resetRequests.initialize(to: 0)
        bypassFlag.initialize(to: 0)
        analysisFlag.initialize(to: 0)
        ring.initialize(repeating: 0, count: Self.ringCapacity)
        written.initialize(to: 0)
        rateBits.initialize(to: 0)
    }

    deinit {
        targets.deallocate()
        resetRequests.deallocate()
        bypassFlag.deallocate()
        analysisFlag.deallocate()
        ring.deallocate()
        written.deallocate()
        rateBits.deallocate()
    }

    // MARK: Control (any thread)

    public func setTarget(_ parameter: TunerParameter, _ value: Float) {
        targets[parameter.rawValue] = parameter.clamped(value)
    }

    public func target(_ parameter: TunerParameter) -> Float {
        targets[parameter.rawValue]
    }

    public func applyParameter(_ address: AUParameterAddress, _ value: AUValue) {
        guard let parameter = TunerParameter(rawValue: Int(address)) else { return }
        setTarget(parameter, value)
    }

    public func targetValue(_ address: AUParameterAddress) -> AUValue {
        TunerParameter(rawValue: Int(address)).map(target) ?? 0
    }

    public func requestReset() {
        resetRequests.pointee &+= 1
    }

    public var isBypassed: Bool {
        get { bypassFlag.pointee != 0 }
        set { bypassFlag.pointee = newValue ? 1 : 0 }
    }

    /// The editor sets this while it is on screen; otherwise the kernel only
    /// passes the sound through.
    public var isAnalyzing: Bool {
        get { analysisFlag.pointee != 0 }
        set { analysisFlag.pointee = newValue ? 1 : 0 }
    }

    public var tailTime: Double { 0 }

    public func takeMeterPeaks() -> MyFXPeaks {
        meterPeaks.take()
    }

    // MARK: Ring (reader side, any one thread)

    /// Rate of the ring's samples; 0 before `prepare`.
    public var decimatedSampleRate: Double {
        Double(bitPattern: rateBits.pointee)
    }

    /// How many samples have been written since `prepare` (only grows).
    public var writtenCount: Int {
        written.pointee
    }

    /// Copies the newest `count` samples (oldest first) into `destination`
    /// and returns the write count they end at, or nil if not that many
    /// are there yet or the writer overran the copy.
    public func copyLatest(_ count: Int, into destination: UnsafeMutablePointer<Float>) -> Int? {
        precondition(count <= Self.ringCapacity / 2)
        let end = written.pointee
        guard end >= count else { return nil }
        for index in 0..<count {
            destination[index] = ring[(end - count + index) & (Self.ringCapacity - 1)]
        }
        // Written over while copying: the oldest samples may be newer ones.
        guard written.pointee - end <= Self.ringCapacity - count else { return nil }
        return end
    }

    // MARK: Setup (not while rendering)

    public func prepare(sampleRate: Double, maximumFrames: Int) {
        factor = max(1, Int((sampleRate / Self.targetRate).rounded()))
        let rate = sampleRate / Double(factor)
        // Fundamentals stop at about 1.5 kHz; keep the harmonics up to 0.2 x the new rate.
        filter = TunerLowPass(cutoff: 0.2 * rate, sampleRate: sampleRate)
        rateBits.pointee = rate.bitPattern
        written.pointee = 0
        isPrepared = true
        reset()
    }

    public func reset() {
        filter.clear()
        phase = 0
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
        meterPeaks.recordInput(inputLeft, inputRight, frameCount)
        if isAnalyzing && !isBypassed {
            capture(inputLeft, inputRight, frameCount)
        }
        // The sound itself passes through unchanged.
        if UnsafePointer(outputLeft) != inputLeft { outputLeft.update(from: inputLeft, count: frameCount) }
        if let outputRight, UnsafePointer(outputRight) != inputRight {
            outputRight.update(from: inputRight, count: frameCount)
        }
        meterPeaks.recordOutput(outputLeft, outputRight ?? outputLeft, frameCount)
    }

    private func capture(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>, _ frameCount: Int) {
        var filter = self.filter
        var phase = self.phase
        var end = written.pointee
        let mask = Self.ringCapacity - 1
        for frame in 0..<frameCount {
            let filtered = filter.process(0.5 * (left[frame] + right[frame]))
            phase += 1
            if phase >= factor {
                phase = 0
                ring[end & mask] = filtered
                end += 1
            }
        }
        self.filter = filter
        self.phase = phase
        written.pointee = end
    }
}

/// 4th-order Butterworth low-pass (two biquads) ahead of the decimation.
struct TunerLowPass {
    private struct Section {
        var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
        var z1: Float = 0, z2: Float = 0

        init() {}

        init(cutoff: Double, sampleRate: Double, q: Double) {
            let w = 2 * Double.pi * min(cutoff, 0.45 * sampleRate) / sampleRate
            let alpha = sin(w) / (2 * q)
            let cosW = cos(w)
            let a0 = 1 + alpha
            b0 = Float((1 - cosW) / 2 / a0)
            b1 = Float((1 - cosW) / a0)
            b2 = b0
            a1 = Float(-2 * cosW / a0)
            a2 = Float((1 - alpha) / a0)
        }

        @inline(__always)
        mutating func process(_ x: Float) -> Float {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    private var first = Section()
    private var second = Section()

    init() {}

    init(cutoff: Double, sampleRate: Double) {
        first = Section(cutoff: cutoff, sampleRate: sampleRate, q: 0.541_196)
        second = Section(cutoff: cutoff, sampleRate: sampleRate, q: 1.306_563)
    }

    mutating func clear() {
        first.z1 = 0
        first.z2 = 0
        second.z1 = 0
        second.z2 = 0
    }

    @inline(__always)
    mutating func process(_ x: Float) -> Float {
        let y = second.process(first.process(x))
        return y.isFinite ? y : 0
    }
}
