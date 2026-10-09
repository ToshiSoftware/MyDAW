import AppKit
import AudioToolbox
import SwiftUI
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

// MARK: - EQ graph

/// One band's settings as the graph reads them.
struct ChannelStripBandView {
    let index: Int
    let shape: ChannelStripBandShape
    let bandOn: Bool
    let frequency: Double
    let gain: Double
    let q: Double

    init(index: Int, model: MyFXEditorModel) {
        self.index = index
        let value = { (field: ChannelStripBandField) in
            model.value(ChannelStripParameter.band(index, field).address)
        }
        bandOn = value(.on) >= 0.5
        shape = ChannelStripBandShape(
            isOn: bandOn && model.value(ChannelStripParameter.eqOn.address) >= 0.5,
            type: ChannelStripFilterType(rawValue: Int(value(.type))) ?? .bell,
            steep: value(.slope) >= 0.5
        )
        frequency = Double(value(.frequency))
        gain = Double(value(.gain))
        q = Double(value(.q))
    }

    func design(sampleRate: Double) -> ChannelStripFilterDesign {
        ChannelStripFilterDesign(type: shape.type, steep: shape.steep, frequency: frequency, gain: gain,
                                 q: q, sampleRate: sampleRate)
    }
}

/// Frequency and level axes of the EQ graph.
struct ChannelStripEQScale {
    static let lowest = 20.0
    static let highest = 20_000.0
    static let range = 18.0
    let size: CGSize
    private let inset: CGFloat = 6

    func x(_ frequency: Double) -> CGFloat {
        size.width * CGFloat(log(frequency / Self.lowest) / log(Self.highest / Self.lowest))
    }

    func frequency(_ x: CGFloat) -> Double {
        Self.lowest * pow(Self.highest / Self.lowest, Double(x / max(size.width, 1)))
    }

    func y(_ decibels: Double) -> CGFloat {
        let clamped = min(max(decibels, -Self.range - 2), Self.range + 2)
        return size.height / 2 - CGFloat(clamped / Self.range) * (size.height / 2 - inset)
    }

    /// dB per point vertically.
    var decibelsPerPoint: Double { Self.range / Double(size.height / 2 - inset) }
}

/// Waves-style EQ graph: spectrum, the summed curve, and a node per band.
/// Drag a node: across for frequency, up and down for gain (Q on cuts);
/// ⌥-drag or scroll for Q; ⇧ for fine steps; double-click turns the band
/// on or off; ⌘-click sets its gain to 0 dB.
struct ChannelStripEQGraph: View {
    @ObservedObject var model: MyFXEditorModel
    @ObservedObject var display: ChannelStripDisplayModel
    @Binding var selectedBand: Int
    @State private var mouse = ChannelStripMouseHandler()
    @State private var drag = ChannelStripEQDrag()

    private static let gridFrequencies: [(Double, String)] = [(63, "63"), (250, "250"), (1_000, "1K"),
                                                               (4_000, "4K"), (16_000, "16K")]
    private static let nodeRadius: CGFloat = 7

    var body: some View {
        GeometryReader { geometry in
            let scale = ChannelStripEQScale(size: geometry.size)
            let bands = (0..<ChannelStripParameter.bandCount).map { ChannelStripBandView(index: $0, model: model) }
            ZStack {
                Canvas { context, _ in
                    drawBackground(context, scale)
                    drawSpectrum(context, scale)
                    drawCurves(context, scale, bands)
                }
                ForEach(bands, id: \.index) { band in
                    node(band, scale)
                }
                ChannelStripMouseSurface(handler: configuredMouse(scale, bands))
            }
        }
        .background(MyFXPalette.well)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    // MARK: Drawing

    private func drawBackground(_ context: GraphicsContext, _ scale: ChannelStripEQScale) {
        for (frequency, label) in Self.gridFrequencies {
            let x = scale.x(frequency)
            context.stroke(Path { $0.move(to: CGPoint(x: x, y: 10)); $0.addLine(to: CGPoint(x: x, y: scale.size.height)) },
                           with: .color(ChannelStripColors.grid), lineWidth: 1)
            context.draw(Text(label).font(.system(size: 7, weight: .medium)).foregroundColor(ChannelStripColors.gridLabel),
                         at: CGPoint(x: x, y: 5))
        }
        for decibels in [-9.0, 0, 9] {
            let y = scale.y(decibels)
            context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: scale.size.width, y: y)) },
                           with: .color(decibels == 0 ? Color.white.opacity(0.22) : ChannelStripColors.grid),
                           lineWidth: 1)
            let label = decibels > 0 ? "+9" : (decibels < 0 ? "-9" : "0")
            context.draw(Text(label).font(.system(size: 7, weight: .medium)).foregroundColor(ChannelStripColors.gridLabel),
                         at: CGPoint(x: 3, y: y - 5), anchor: .leading)
        }
    }

    /// Bars from the bottom: -72 dB at the bottom, 0 dB at the top.
    private func drawSpectrum(_ context: GraphicsContext, _ scale: ChannelStripEQScale) {
        let height = scale.size.height
        for (band, level) in display.spectrum.enumerated() {
            let fraction = CGFloat(min(max((level + 72) / 72, 0), 1))
            guard fraction > 0 else { continue }
            let left = scale.x(ChannelStripSpectrum.bandEdge(band)) + 1
            let right = scale.x(ChannelStripSpectrum.bandEdge(band + 1)) - 1
            let rect = CGRect(x: left, y: height * (1 - fraction), width: max(1, right - left), height: height * fraction)
            context.fill(Path(rect), with: .color(Color.white.opacity(0.09)))
        }
    }

    private func drawCurves(_ context: GraphicsContext, _ scale: ChannelStripEQScale, _ bands: [ChannelStripBandView]) {
        let sampleRate = display.sampleRate
        let designs = bands.map { $0.shape.isOn ? $0.design(sampleRate: sampleRate) : nil }
        let width = scale.size.width
        let step: CGFloat = 2
        var points: [CGPoint] = []
        var x: CGFloat = 0
        while x <= width + step {
            let frequency = scale.frequency(min(x, width))
            let total = designs.reduce(0.0) { $0 + ($1?.decibels(at: frequency, sampleRate: sampleRate) ?? 0) }
            points.append(CGPoint(x: min(x, width), y: scale.y(total)))
            x += step
        }

        // The selected band alone, faintly.
        if let design = designs[selectedBand] {
            var single = Path()
            var x: CGFloat = 0
            while x <= width {
                let y = scale.y(design.decibels(at: scale.frequency(x), sampleRate: sampleRate))
                x == 0 ? single.move(to: CGPoint(x: x, y: y)) : single.addLine(to: CGPoint(x: x, y: y))
                x += step
            }
            context.stroke(single, with: .color(ChannelStripColors.band(selectedBand).opacity(0.45)), lineWidth: 1)
        }

        var line = Path()
        line.addLines(points)
        var fill = line
        fill.addLine(to: CGPoint(x: width, y: scale.y(0)))
        fill.addLine(to: CGPoint(x: 0, y: scale.y(0)))
        fill.closeSubpath()
        context.fill(fill, with: .color(ChannelStripColors.curve.opacity(0.16)))
        context.stroke(line, with: .color(ChannelStripColors.curve), lineWidth: 1.6)
    }

    /// Where a band's node sits: on its gain, or for cuts on the curve at
    /// its frequency.
    private func nodePosition(_ band: ChannelStripBandView, _ scale: ChannelStripEQScale) -> CGPoint {
        let level: Double
        if band.shape.type.isCut {
            level = band.design(sampleRate: display.sampleRate).decibels(at: band.frequency, sampleRate: display.sampleRate)
        } else {
            level = band.gain
        }
        return CGPoint(x: scale.x(band.frequency), y: scale.y(level))
    }

    /// Filled while the band computes; a ring when it is flat (not computed);
    /// grey when off; yellow brackets when selected.
    private func node(_ band: ChannelStripBandView, _ scale: ChannelStripEQScale) -> some View {
        let color = band.shape.isOn ? ChannelStripColors.band(band.index) : Color.gray
        let isComputing = display.activeBands & (1 << band.index) != 0
        let r = Self.nodeRadius
        return ZStack {
            Circle()
                .fill(isComputing ? color.opacity(0.35) : Color.black.opacity(0.35))
            Circle()
                .stroke(color, lineWidth: 1.5)
            Text("\(band.index + 1)")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(band.shape.isOn ? .white : .gray)
            if band.index == selectedBand {
                Circle()
                    .trim(from: 0.38, to: 0.62)
                    .stroke(ChannelStripColors.selection, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .padding(-3.5)
                Circle()
                    .trim(from: 0.88, to: 1)
                    .stroke(ChannelStripColors.selection, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .padding(-3.5)
                Circle()
                    .trim(from: 0, to: 0.12)
                    .stroke(ChannelStripColors.selection, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .padding(-3.5)
            }
        }
        .frame(width: 2 * r, height: 2 * r)
        .position(nodePosition(band, scale))
        .allowsHitTesting(false)
    }

    // MARK: Mouse

    private func configuredMouse(_ scale: ChannelStripEQScale, _ bands: [ChannelStripBandView]) -> ChannelStripMouseHandler {
        let model = model
        let drag = drag
        let positions = bands.map { nodePosition($0, scale) }
        let selection = $selectedBand
        let address = { (band: Int, field: ChannelStripBandField) in
            ChannelStripParameter.band(band, field).address
        }
        let nearest = { (point: CGPoint) -> Int? in
            let distances = positions.map { hypot($0.x - point.x, $0.y - point.y) }
            guard let best = distances.indices.min(by: { distances[$0] < distances[$1] }),
                  distances[best] <= Self.nodeRadius + 5 else { return nil }
            return best
        }

        mouse.down = { point, clicks, flags in
            drag.band = nil
            guard let band = nearest(point) else { return }
            selection.wrappedValue = band
            if clicks == 2 {
                let on = address(band, .on)
                model.setOnce(on, model.value(on) >= 0.5 ? 0 : 1)
                return
            }
            if flags.contains(.command) {
                model.setOnce(address(band, .gain), 0)
                return
            }
            drag.band = band
            drag.start = point
            drag.frequency = Double(model.value(address(band, .frequency)))
            drag.gain = Double(model.value(address(band, .gain)))
            drag.q = Double(model.value(address(band, .q)))
            for field in [ChannelStripBandField.frequency, .gain, .q] {
                model.set(address(band, field), model.value(address(band, field)), event: .touch)
            }
        }
        mouse.dragged = { point, flags in
            guard let band = drag.band else { return }
            let fine = flags.contains(.shift) ? 0.1 : 1.0
            let dx = Double(point.x - drag.start.x) * fine
            let dy = Double(point.y - drag.start.y) * fine
            let isCut = (ChannelStripFilterType(rawValue: Int(model.value(address(band, .type)))) ?? .bell).isCut
            if flags.contains(.option) || isCut {
                // Up raises Q.
                model.set(address(band, .q), Float(drag.q * exp(-dy * 0.02)))
            }
            if !flags.contains(.option) {
                let octaves = log2(ChannelStripEQScale.highest / ChannelStripEQScale.lowest)
                let frequency = drag.frequency * pow(2, dx / Double(max(scale.size.width, 1)) * octaves)
                model.set(address(band, .frequency), Float(frequency))
                if !isCut {
                    var gain = drag.gain - dy * scale.decibelsPerPoint
                    // Settle on exactly 0 dB near it: a flat band costs nothing.
                    if abs(gain) < 0.3 { gain = 0 }
                    model.set(address(band, .gain), Float(gain))
                }
            }
        }
        mouse.up = {
            guard let band = drag.band else { return }
            for field in [ChannelStripBandField.frequency, .gain, .q] {
                model.set(address(band, field), model.value(address(band, field)), event: .release)
            }
            drag.band = nil
        }
        mouse.scrolled = { point, delta in
            let band = nearest(point) ?? selection.wrappedValue
            let q = address(band, .q)
            model.set(q, model.value(q) * Float(exp(Double(delta) * 0.03)))
        }
        return mouse
    }
}

/// An EQ node drag in progress.
final class ChannelStripEQDrag {
    var band: Int?
    var start = CGPoint.zero
    var frequency = 1_000.0
    var gain = 0.0
    var q = 1.0
}

// MARK: - Compressor curve

/// Studio One-style transfer curve, -60 to +6 dB both ways, with two
/// handles. The threshold point: drag across for threshold, up and down for
/// ratio (up toward 1:1). The ratio point, on the line above the threshold:
/// drag up and down and the line follows it. Anywhere else drags like the
/// threshold point. ⌥-drag or scroll for knee; ⇧ for fine steps;
/// double-click resets the three. The ring rides the curve at the
/// compressor's input level: white below the knee, yellow in it, orange
/// while compressing. With the compressor off the curve is the 1:1 line.
struct ChannelStripCompCurve: View {
    @ObservedObject var model: MyFXEditorModel
    @ObservedObject var display: ChannelStripDisplayModel
    @State private var mouse = ChannelStripMouseHandler()
    @State private var drag = ChannelStripCompDrag()

    static let lowest: Float = -60
    static let highest: Float = 6

    private struct Settings {
        var threshold: Float
        var ratio: Float
        var knee: Float
        var makeup: Float
        var isOn: Bool

        /// Off: the signal passes unchanged, so a straight 1:1 line.
        func output(_ x: Float) -> Float {
            guard isOn else { return x }
            return ChannelStripCompressorCurve.output(x, threshold: threshold, ratio: ratio, knee: knee) + makeup
        }

        /// Input level of the ratio point: 0 dB, or 6 dB above a threshold
        /// near 0, so it stays clear of the threshold point.
        var ratioInput: Float {
            min(ChannelStripCompCurve.highest - 1, max(0, threshold + 6))
        }

        /// The ratio that puts the curve's output at `ratioInput` on
        /// `target` (dB, makeup included); the curve falls as ratio rises.
        func ratio(reaching target: Float) -> Float {
            let x = ratioInput
            var low: Float = 1
            var high: Float = 20
            for _ in 0..<30 {
                let middle = (low + high) / 2
                let level = ChannelStripCompressorCurve.output(x, threshold: threshold, ratio: middle, knee: knee) + makeup
                if level > target { low = middle } else { high = middle }
            }
            return (low + high) / 2
        }
    }

    private var settings: Settings {
        let value = { (parameter: ChannelStripParameter) in model.value(parameter.address) }
        let threshold = value(.compThreshold)
        let ratio = value(.compRatio)
        let auto = value(.compAutoMakeup) >= 0.5
            ? ChannelStripCompressorCurve.autoMakeup(threshold: threshold, ratio: ratio) : 0
        return Settings(threshold: threshold, ratio: ratio, knee: value(.compKnee),
                        makeup: value(.compMakeup) + auto, isOn: value(.compOn) >= 0.5)
    }

    var body: some View {
        GeometryReader { geometry in
            let side = geometry.size.width
            let settings = settings
            ZStack {
                Canvas { context, _ in
                    draw(context, side: side, settings)
                }
                ChannelStripMouseSurface(handler: configuredMouse(side: side))
            }
        }
        .background(MyFXPalette.well)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private func point(_ input: Float, _ output: Float, _ side: CGFloat) -> CGPoint {
        let span = Self.highest - Self.lowest
        return CGPoint(x: CGFloat((input - Self.lowest) / span) * side,
                       y: side - CGFloat((output - Self.lowest) / span) * side)
    }

    private func draw(_ context: GraphicsContext, side: CGFloat, _ settings: Settings) {
        for level in stride(from: Float(-48), through: 0, by: 12) {
            let p = point(level, level, side)
            let color = level == 0 ? Color.white.opacity(0.2) : ChannelStripColors.grid
            context.stroke(Path { $0.move(to: CGPoint(x: p.x, y: 0)); $0.addLine(to: CGPoint(x: p.x, y: side)) },
                           with: .color(color), lineWidth: 1)
            context.stroke(Path { $0.move(to: CGPoint(x: 0, y: p.y)); $0.addLine(to: CGPoint(x: side, y: p.y)) },
                           with: .color(color), lineWidth: 1)
            context.draw(Text("\(Int(level))").font(.system(size: 6.5, weight: .medium))
                            .foregroundColor(ChannelStripColors.gridLabel),
                         at: CGPoint(x: p.x - 2, y: side - 5), anchor: .trailing)
        }
        // 1:1 for reference.
        context.stroke(Path { $0.move(to: point(Self.lowest, Self.lowest, side)); $0.addLine(to: point(Self.highest, Self.highest, side)) },
                       with: .color(Color.white.opacity(0.08)), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))

        var curve = Path()
        var x = Self.lowest
        curve.move(to: point(x, settings.output(x), side))
        while x < Self.highest {
            x = min(Self.highest, x + 0.5)
            curve.addLine(to: point(x, settings.output(x), side))
        }
        let tint = settings.isOn ? ChannelStripColors.compCurve : Color.gray
        context.stroke(curve, with: .color(tint), lineWidth: 1.6)

        // Handles at the threshold and the ratio point. Off: still there to
        // set them, faintly on the line.
        for input in [settings.threshold, settings.ratioInput] {
            let handle = point(input, settings.output(input), side)
            context.fill(Path(ellipseIn: CGRect(x: handle.x - 4, y: handle.y - 4, width: 8, height: 8)),
                         with: .color(tint.opacity(settings.isOn ? 1 : 0.5)))
        }

        // The level ring.
        let level = display.detector
        let input = max(level, Self.lowest)
        let ringColor: Color
        if !settings.isOn || input < settings.threshold - settings.knee / 2 {
            ringColor = .white
        } else if input <= settings.threshold + settings.knee / 2 {
            ringColor = .yellow
        } else {
            ringColor = ChannelStripColors.reduction
        }
        let ring = point(input, settings.output(input), side)
        context.stroke(Path(ellipseIn: CGRect(x: ring.x - 3.5, y: ring.y - 3.5, width: 7, height: 7)),
                       with: .color(ringColor.opacity(level < Self.lowest ? 0.35 : 1)), lineWidth: 1.5)
    }

    private func configuredMouse(side: CGFloat) -> ChannelStripMouseHandler {
        let model = model
        let drag = drag
        let decibelsPerPoint = Double(Self.highest - Self.lowest) / Double(max(side, 1))
        let all: [ChannelStripParameter] = [.compThreshold, .compRatio, .compKnee]

        mouse.down = { point, clicks, flags in
            drag.isActive = false
            if clicks == 2 {
                for parameter in all { model.setOnce(parameter.address, parameter.defaultValue) }
                return
            }
            drag.isActive = true
            drag.start = point
            let settings = settings
            let ratioPoint = self.point(settings.ratioInput, settings.output(settings.ratioInput), side)
            drag.isRatioPoint = settings.isOn && !flags.contains(.option)
                && hypot(point.x - ratioPoint.x, point.y - ratioPoint.y) <= 8
            drag.ratioOutput = Double(settings.output(settings.ratioInput))
            drag.threshold = Double(model.value(ChannelStripParameter.compThreshold.address))
            drag.ratioFraction = ChannelStripTaper.fraction(.compRatio, model.value(ChannelStripParameter.compRatio.address))
            drag.knee = Double(model.value(ChannelStripParameter.compKnee.address))
            for parameter in all { model.set(parameter.address, model.value(parameter.address), event: .touch) }
        }
        mouse.dragged = { point, flags in
            guard drag.isActive else { return }
            let fine = flags.contains(.shift) ? 0.1 : 1.0
            let dx = Double(point.x - drag.start.x) * fine
            let dy = Double(point.y - drag.start.y) * fine
            if drag.isRatioPoint {
                // The point follows the mouse up and down.
                let target = Float(drag.ratioOutput - dy * decibelsPerPoint)
                model.set(ChannelStripParameter.compRatio.address, settings.ratio(reaching: target))
            } else if flags.contains(.option) {
                model.set(ChannelStripParameter.compKnee.address, Float(drag.knee - dy * 24 / Double(side)))
            } else {
                model.set(ChannelStripParameter.compThreshold.address, Float(drag.threshold + dx * decibelsPerPoint))
                // Up toward 1:1.
                let fraction = drag.ratioFraction + dy / Double(side)
                model.set(ChannelStripParameter.compRatio.address, ChannelStripTaper.value(.compRatio, fraction))
            }
        }
        mouse.up = {
            guard drag.isActive else { return }
            for parameter in all { model.set(parameter.address, model.value(parameter.address), event: .release) }
            drag.isActive = false
        }
        mouse.scrolled = { _, delta in
            let knee = ChannelStripParameter.compKnee.address
            model.set(knee, model.value(knee) + Float(delta) * 0.5)
        }
        return mouse
    }
}

final class ChannelStripCompDrag {
    var isActive = false
    /// Dragging the ratio point (else the threshold point).
    var isRatioPoint = false
    /// The ratio point's output level (dB) when the drag started.
    var ratioOutput = 0.0
    var start = CGPoint.zero
    var threshold = 0.0
    var ratioFraction = 0.0
    var knee = 0.0
}

/// Gain reduction, 0 to -24 dB, growing down from the top.
struct ChannelStripReductionMeter: View {
    let reduction: Float

    var body: some View {
        GeometryReader { geometry in
            let fraction = CGFloat(min(max(-reduction / 24, 0), 1))
            ZStack(alignment: .top) {
                Rectangle().fill(MyFXPalette.well)
                Rectangle()
                    .fill(ChannelStripColors.reduction)
                    .frame(height: geometry.size.height * fraction)
                ForEach([6, 12, 18], id: \.self) { decibels in
                    Rectangle()
                        .fill(Color.white.opacity(0.25))
                        .frame(height: 1)
                        .offset(y: geometry.size.height * CGFloat(decibels) / 24)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .help("Gain reduction, 0 to -24 dB")
    }
}
