import SwiftUI

public struct WaveformCanvas: View {
    @ObservedObject public var waveformCache: WaveformCache
    public let trackColor: Color
    public let sampleRate: Double
    public let pixelsPerSecond: CGFloat
    public let sampleOffset: Double
    public let visibleDuration: Double?
    public let channelIndex: Int?
    public let verticalScale: CGFloat

    public init(
        waveformCache: WaveformCache,
        trackColor: Color,
        sampleRate: Double = 48000.0,
        pixelsPerSecond: CGFloat = 80.0,
        sampleOffset: Double = 0.0,
        visibleDuration: Double? = nil,
        channelIndex: Int? = nil,
        verticalScale: CGFloat = 1.0
    ) {
        self.waveformCache = waveformCache
        self.trackColor = trackColor
        self.sampleRate = sampleRate
        self.pixelsPerSecond = pixelsPerSecond
        self.sampleOffset = max(0.0, sampleOffset)
        self.visibleDuration = visibleDuration
        self.channelIndex = channelIndex
        self.verticalScale = verticalScale
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

            for i in startIndex..<endIndex {
                let peak = peaks[i]
                let x = CGFloat(Double(i - startIndex) * pixelsPerPeak)
                if x > size.width { break }

                let topY = centerY - max(1.0, CGFloat(peak.max) * maxAmplitude)
                let bottomY = centerY - min(-1.0, CGFloat(peak.min) * maxAmplitude)

                if i == startIndex {
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
    }
}

