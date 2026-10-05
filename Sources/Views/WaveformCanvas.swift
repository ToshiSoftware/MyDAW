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
            let coarse = waveformCache.peaks(for: channelIndex)
            guard !coarse.isEmpty, pixelsPerSecond > 0 else { return }
            let fine = waveformCache.finePeaks(for: channelIndex)

            let centerY = size.height / 2.0
            let maxAmplitude = (size.height / 2.0) * 0.92 * verticalScale
            let rate = sampleRate > 0 ? sampleRate : 48000.0
            let pointsPerSecond = Double(pixelsPerSecond)
            // Samples covered by one point-wide column.
            let samplesPerColumn = rate / pointsPerSecond

            // Draw center reference line
            var centerLine = Path()
            centerLine.move(to: CGPoint(x: 0, y: centerY))
            centerLine.addLine(to: CGPoint(x: size.width, y: centerY))
            context.stroke(centerLine, with: .color(Color.white.opacity(0.12)), lineWidth: 1)

            // The coarse level while each of its peaks fits in a column;
            // zoomed in further, the fine level (when loaded), so the
            // waveform keeps one peak per column instead of stretching.
            let useFine = !fine.isEmpty && samplesPerColumn < Double(waveformCache.samplesPerPeak)
            let samplesPerPeak = Double(useFine ? WaveformCache.fineSamplesPerPeak : waveformCache.samplesPerPeak)
            let peakCount = useFine ? fine.count : coarse.count

            // Columns from the canvas's left edge (= `sampleOffset`), only
            // inside the clip's visible part and the draw window.
            let startSample = sampleOffset * rate
            let clipColumns = visibleDuration.map { $0 * pointsPerSecond }
                ?? (Double(peakCount) * samplesPerPeak - startSample) / samplesPerColumn
            // Clamped as Doubles first: the unbounded window is ±infinity
            // once scaled, which Int() cannot take.
            let window = drawWindow.range
            let columnLimit = max(0.0, min(Double(size.width), clipColumns))
            let windowStart = (window.lowerBound - timelineOrigin) * pointsPerSecond
            let windowEnd = (window.upperBound - timelineOrigin) * pointsPerSecond
            let firstColumn = Int(floor(max(0.0, min(columnLimit, windowStart))))
            let lastColumn = Int(ceil(max(0.0, min(columnLimit, windowEnd))))
            guard firstColumn < lastColumn else { return }

            // Zoomed in past the fine level, the raw samples of the visible
            // part (read in the background; the fine level until then).
            let fineSamples = Double(WaveformCache.fineSamplesPerPeak)
            var samples: [Float] = []
            var samplesStart = 0
            if useFine && samplesPerColumn < fineSamples {
                let neededStart = Int(startSample + Double(firstColumn) * samplesPerColumn)
                let neededEnd = Int(ceil(startSample + Double(lastColumn) * samplesPerColumn))
                waveformCache.requestSamples(max(0, neededStart - 1)..<neededEnd)
                if let window = waveformCache.sampleWindow {
                    samples = window.samples(for: channelIndex)
                    samplesStart = window.startFrame
                }
            }

            // One rectangle per column, from its lowest to its highest
            // sample (true extremes, so zoomed in the bars follow the wave
            // instead of all rising from the centre line), as the waveform
            // is heard (envelope gain).
            var bars = Path()
            for column in firstColumn..<lastColumn {
                let columnStart = startSample + Double(column) * samplesPerColumn
                var low: Float = .infinity
                var high: Float = -.infinity
                // Frames of this column relative to the sample window; the
                // previous sample is included so neighbouring columns join.
                let sampleFirst = Int(columnStart) - 1 - samplesStart
                let sampleLast = Int(ceil(columnStart + samplesPerColumn)) - samplesStart
                if !samples.isEmpty, sampleFirst >= 0, sampleLast <= samples.count {
                    for index in sampleFirst..<max(sampleFirst + 1, sampleLast) {
                        let value = samples[index]
                        low = Swift.min(low, value)
                        high = Swift.max(high, value)
                    }
                } else {
                    let first = Int(columnStart / samplesPerPeak)
                    guard first < peakCount else { break }
                    let last = min(peakCount, max(first + 1, Int(ceil((columnStart + samplesPerColumn) / samplesPerPeak))))
                    if useFine {
                        for index in first..<last {
                            let peak = fine[index]
                            low = Swift.min(low, peak.minValue)
                            high = Swift.max(high, peak.maxValue)
                        }
                    } else {
                        for index in first..<last {
                            let peak = coarse[index]
                            low = Swift.min(low, peak.min)
                            high = Swift.max(high, peak.max)
                        }
                    }
                }
                let gain = envelope.map {
                    CGFloat($0.gain(at: $0.span.start + (Double(column) + 0.5) / pointsPerSecond))
                } ?? 1.0
                var topY = centerY - CGFloat(high) * maxAmplitude * gain
                var bottomY = centerY - CGFloat(low) * maxAmplitude * gain
                // At least 1 pt thick, around the value (silence: the centre line).
                if bottomY - topY < 1.0 {
                    let middle = (topY + bottomY) / 2.0
                    topY = middle - 0.5
                    bottomY = middle + 0.5
                }
                // Kept inside the lane when the vertical zoom pushes peaks past it.
                topY = min(max(0.0, topY), size.height)
                bottomY = min(max(0.0, bottomY), size.height)
                guard bottomY > topY else { continue }
                bars.addRect(CGRect(x: CGFloat(column), y: topY, width: 1.0, height: bottomY - topY))
            }

            let gradient = Gradient(colors: [
                trackColor.opacity(0.95),
                trackColor.opacity(0.6)
            ])
            context.fill(
                bars,
                with: .linearGradient(
                    gradient,
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
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
