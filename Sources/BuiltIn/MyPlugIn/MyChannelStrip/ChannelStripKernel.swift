import AudioToolbox
import Foundation
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

/// What the editor shows besides the IN/OUT meters, since it last asked.
public struct ChannelStripReadings: Equatable, Sendable {
    /// Deepest gain reduction in dB (<= 0).
    public var reduction: Float = 0
    /// Highest level entering the compressor's detector (linear).
    public var detector: Float = 0
    /// Bit n set: band n+1 is being computed.
    public var activeBands: Int = 0

    public init(reduction: Float = 0, detector: Float = 0, activeBands: Int = 0) {
        self.reduction = reduction
        self.detector = detector
        self.activeBands = activeBands
    }
}

/// One band's targets.
struct ChannelStripBandSettings {
    var shape = ChannelStripBandShape.off
    var frequency = 1_000.0
    var gain = 0.0
    var q = 1.0
}

/// The whole MyChannelStrip signal path, independent of Audio Unit APIs:
///
///     input ─ EQ ⇄ COMP (either order) ─ output gain ─ output
///                └ spectrum tap (EQ output)
///
/// Parts that leave the sound unchanged are not computed: bands that are
/// off or at 0 dB, the compressor when off, the output gain at 0 dB. With
/// everything flat the output is the input, bit for bit.
///
/// Threading: `prepare` and `reset` while not rendering, `process` on the
/// render thread; targets, flags and readings are single aligned words
/// written from either side.
public final class ChannelStripKernel: MyFXKernel {
    static let chunkSize = 16
    private static let glideSeconds = 0.02
    private static let fadeSeconds = 0.01

    public private(set) var sampleRate = 48_000.0

    private let targets = UnsafeMutablePointer<Float>.allocate(capacity: ChannelStripParameter.addressCount)
    private let resetRequests = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private let bypassFlag = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private let analysisFlag = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    /// Deepest reduction, detector peak, active band bits.
    private let readings = UnsafeMutablePointer<Float>.allocate(capacity: 3)
    private let meterPeaks = MyFXMeterPeaks()
    public let analysis = ChannelStripAnalysisRing()
    private var handledResets: Int32 = 0
    private var wasBypassed = false
    private var isPrepared = false

    // Render-thread state.
    private let bands = (0..<ChannelStripParameter.bandCount).map { _ in ChannelStripBand() }
    /// The bands' targets for the current render call (filled in place, so
    /// rendering allocates nothing).
    private var bandSettings = [ChannelStripBandSettings](repeating: ChannelStripBandSettings(),
                                                          count: ChannelStripParameter.bandCount)
    private let compressor = ChannelStripCompressor()
    private var order = ChannelStripOrder.eqFirst
    /// Output level while changing the order: fades to 0, the order changes
    /// and the filters and envelope are cleared, then it fades back to 1.
    private var gate: Float = 1
    private var gateStep: Float = 0
    private var outputGain: Float = 1
    private var smoothing: Float = 0

    public init() {
        targets.initialize(repeating: 0, count: ChannelStripParameter.addressCount)
        for parameter in ChannelStripParameter.allCases {
            targets[parameter.rawValue] = parameter.defaultValue
        }
        resetRequests.initialize(to: 0)
        bypassFlag.initialize(to: 0)
        analysisFlag.initialize(to: 0)
        readings.initialize(repeating: 0, count: 3)
    }

    deinit {
        targets.deallocate()
        resetRequests.deallocate()
        bypassFlag.deallocate()
        analysisFlag.deallocate()
        readings.deallocate()
    }

    // MARK: Control (any thread)

    public func setTarget(_ parameter: ChannelStripParameter, _ value: Float) {
        targets[parameter.rawValue] = parameter.clamped(value)
    }

    public func target(_ parameter: ChannelStripParameter) -> Float {
        targets[parameter.rawValue]
    }

    public func applyParameter(_ address: AUParameterAddress, _ value: AUValue) {
        guard let parameter = ChannelStripParameter(rawValue: Int(address)) else { return }
        setTarget(parameter, value)
    }

    public func targetValue(_ address: AUParameterAddress) -> AUValue {
        ChannelStripParameter(rawValue: Int(address)).map(target) ?? 0
    }

    public func requestReset() {
        resetRequests.pointee &+= 1
    }

    public var isBypassed: Bool {
        get { bypassFlag.pointee != 0 }
        set { bypassFlag.pointee = newValue ? 1 : 0 }
    }

    /// Whether the EQ output is written for the spectrum display (only while
    /// an editor shows it).
    public var isAnalysing: Bool {
        get { analysisFlag.pointee != 0 }
        set { analysisFlag.pointee = newValue ? 1 : 0 }
    }

    public var tailTime: Double { 0 }

    public func takeMeterPeaks() -> MyFXPeaks {
        meterPeaks.take()
    }

    /// Gain reduction and detector level since the last call, and the bands
    /// computing now.
    public func takeReadings() -> ChannelStripReadings {
        let taken = ChannelStripReadings(reduction: readings[0], detector: readings[1],
                                         activeBands: Int(readings[2]))
        readings[0] = 0
        readings[1] = 0
        return taken
    }

    public var targetOrder: ChannelStripOrder {
        ChannelStripOrder(rawValue: Int(target(.order))) ?? .eqFirst
    }

    // MARK: Setup (not while rendering)

    public func prepare(sampleRate: Double, maximumFrames: Int) {
        self.sampleRate = sampleRate
        for band in bands {
            band.prepare(sampleRate: sampleRate, chunk: Self.chunkSize, glideSeconds: Self.glideSeconds,
                         fadeSeconds: Self.fadeSeconds)
        }
        compressor.prepare(sampleRate: sampleRate, smoothingSeconds: Self.glideSeconds,
                           fadeSeconds: Self.fadeSeconds)
        smoothing = Float(1 - exp(-1 / (Self.glideSeconds * sampleRate)))
        gateStep = Float(1 / (Self.fadeSeconds * sampleRate))
        isPrepared = true
        reset()
    }

    /// Clears the audio state and jumps every smoothed value to its target.
    public func reset() {
        for (index, band) in bands.enumerated() {
            let settings = bandTargets(index)
            band.reset(shape: settings.shape, frequency: settings.frequency, gain: settings.gain, q: settings.q)
        }
        compressor.reset(compressorSettings())
        order = targetOrder
        gate = 1
        outputGain = Self.linear(target(.outputGain))
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
        if UnsafePointer(outputLeft) != inputLeft { outputLeft.update(from: inputLeft, count: frameCount) }
        if let outputRight, UnsafePointer(outputRight) != inputRight {
            outputRight.update(from: inputRight, count: frameCount)
        }
        if isBypassed {
            meterPeaks.recordOutput(outputLeft, outputRight ?? outputLeft, frameCount)
            wasBypassed = true
            return
        }
        if wasBypassed {
            reset()
        }

        let wantedOrder = targetOrder
        for index in bandSettings.indices { bandSettings[index] = bandTargets(index) }
        let settings = compressorSettings()
        let gainTarget = Self.linear(target(.outputGain))
        let analysing = isAnalysing
        var deepest = readings[0]
        var detector = readings[1]

        var offset = 0
        while offset < frameCount {
            let count = min(Self.chunkSize, frameCount - offset)
            let left = outputLeft + offset
            let right = outputRight.map { $0 + offset }

            if order == .compFirst {
                compressor.process(left, right, count, settings)
            }
            for index in bands.indices {
                let settings = bandSettings[index]
                bands[index].process(left, right, count, shape: settings.shape, frequency: settings.frequency,
                                     gain: settings.gain, q: settings.q)
            }
            if analysing {
                analysis.write(left, right.map { UnsafePointer($0) }, count)
            }
            if order == .eqFirst {
                compressor.process(left, right, count, settings)
            }
            deepest = min(deepest, compressor.deepestReduction)
            detector = max(detector, compressor.detectorPeak)

            applyOutput(left, right, count, gainTarget: gainTarget, wantedOrder: wantedOrder)
            offset += count

            // Faded out for an order change: switch, from empty filters.
            if gate == 0 && wantedOrder != order {
                order = wantedOrder
                compressor.clearState()
                for band in bands { band.clearState() }
            }
        }

        var active = 0
        for (index, band) in bands.enumerated() where band.isActive { active |= 1 << index }
        readings[0] = deepest
        readings[1] = detector
        readings[2] = Float(active)
        meterPeaks.recordOutput(outputLeft, outputRight ?? outputLeft, frameCount)
    }

    /// Output gain and the order-change gate; nothing when both rest at 1.
    @inline(__always)
    private func applyOutput(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>?,
                             _ count: Int, gainTarget: Float, wantedOrder: ChannelStripOrder) {
        let gateTarget: Float = wantedOrder == order ? 1 : 0
        let isResting = outputGain == 1 && gainTarget == 1 && gate == 1 && gateTarget == 1
        guard !isResting else { return }
        var outputGain = self.outputGain
        var gate = self.gate
        for i in 0..<count {
            outputGain += (gainTarget - outputGain) * smoothing
            gate = gateTarget > gate ? min(1, gate + gateStep) : max(0, gate - gateStep)
            let level = outputGain * gate
            left[i] *= level
            right?[i] *= level
        }
        // Settle exactly, so 0 dB stops costing anything.
        if abs(gainTarget - outputGain) < 1e-6 { outputGain = gainTarget }
        self.outputGain = outputGain
        self.gate = gate
    }

    // MARK: Private

    private func bandTargets(_ index: Int) -> ChannelStripBandSettings {
        let base = index * 10
        let shape = ChannelStripBandShape(
            isOn: target(.eqOn) >= 0.5 && targets[base + ChannelStripBandField.on.rawValue] >= 0.5,
            type: ChannelStripFilterType(rawValue: Int(targets[base + ChannelStripBandField.type.rawValue])) ?? .bell,
            steep: targets[base + ChannelStripBandField.slope.rawValue] >= 0.5
        )
        return ChannelStripBandSettings(
            shape: shape,
            frequency: Double(targets[base + ChannelStripBandField.frequency.rawValue]),
            gain: Double(targets[base + ChannelStripBandField.gain.rawValue]),
            q: Double(targets[base + ChannelStripBandField.q.rawValue])
        )
    }

    private func compressorSettings() -> ChannelStripCompressorSettings {
        let threshold = target(.compThreshold)
        let ratio = target(.compRatio)
        let auto = target(.compAutoMakeup) >= 0.5
            ? ChannelStripCompressorCurve.autoMakeup(threshold: threshold, ratio: ratio) : 0
        return ChannelStripCompressorSettings(
            isOn: target(.compOn) >= 0.5,
            threshold: threshold,
            ratio: ratio,
            knee: target(.compKnee),
            attackSeconds: target(.compAttack) / 1_000,
            releaseSeconds: target(.compRelease) / 1_000,
            makeup: target(.compMakeup) + auto,
            isLinked: target(.compLink) >= 0.5,
            mix: target(.compMix) / 100
        )
    }

    private static func linear(_ decibels: Float) -> Float {
        pow(10, decibels / 20)
    }
}
