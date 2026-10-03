import SwiftUI

/// Compared with `==` (use `.equatable()`), so a parent redrawn for another
/// reason — a zoom step, a track resize — does not redraw the waveform when
/// nothing it draws has changed.
public struct WaveformCanvas: View, Equatable {
    @ObservedObject public var waveformCache: WaveformCache
    /// Only the part inside its `drawWindow` is drawn.
    @ObservedObject public var drawWindow: DrawWindowState
    /// Timeline seconds at the canvas's left edge.
    public let timelineOrigin: Double
    /// Stretches the drawn waveform while a scale change is previewed.
    public let scalePreview: PreviewScale
    public let trackColor: Color
    public let sampleRate: Double
    public let pixelsPerSecond: CGFloat
    public let sampleOffset: Double
    public let visibleDuration: Double?
    public let channelIndex: Int?
    public let verticalScale: CGFloat
    /// Playback gain, measured from the clip's start at the first visible
    /// sample; the waveform is drawn at the level it will actually be heard.
    public let envelope: ClipLayering.Envelope?

    public init(
        waveformCache: WaveformCache,
        trackColor: Color,
        sampleRate: Double = 48000.0,
        pixelsPerSecond: CGFloat = 80.0,
        sampleOffset: Double = 0.0,
        visibleDuration: Double? = nil,
        channelIndex: Int? = nil,
        verticalScale: CGFloat = 1.0,
        envelope: ClipLayering.Envelope? = nil,
        drawWindow: DrawWindowState? = nil,
        timelineOrigin: Double = 0.0,
        scalePreview: PreviewScale? = nil
    ) {
        self.scalePreview = scalePreview ?? .none
        self.waveformCache = waveformCache
        self.drawWindow = drawWindow ?? .unbounded
        self.timelineOrigin = timelineOrigin
        self.trackColor = trackColor
        self.sampleRate = sampleRate
        self.pixelsPerSecond = pixelsPerSecond
        self.sampleOffset = max(0.0, sampleOffset)
        self.visibleDuration = visibleDuration
        self.channelIndex = channelIndex
        self.verticalScale = verticalScale
        self.envelope = envelope
    }

    public static func == (lhs: WaveformCanvas, rhs: WaveformCanvas) -> Bool {
        lhs.waveformCache === rhs.waveformCache
            && lhs.drawWindow === rhs.drawWindow
            && lhs.scalePreview === rhs.scalePreview
            && lhs.trackColor == rhs.trackColor
            && lhs.sampleRate == rhs.sampleRate
            && lhs.pixelsPerSecond == rhs.pixelsPerSecond
            && lhs.sampleOffset == rhs.sampleOffset
            && lhs.visibleDuration == rhs.visibleDuration
            && lhs.channelIndex == rhs.channelIndex
            && lhs.verticalScale == rhs.verticalScale
            && lhs.envelope == rhs.envelope
            && lhs.timelineOrigin == rhs.timelineOrigin
    }

    public var body: some View {
        Canvas { context, size in
            let peaks = waveformCache.peaks(for: channelIndex)
            guard !peaks.isEmpty else { return }

            let centerY = size.height / 2.0
            let maxAmplitude = (size.height / 2.0) * 0.92 * verticalScale
            let secondsPerPeak = Double(waveformCache.samplesPerPeak) / (sampleRate > 0 ? sampleRate : 48000.0)
            let pixelsPerPeak = secondsPerPeak * Double(pixelsPerSecond)

            // Draw center reference line
            var centerLine = Path()
            centerLine.move(to: CGPoint(x: 0, y: centerY))
            centerLine.addLine(to: CGPoint(x: size.width, y: centerY))
            context.stroke(centerLine, with: .color(Color.white.opacity(0.12)), lineWidth: 1)

            // Build mirrored polygon path
            var topPath = Path()
            var bottomPoints: [CGPoint] = []

            let startIndex = min(
                peaks.count,
                max(0, Int(sampleOffset * sampleRate / Double(waveformCache.samplesPerPeak)))
            )
            let visiblePeakCount = visibleDuration.map {
                max(1, Int(ceil($0 * sampleRate / Double(waveformCache.samplesPerPeak))))
            } ?? peaks.count
            let endIndex = min(peaks.count, startIndex + visiblePeakCount)

            // Zoomed far out, several peaks share a pixel: draw each group's
            // extremes once instead of every peak.
            let group = max(1, Int(1.0 / max(pixelsPerPeak, 0.000_001)))
            // Only the peaks inside the draw window (in seconds from the
            // canvas's left edge), started on a group boundary.
            let window = drawWindow.range
            let windowStart = (window.lowerBound - timelineOrigin) / secondsPerPeak
            let windowEnd = (window.upperBound - timelineOrigin) / secondsPerPeak
            var firstIndex = startIndex
            if windowStart > 0 {
                let skipped = Int(min(windowStart, Double(endIndex - startIndex)))
                firstIndex = startIndex + skipped - skipped % group
            }
            let lastIndex = windowEnd < Double(endIndex - startIndex)
                ? min(endIndex, startIndex + Int(max(0, windowEnd)) + group + 1)
                : endIndex
            guard firstIndex < lastIndex else { return }
            for i in stride(from: firstIndex, to: lastIndex, by: group) {
                let groupEnd = min(lastIndex, i + group)
                var peak = peaks[i]
                if groupEnd - i > 1 {
                    var low = peak.min
                    var high = peak.max
                    for j in (i + 1)..<groupEnd {
                        low = Swift.min(low, peaks[j].min)
                        high = Swift.max(high, peaks[j].max)
                    }
                    peak = PeakPoint(id: peak.id, min: low, max: high)
                }
                let x = CGFloat(Double(i - startIndex) * pixelsPerPeak)
                if x > size.width { break }

                let gain = envelope.map {
                    CGFloat($0.gain(at: $0.span.start + Double(i - startIndex) * secondsPerPeak))
                } ?? 1.0
                // Kept inside the lane when the vertical zoom pushes peaks past it.
                let topY = max(0.0, centerY - max(1.0, CGFloat(peak.max) * maxAmplitude * gain))
                let bottomY = min(size.height, centerY - min(-1.0, CGFloat(peak.min) * maxAmplitude * gain))

                if i == firstIndex {
                    topPath.move(to: CGPoint(x: x, y: centerY))
                    topPath.addLine(to: CGPoint(x: x, y: topY))
                } else {
                    topPath.addLine(to: CGPoint(x: x, y: topY))
                }
                bottomPoints.append(CGPoint(x: x, y: bottomY))
            }

            // Reverse bottom points to close the polygon
            for pt in bottomPoints.reversed() {
                topPath.addLine(to: pt)
            }
            topPath.closeSubpath()

            // Fill with smooth gradient
            let gradient = Gradient(colors: [
                trackColor.opacity(0.85),
                trackColor.opacity(0.45)
            ])
            context.fill(
                topPath,
                with: .linearGradient(
                    gradient,
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )

            // Crisp stroke contour
            context.stroke(topPath, with: .color(trackColor.opacity(0.95)), lineWidth: 1.0)
        }
        .modifier(VerticalStretch(preview: scalePreview, anchor: .center))
        .clipped()
    }
}

/// Fade-in and fade-out lines across a clip's full height, following each
/// fade's curve (gain 0 at the bottom, 1 at the top).
public struct FadeLinesOverlay: View {
    let fadeInWidth: CGFloat
    let fadeOutWidth: CGFloat
    let fadeInCurve: FadeCurve
    let fadeOutCurve: FadeCurve

    public init(fadeInWidth: CGFloat, fadeOutWidth: CGFloat, fadeInCurve: FadeCurve, fadeOutCurve: FadeCurve) {
        self.fadeInWidth = fadeInWidth
        self.fadeOutWidth = fadeOutWidth
        self.fadeInCurve = fadeInCurve
        self.fadeOutCurve = fadeOutCurve
    }

    public var body: some View {
        Canvas { context, size in
            let steps = 32
            if fadeInWidth > 0.0 {
                let width = min(size.width, fadeInWidth)
                var path = Path()
                for step in 0...steps {
                    let ramp = Double(step) / Double(steps)
                    let point = CGPoint(x: width * CGFloat(ramp), y: size.height * CGFloat(1.0 - fadeInCurve.value(ramp)))
                    step == 0 ? path.move(to: point) : path.addLine(to: point)
                }
                context.stroke(path, with: .color(Color.white.opacity(0.85)), lineWidth: 1.5)
            }
            if fadeOutWidth > 0.0 {
                let startX = max(0.0, size.width - fadeOutWidth)
                var path = Path()
                for step in 0...steps {
                    let progress = Double(step) / Double(steps)
                    let point = CGPoint(
                        x: startX + (size.width - startX) * CGFloat(progress),
                        y: size.height * CGFloat(1.0 - fadeOutCurve.value(1.0 - progress))
                    )
                    step == 0 ? path.move(to: point) : path.addLine(to: point)
                }
                context.stroke(path, with: .color(Color.white.opacity(0.85)), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
    }
}
