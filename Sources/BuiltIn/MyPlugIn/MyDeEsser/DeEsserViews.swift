import AppKit
import SwiftUI
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

// MyDeEsser's own editor parts: the band graph, the SIB and GR meters and
// the switch buttons. Type names start with "DeEsser" because MyDAW
// compiles these files into its own module.

enum DeEsserColors {
    /// Consonant reduction: THRESH, the SIB marker, GR, the graph's dip.
    static let reduction = Color(red: 0.95, green: 0.32, blue: 0.3)
    /// SIB level below THRESH.
    static let level = Color(red: 0.2, green: 0.72, blue: 0.72)
    static let listen = Color(red: 0.98, green: 0.82, blue: 0.2)
    static let link = Color(red: 0.38, green: 0.62, blue: 1.0)
}

// MARK: - Band graph

/// 500 Hz to 20 kHz (log) by +3 to -24 dB: the band above FREQ, and the
/// response |L + g·H| with the dip it makes filled red. Dragging sideways
/// moves FREQ with the pointer (⌘ fine, ⌥-click resets).
struct DeEsserBandGraph: View {
    static let lowFrequency = 500.0
    static let highFrequency = 20_000.0
    static let topDecibels = 3.0
    static let bottomDecibels = -24.0

    let frequency: Double
    let gain: Double
    let sampleRate: Double
    let isListening: Bool
    let isBypassed: Bool
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard dragStart != nil || drag.translation.width != 0 else { return }
                        if dragStart == nil {
                            dragStart = frequency
                            onBegin()
                        }
                        let fine = NSEvent.modifierFlags.contains(.command) ? 0.15 : 1.0
                        let octaves = Double(drag.translation.width / geometry.size.width)
                            * log2(Self.highFrequency / Self.lowFrequency) * fine
                        onChange((dragStart ?? frequency) * pow(2, octaves))
                    }
                    .onEnded { _ in
                        if dragStart != nil { onEnd() }
                        dragStart = nil
                    }
            )
            .simultaneousGesture(TapGesture().modifiers(.option).onEnded(onReset))
        }
    }

    static func x(_ frequency: Double, width: CGFloat) -> CGFloat {
        width * CGFloat(log(frequency / lowFrequency) / log(highFrequency / lowFrequency))
    }

    static func y(_ decibels: Double, height: CGFloat) -> CGFloat {
        let clamped = min(max(decibels, bottomDecibels), topDecibels)
        return height * CGFloat((topDecibels - clamped) / (topDecibels - bottomDecibels))
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let width = size.width
        let height = size.height
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(MyFXPalette.well))

        // Grid.
        let label = Font.system(size: 7, weight: .medium, design: .monospaced)
        for decibels in [0.0, -6, -12, -18] {
            let y = Self.y(decibels, height: height)
            context.fill(Path(CGRect(x: 0, y: y, width: width, height: 0.5)),
                         with: .color(.white.opacity(decibels == 0 ? 0.3 : 0.12)))
            if decibels < 0 {
                context.draw(Text(String(format: "%.0f", decibels)).font(label).foregroundColor(.white.opacity(0.4)),
                             at: CGPoint(x: 3, y: y - 1), anchor: .bottomLeading)
            }
        }
        for (frequency, name) in [(1_000.0, "1k"), (2_000, "2k"), (5_000, "5k"), (10_000, "10k")] {
            let x = Self.x(frequency, width: width)
            context.fill(Path(CGRect(x: x, y: 0, width: 0.5, height: height)), with: .color(.white.opacity(0.12)))
            context.draw(Text(name).font(label).foregroundColor(.white.opacity(0.4)),
                         at: CGPoint(x: x + 2, y: height - 2), anchor: .bottomLeading)
        }

        // The consonant band and FREQ.
        let split = Self.x(frequency, width: width)
        context.fill(Path(CGRect(x: split, y: 0, width: width - split, height: height)),
                     with: .color(DeEsserColors.reduction.opacity(isBypassed ? 0.04 : 0.1)))
        var line = Path()
        line.move(to: CGPoint(x: split, y: 0))
        line.addLine(to: CGPoint(x: split, y: height))
        context.stroke(line, with: .color(DeEsserColors.reduction.opacity(0.9)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 2]))

        // Response with the current reduction.
        let points = 160
        let gain = isBypassed ? 1 : gain
        var curve = Path()
        var fill = Path()
        let zero = Self.y(0, height: height)
        fill.move(to: CGPoint(x: 0, y: zero))
        for index in 0...points {
            let x = width * CGFloat(index) / CGFloat(points)
            let f = Self.lowFrequency * pow(Self.highFrequency / Self.lowFrequency, Double(index) / Double(points))
            let response = DeEsserCrossover.response(at: f, crossover: frequency, gain: gain, sampleRate: sampleRate)
            let point = CGPoint(x: x, y: Self.y(20 * log10(max(response, 1e-6)), height: height))
            if index == 0 { curve.move(to: point) } else { curve.addLine(to: point) }
            fill.addLine(to: point)
        }
        fill.addLine(to: CGPoint(x: width, y: zero))
        fill.closeSubpath()
        if gain < 1 {
            context.fill(fill, with: .color(DeEsserColors.reduction.opacity(0.55)))
        }
        context.stroke(curve, with: .color(isBypassed ? .gray : .white.opacity(0.9)), lineWidth: 1.5)

        // Captions.
        let caption = Font.system(size: 8, weight: .bold)
        context.draw(Text(String(format: "%.2f kHz", frequency / 1_000)).font(caption)
                        .foregroundColor(DeEsserColors.reduction),
                     at: CGPoint(x: min(split + 3, width - 46), y: 3), anchor: .topLeading)
        if isListening {
            context.draw(Text("LISTEN").font(caption).foregroundColor(DeEsserColors.listen),
                         at: CGPoint(x: width - 4, y: height - 3), anchor: .bottomTrailing)
        }
    }
}

// MARK: - Meters

/// -60 to 0 dB, linear in dB, for the SIB meter and its ticks.
enum DeEsserSibilanceScale {
    static let floor: Double = -60
    static let ticks: [Double] = [-60, -48, -36, -24, -12, 0]

    static func fraction(forDecibels decibels: Double) -> Double {
        min(max((decibels - floor) / -floor, 0), 1)
    }

    static func fraction(forLevel level: Float) -> Double {
        level > 0 ? fraction(forDecibels: 20 * log10(Double(level))) : 0
    }
}

/// The high band's level, L over R, teal up to THRESH and red above it,
/// with THRESH as a red marker. Dragging sideways moves THRESH (relative,
/// ⌘ fine, ⌥-click resets).
struct DeEsserSibilanceMeter: View {
    let state: MyFXMeterState
    let threshold: Double
    let onBegin: () -> Void
    let onChange: (Double) -> Void
    let onEnd: () -> Void
    let onReset: () -> Void
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let mark = CGFloat(DeEsserSibilanceScale.fraction(forDecibels: threshold)) * width
            ZStack(alignment: .leading) {
                VStack(spacing: 1) {
                    bar(level: state.left, hold: state.holdLeft, width: width, mark: mark)
                    bar(level: state.right, hold: state.holdRight, width: width, mark: mark)
                }
                Rectangle()
                    .fill(DeEsserColors.reduction)
                    .frame(width: 2)
                    .offset(x: min(max(0, mark - 1), width - 2))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        guard dragStart != nil || drag.translation.width != 0 else { return }
                        if dragStart == nil {
                            dragStart = threshold
                            onBegin()
                        }
                        let fine = NSEvent.modifierFlags.contains(.command) ? 0.15 : 1.0
                        let decibels = Double(drag.translation.width / width) * -DeEsserSibilanceScale.floor * fine
                        onChange((dragStart ?? threshold) + decibels)
                    }
                    .onEnded { _ in
                        if dragStart != nil { onEnd() }
                        dragStart = nil
                    }
            )
            .simultaneousGesture(TapGesture().modifiers(.option).onEnded(onReset))
        }
    }

    private func bar(level: Float, hold: Float, width: CGFloat, mark: CGFloat) -> some View {
        let length = CGFloat(DeEsserSibilanceScale.fraction(forLevel: level)) * width
        let holdPosition = CGFloat(DeEsserSibilanceScale.fraction(forLevel: hold)) * width
        return ZStack(alignment: .leading) {
            Rectangle().fill(MyFXPalette.well)
            Rectangle().fill(DeEsserColors.level).frame(width: min(length, mark))
            if length > mark {
                Rectangle().fill(DeEsserColors.reduction).frame(width: length - mark).offset(x: mark)
            }
            if holdPosition > 0 {
                Rectangle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 1)
                    .offset(x: max(0, holdPosition - 1))
            }
        }
    }
}

/// Gain reduction, L over R, growing red leftward from 0 dB at the right
/// end to -24 dB at the left.
struct DeEsserReductionMeter: View {
    static let range: Float = 24
    let left: Float
    let right: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                VStack(spacing: 1) {
                    bar(left, width: geometry.size.width)
                    bar(right, width: geometry.size.width)
                }
                Text("-24")
                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.leading, 2)
            }
        }
    }

    private func bar(_ reduction: Float, width: CGFloat) -> some View {
        let length = CGFloat(min(1, max(0, -reduction / Self.range))) * width
        return ZStack(alignment: .trailing) {
            Rectangle().fill(MyFXPalette.well)
            Rectangle().fill(DeEsserColors.reduction).frame(width: length)
        }
    }
}

/// A meter row's readout: the value in a well; clicking clears it.
struct DeEsserReadout: View {
    let text: String
    let color: Color
    let onClear: () -> Void

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundColor(color)
            .frame(width: MyFXMeterRow.readoutWidth, height: 14)
            .background(RoundedRectangle(cornerRadius: 2).fill(MyFXPalette.well))
            .contentShape(Rectangle())
            .onTapGesture(perform: onClear)
            .help("Peak since last click")
    }
}

// MARK: - Buttons

/// An on/off parameter as a text button, lit in `tint` when on.
struct DeEsserButton: View {
    let parameter: DeEsserParameter
    @ObservedObject var model: MyFXEditorModel
    let tint: Color

    var body: some View {
        let isOn = model.value(parameter.address) >= 0.5
        Text(parameter.displayName)
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(isOn ? .black.opacity(0.85) : MyFXPalette.heading)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 3).fill(isOn ? tint : MyFXPalette.well))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(MyFXPalette.border, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture { model.setOnce(parameter.address, isOn ? 0 : 1) }
    }
}
