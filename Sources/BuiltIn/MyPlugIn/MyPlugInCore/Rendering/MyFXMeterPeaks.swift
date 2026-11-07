import Foundation

/// Absolute input and output peaks of an effect since they were last taken.
public struct MyFXPeaks: Equatable, Sendable {
    public var inputLeft: Float
    public var inputRight: Float
    public var outputLeft: Float
    public var outputRight: Float

    public init(inputLeft: Float = 0, inputRight: Float = 0, outputLeft: Float = 0, outputRight: Float = 0) {
        self.inputLeft = inputLeft
        self.inputRight = inputRight
        self.outputLeft = outputLeft
        self.outputRight = outputRight
    }
}

/// An Audio Unit whose editor shows input and output meters.
public protocol MyFXMetering: AnyObject {
    func takeMeterPeaks() -> MyFXPeaks
}

/// Peak store written on the render thread and taken by the editor's timer.
/// Each value is one aligned 32-bit word: a reader sees the old or the new
/// value; a peak landing between take's read and clear is lost for a frame.
public final class MyFXMeterPeaks {
    private let peaks = UnsafeMutablePointer<Float>.allocate(capacity: 4)

    public init() {
        peaks.initialize(repeating: 0, count: 4)
    }

    deinit {
        peaks.deallocate()
    }

    /// Render thread. For mono pass the same channel as left and right.
    @inline(__always)
    public func recordInput(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>, _ count: Int) {
        record(left, right, count, slot: 0)
    }

    @inline(__always)
    public func recordOutput(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>, _ count: Int) {
        record(left, right, count, slot: 2)
    }

    /// Returns the peaks since the previous call and starts over.
    public func take() -> MyFXPeaks {
        let taken = MyFXPeaks(inputLeft: peaks[0], inputRight: peaks[1], outputLeft: peaks[2], outputRight: peaks[3])
        peaks.update(repeating: 0, count: 4)
        return taken
    }

    @inline(__always)
    private func record(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>, _ count: Int, slot: Int) {
        var peakLeft = peaks[slot]
        var peakRight = peaks[slot + 1]
        for frame in 0..<count {
            peakLeft = max(peakLeft, abs(left[frame]))
            peakRight = max(peakRight, abs(right[frame]))
        }
        peaks[slot] = peakLeft
        peaks[slot + 1] = peakRight
    }
}
