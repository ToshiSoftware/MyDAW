import AVFoundation

/// Peak level per channel; mono buffers report the same value on both sides.
public struct StereoPeak: Sendable, Equatable {
    public var left: Float
    public var right: Float

    public static let zero = StereoPeak(left: 0, right: 0)

    public init(left: Float, right: Float) {
        self.left = left
        self.right = right
    }

    public init(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else {
            self = .zero
            return
        }
        let frames = Int(buffer.frameLength)
        func peak(_ channel: Int) -> Float {
            var value: Float = 0
            let samples = channelData[channel]
            for index in 0..<frames {
                value = max(value, abs(samples[index]))
            }
            return value
        }
        let left = peak(0)
        self.init(left: left, right: buffer.format.channelCount > 1 ? peak(1) : left)
    }

    public var maximum: Float { max(left, right) }

    public func merged(with other: StereoPeak) -> StereoPeak {
        StereoPeak(left: max(left, other.left), right: max(right, other.right))
    }

    /// Fast attack, exponential release, as used by the meter timers. Levels
    /// below -100 dB drop to exactly zero so an idle meter stops changing.
    public func falling(to new: StereoPeak, by factor: Float) -> StereoPeak {
        func fall(_ current: Float, _ incoming: Float) -> Float {
            let value = max(incoming, current * factor)
            return value < 1e-5 ? 0 : value
        }
        return StereoPeak(left: fall(left, new.left), right: fall(right, new.right))
    }
}
