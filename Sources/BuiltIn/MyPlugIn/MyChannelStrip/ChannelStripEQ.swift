import Foundation

// MyChannelStrip's EQ: RBJ cookbook biquads. The coefficient functions are
// shared by the kernel and the editor's graph, so the curve drawn is the
// filter heard.

// MARK: - Coefficients

/// One normalised biquad section (a0 = 1).
public struct ChannelStripBiquad: Equatable, Sendable {
    public var b0, b1, b2, a1, a2: Double

    public static let identity = ChannelStripBiquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    /// Gain in dB at `frequency`.
    public func decibels(at frequency: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * frequency / sampleRate
        let cos1 = cos(w)
        let cos2 = cos(2 * w)
        let numerator = b0 * b0 + b1 * b1 + b2 * b2 + 2 * (b0 * b1 + b1 * b2) * cos1 + 2 * b0 * b2 * cos2
        let denominator = 1 + a1 * a1 + a2 * a2 + 2 * (a1 + a1 * a2) * cos1 + 2 * a2 * cos2
        return 10 * log10(max(numerator, 1e-30) / max(denominator, 1e-30))
    }
}

/// A band's filter: one section, or two for a 24 dB/oct cut.
public struct ChannelStripFilterDesign: Equatable, Sendable {
    public var first: ChannelStripBiquad
    public var second: ChannelStripBiquad?

    /// Q of the two sections of a 4th-order Butterworth.
    static let butterworthQ = (0.541_196_1, 1.306_563)

    public init(type: ChannelStripFilterType, steep: Bool, frequency: Double, gain: Double, q: Double,
                sampleRate: Double) {
        let frequency = min(max(frequency, 10), 0.45 * sampleRate)
        let q = max(q, 0.05)
        if type.isCut && steep {
            // At Q 0.71 a 4th-order Butterworth; a higher Q raises the second
            // section's Q in proportion, giving a resonant shoulder.
            let scale = q / 0.707_106_8
            first = Self.section(type, frequency, gain, Self.butterworthQ.0, sampleRate)
            second = Self.section(type, frequency, gain, Self.butterworthQ.1 * scale, sampleRate)
        } else {
            first = Self.section(type, frequency, gain, q, sampleRate)
            second = nil
        }
    }

    public func decibels(at frequency: Double, sampleRate: Double) -> Double {
        first.decibels(at: frequency, sampleRate: sampleRate)
            + (second?.decibels(at: frequency, sampleRate: sampleRate) ?? 0)
    }

    private static func section(_ type: ChannelStripFilterType, _ frequency: Double, _ gain: Double,
                                _ q: Double, _ sampleRate: Double) -> ChannelStripBiquad {
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosW = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let a = pow(10, gain / 40)
        let b0, b1, b2, a0, a1, a2: Double
        switch type {
        case .lowCut:
            b0 = (1 + cosW) / 2; b1 = -(1 + cosW); b2 = (1 + cosW) / 2
            a0 = 1 + alpha; a1 = -2 * cosW; a2 = 1 - alpha
        case .highCut:
            b0 = (1 - cosW) / 2; b1 = 1 - cosW; b2 = (1 - cosW) / 2
            a0 = 1 + alpha; a1 = -2 * cosW; a2 = 1 - alpha
        case .bell:
            b0 = 1 + alpha * a; b1 = -2 * cosW; b2 = 1 - alpha * a
            a0 = 1 + alpha / a; a1 = -2 * cosW; a2 = 1 - alpha / a
        case .lowShelf:
            let root = 2 * a.squareRoot() * alpha
            b0 = a * ((a + 1) - (a - 1) * cosW + root)
            b1 = 2 * a * ((a - 1) - (a + 1) * cosW)
            b2 = a * ((a + 1) - (a - 1) * cosW - root)
            a0 = (a + 1) + (a - 1) * cosW + root
            a1 = -2 * ((a - 1) + (a + 1) * cosW)
            a2 = (a + 1) + (a - 1) * cosW - root
        case .highShelf:
            let root = 2 * a.squareRoot() * alpha
            b0 = a * ((a + 1) + (a - 1) * cosW + root)
            b1 = -2 * a * ((a - 1) + (a + 1) * cosW)
            b2 = a * ((a + 1) + (a - 1) * cosW - root)
            a0 = (a + 1) - (a - 1) * cosW + root
            a1 = 2 * ((a - 1) - (a + 1) * cosW)
            a2 = (a + 1) - (a - 1) * cosW - root
        }
        return ChannelStripBiquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }
}

/// What a band is set to, as far as its filter's structure goes. Changing
/// it crossfades; frequency, gain and Q glide.
public struct ChannelStripBandShape: Equatable, Sendable {
    public var isOn: Bool
    public var type: ChannelStripFilterType
    public var steep: Bool

    public static let off = ChannelStripBandShape(isOn: false, type: .bell, steep: false)

    /// Whether the filter changes the sound at `gain` (shelves and bells at
    /// exactly 0 dB do not, and are not computed).
    public func isAudible(gain: Double) -> Bool {
        isOn && (type.isCut || gain != 0)
    }
}

// MARK: - Render-side band

/// Transposed direct form II state of one section, one channel.
struct ChannelStripSectionState {
    var z1 = 0.0
    var z2 = 0.0

    @inline(__always)
    mutating func tick(_ x: Double, _ c: ChannelStripBiquad) -> Double {
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        return y
    }
}

/// One filter instance of a band; a band keeps two to crossfade between.
final class ChannelStripFilterSlot {
    var shape = ChannelStripBandShape.off
    var design = ChannelStripFilterDesign(type: .bell, steep: false, frequency: 1_000, gain: 0, q: 1,
                                          sampleRate: 48_000)
    /// Frequency, gain and Q `design` was made for (nil: make it).
    var designedFor: (Double, Double, Double)?
    private var left = (ChannelStripSectionState(), ChannelStripSectionState())
    private var right = (ChannelStripSectionState(), ChannelStripSectionState())
    /// Whether the state holds anything (cleared when the slot stops).
    private var isRunning = false

    func clear() {
        left = (ChannelStripSectionState(), ChannelStripSectionState())
        right = (ChannelStripSectionState(), ChannelStripSectionState())
        isRunning = false
    }

    func update(frequency: Double, gain: Double, q: Double, sampleRate: Double) {
        if let (f, g, qq) = designedFor, f == frequency, g == gain, qq == q { return }
        design = ChannelStripFilterDesign(type: shape.type, steep: shape.steep, frequency: frequency,
                                          gain: gain, q: q, sampleRate: sampleRate)
        designedFor = (frequency, gain, q)
    }

    /// Filters in place; does nothing when the slot is inaudible at `gain`.
    @inline(__always)
    func process(_ leftSamples: UnsafeMutablePointer<Float>, _ rightSamples: UnsafeMutablePointer<Float>?,
                 _ count: Int, gain: Double) {
        guard shape.isAudible(gain: gain) else {
            if isRunning { clear() }
            return
        }
        isRunning = true
        let first = design.first
        if let second = design.second {
            for i in 0..<count {
                leftSamples[i] = Float(left.1.tick(left.0.tick(Double(leftSamples[i]), first), second))
            }
            if let rightSamples {
                for i in 0..<count {
                    rightSamples[i] = Float(right.1.tick(right.0.tick(Double(rightSamples[i]), first), second))
                }
            }
        } else {
            for i in 0..<count {
                leftSamples[i] = Float(left.0.tick(Double(leftSamples[i]), first))
            }
            if let rightSamples {
                for i in 0..<count {
                    rightSamples[i] = Float(right.0.tick(Double(rightSamples[i]), first))
                }
            }
        }
    }
}

/// One EQ band on the render thread. Frequency (in octaves), gain and Q
/// glide once per chunk and snap onto their targets, so a band set back to
/// 0 dB reaches exactly 0 and stops being computed. A change of shape (on,
/// type, slope) crossfades from the old filter to the new one.
final class ChannelStripBand {
    static let maximumChunk = 64

    private var current = ChannelStripFilterSlot()
    private var next = ChannelStripFilterSlot()
    private var fadePosition = 0
    private var fadeLength = 480
    private var isFading = false
    private var sampleRate = 48_000.0
    /// Per-chunk glide factor.
    private var glide = 1.0

    private(set) var octaves = log2(1_000.0)
    private(set) var gain = 0.0
    private(set) var logQ = 0.0

    private let fadeLeft = UnsafeMutablePointer<Float>.allocate(capacity: maximumChunk)
    private let fadeRight = UnsafeMutablePointer<Float>.allocate(capacity: maximumChunk)

    deinit {
        fadeLeft.deallocate()
        fadeRight.deallocate()
    }

    func prepare(sampleRate: Double, chunk: Int, glideSeconds: Double, fadeSeconds: Double) {
        self.sampleRate = sampleRate
        glide = 1 - exp(-Double(chunk) / (glideSeconds * sampleRate))
        fadeLength = max(1, Int(fadeSeconds * sampleRate))
    }

    /// Jumps to the targets with empty filters.
    func reset(shape: ChannelStripBandShape, frequency: Double, gain: Double, q: Double) {
        octaves = log2(frequency)
        self.gain = gain
        logQ = log(q)
        isFading = false
        current.shape = shape
        current.designedFor = nil
        current.clear()
        next.clear()
        current.update(frequency: frequency, gain: gain, q: q, sampleRate: sampleRate)
    }

    /// Clears the filters' memory, keeping settings.
    func clearState() {
        current.clear()
        next.clear()
        if isFading {
            swap(&current, &next)
            isFading = false
        }
    }

    /// Whether the band is computing anything now.
    var isActive: Bool {
        isFading ? (current.shape.isAudible(gain: gain) || next.shape.isAudible(gain: gain))
                 : current.shape.isAudible(gain: gain)
    }

    /// Filters one chunk (at most `maximumChunk` frames) in place.
    func process(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>?, _ count: Int,
                 shape: ChannelStripBandShape, frequency: Double, gain targetGain: Double, q: Double) {
        octaves = Self.approach(octaves, log2(frequency), glide, snap: 1e-4)
        gain = Self.approach(gain, targetGain, glide, snap: 1e-3)
        logQ = Self.approach(logQ, log(q), glide, snap: 1e-4)

        if !isFading && shape != current.shape {
            next.shape = shape
            next.designedFor = nil
            next.clear()
            fadePosition = 0
            isFading = true
        }

        let frequencyNow = exp2(octaves)
        let qNow = exp(logQ)
        let gainNow = gain
        if current.shape.isAudible(gain: gainNow) {
            current.update(frequency: frequencyNow, gain: gainNow, q: qNow, sampleRate: sampleRate)
        }
        guard isFading else {
            current.process(left, right, count, gain: gainNow)
            return
        }

        // Old filter into the side buffers, new one in place, then blend.
        if next.shape.isAudible(gain: gainNow) {
            next.update(frequency: frequencyNow, gain: gainNow, q: qNow, sampleRate: sampleRate)
        }
        fadeLeft.update(from: left, count: count)
        if let right { fadeRight.update(from: right, count: count) }
        current.process(fadeLeft, right == nil ? nil : fadeRight, count, gain: gainNow)
        next.process(left, right, count, gain: gainNow)
        let step = 1 / Float(fadeLength)
        var weight = Float(fadePosition) * step
        for i in 0..<count {
            let w = min(weight, 1)
            left[i] = fadeLeft[i] + w * (left[i] - fadeLeft[i])
            if let right { right[i] = fadeRight[i] + w * (right[i] - fadeRight[i]) }
            weight += step
        }
        fadePosition += count
        if fadePosition >= fadeLength {
            current.clear()
            swap(&current, &next)
            isFading = false
        }
    }

    @inline(__always)
    private static func approach(_ value: Double, _ target: Double, _ factor: Double, snap: Double) -> Double {
        let moved = value + (target - value) * factor
        return abs(target - moved) < snap ? target : moved
    }
}
