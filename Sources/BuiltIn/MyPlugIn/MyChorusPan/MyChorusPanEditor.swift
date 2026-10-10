import AudioToolbox
import SwiftUI
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

// MyChorusPan's editor (Docs/MyChorusPan.md §1): INIT and the mode menu in
// the header, a row of buttons (LFO waveforms, or Dimension's 1 to 4) with
// the SPEED lamp, then the faders of the current mode.

// MARK: - Faders

enum ChorusPanFaderTaper {
    /// The faders shown in `mode`, left to right.
    static func faders(for mode: ChorusPanMode) -> [ChorusPanParameter] {
        switch mode {
        case .chorus:
            return [.chorusDelay, .chorusDepth, .chorusSpeed, .chorusLFOWidth, .chorusStereoWidth, .chorusMix]
        case .dimension:
            return [.dimensionStereoWidth, .dimensionMix]
        case .flanger:
            return [.flangerDelay, .flangerDepth, .flangerFeedback, .flangerSpeed, .flangerLFOWidth,
                    .flangerStereoWidth, .flangerMix]
        case .autoPan:
            return [.panSpeed, .panWidth]
        }
    }

    /// The buttons' parameter in `mode`: a waveform, or Dimension's 1 to 4.
    static func buttons(for mode: ChorusPanMode) -> ChorusPanParameter {
        switch mode {
        case .chorus: return .chorusLFOType
        case .dimension: return .dimensionMode
        case .flanger: return .flangerLFOType
        case .autoPan: return .panType
        }
    }

    /// DELAY and SPEED logarithmic; the rest linear (FDBK has 0 in the middle).
    static func fraction(for parameter: ChorusPanParameter, value: Float) -> Double {
        let value = Double(parameter.clamped(value))
        let lower = Double(parameter.range.lowerBound)
        let upper = Double(parameter.range.upperBound)
        if parameter.isLogarithmic {
            return log(value / lower) / log(upper / lower)
        }
        return (value - lower) / (upper - lower)
    }

    static func value(for parameter: ChorusPanParameter, fraction: Double) -> Float {
        let fraction = min(max(fraction, 0), 1)
        let lower = Double(parameter.range.lowerBound)
        let upper = Double(parameter.range.upperBound)
        if parameter.isLogarithmic {
            return parameter.clamped(Float(lower * pow(upper / lower, fraction)))
        }
        return parameter.clamped(Float(lower + fraction * (upper - lower)))
    }
}

// MARK: - SPEED lamp

/// The lamp's brightness (0 to 1), following the current mode's LFO like a
/// pedal's LED. Polled 60 times a second while the editor is visible; the
/// kernel publishes the LFO's phase after each render. Main thread only.
final class ChorusPanLampModel: ObservableObject {
    @Published var level = 0.0

    private static let interval = 1.0 / 60
    private weak var kernel: ChorusPanKernel?
    private let isVisible: () -> Bool
    private var timer: Timer?

    init(kernel: ChorusPanKernel, isVisible: @escaping () -> Bool) {
        self.kernel = kernel
        self.isVisible = isVisible
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    deinit {
        timer?.invalidate()
    }

    private func poll() {
        guard let kernel, isVisible() else { return }
        let lamp = kernel.lamp
        let next = (Double(ChorusPanLFO.value(lamp.wave, at: lamp.phase)) + 1) / 2
        if abs(next - level) > 0.004 {
            level = next
        }
    }
}

struct ChorusPanLamp: View {
    let level: Double

    var body: some View {
        let colour = Color(red: 1.0, green: 0.42, blue: 0.12)
        Circle()
            .fill(colour.opacity(0.12 + 0.88 * level))
            .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1))
            .shadow(color: colour.opacity(0.8 * level), radius: 4 * level)
            .frame(width: 10, height: 10)
    }
}

// MARK: - Waveform buttons

/// One cycle of a waveform, drawn in the given box.
struct ChorusPanWaveIcon: Shape {
    let wave: ChorusPanWave

    func path(in rect: CGRect) -> Path {
        func point(_ phase: Double, _ value: Double) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * phase, y: rect.midY - rect.height / 2 * value)
        }
        var path = Path()
        switch wave {
        case .sine:
            path.move(to: point(0, 0))
            for step in 1...32 {
                let phase = Double(step) / 32
                path.addLine(to: point(phase, sin(2 * Double.pi * phase)))
            }
        case .triangle:
            path.addLines([point(0, 0), point(0.25, 1), point(0.75, -1), point(1, 0)])
        case .saw:
            path.addLines([point(0, -1), point(1, 1), point(1, -1)])
        case .square:
            path.addLines([point(0, 1), point(0.5, 1), point(0.5, -1), point(1, -1)])
        }
        return path
    }
}

/// A selection button (a waveform or a number), lit orange when chosen.
struct ChorusPanButton<Label: View>: View {
    static var orange: Color { Color(red: 1.0, green: 0.62, blue: 0.25) }
    static var red: Color { Color(red: 0.92, green: 0.2, blue: 0.18) }

    let isOn: Bool
    var width: CGFloat = 30
    var litColour: Color = ChorusPanButton.orange
    let help: String
    let action: () -> Void
    @ViewBuilder let label: (Color) -> Label

    var body: some View {
        label(isOn ? Color.black.opacity(0.85) : MyFXPalette.heading)
            .frame(width: width, height: 20)
            .background(RoundedRectangle(cornerRadius: 3)
                .fill(isOn ? litColour : MyFXPalette.well))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(MyFXPalette.border, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .help(help)
    }
}

/// The header's INIT: back to the current mode's recommended settings.
struct ChorusPanInitButton: View {
    let action: () -> Void

    var body: some View {
        Text("INIT")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(MyFXPalette.value)
            .frame(width: 36, height: 20)
            .background(RoundedRectangle(cornerRadius: 3).fill(MyFXPalette.well))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(MyFXPalette.border, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .help("Recommended settings for this mode")
    }
}

// MARK: - Editor

struct ChorusPanEditorView: View {
    @ObservedObject var model: MyFXEditorModel
    @ObservedObject var lamp: ChorusPanLampModel

    private var mode: ChorusPanMode {
        ChorusPanMode(rawValue: Int(model.value(ChorusPanParameter.mode.address))) ?? .chorus
    }

    var body: some View {
        MyFXEditorView(model: model, title: "MyChorusPan") {
            HStack(spacing: 6) {
                ChorusPanInitButton(action: initialise)
                MyFXMenuPicker(options: ChorusPanMode.allCases.map(\.displayName), selection: mode.rawValue) { index in
                    model.setOnce(ChorusPanParameter.mode.address, Float(index))
                }
            }
        } faders: {
            VStack(spacing: 12) {
                buttonRow
                HStack(spacing: 0) {
                    ForEach(ChorusPanFaderTaper.faders(for: mode), id: \.self) { parameter in
                        fader(parameter)
                    }
                }
                // Two faders would stretch across the strip; keep them fader-wide.
                .padding(.horizontal, ChorusPanFaderTaper.faders(for: mode).count == 2 ? 64 : 0)
            }
        }
    }

    /// INIT: the current mode's parameters back to their recommended values.
    private func initialise() {
        for parameter in mode.parameters {
            model.setOnce(parameter.address, parameter.defaultValue)
        }
    }

    private var buttonRow: some View {
        let parameter = ChorusPanFaderTaper.buttons(for: mode)
        let selected = Int(model.value(parameter.address))
        let title: String
        switch mode {
        case .chorus, .flanger: title = "LFO"
        case .dimension: title = "MODE"
        case .autoPan: title = "PAN"
        }
        return HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(MyFXPalette.heading)
                .frame(width: 30, alignment: .leading)
            if mode == .dimension {
                // 1 to 3 choose one; 4 is a switch that works with them.
                ForEach(0..<ChorusPanDimensionSetting.delaysMilliseconds.count, id: \.self) { index in
                    ChorusPanButton(isOn: index == selected, help: "Dimension \(index + 1)",
                                    action: { model.setOnce(parameter.address, Float(index)) }) { colour in
                        Text("\(index + 1)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(colour)
                    }
                }
                let boost = ChorusPanParameter.dimensionBoost.address
                let isBoosted = model.value(boost) >= 0.5
                // The SDD-320's button 4: wider and red, as a switch apart from 1 to 3.
                ChorusPanButton(isOn: isBoosted, width: 58, litColour: ChorusPanButton<Text>.red,
                                help: "BOOST (button 4): louder effect, with 1 to 3",
                                action: { model.setOnce(boost, isBoosted ? 0 : 1) }) { colour in
                    Text("BOOST")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(isBoosted ? .white : colour)
                }
            } else {
                ForEach(ChorusPanWave.allCases, id: \.self) { wave in
                    ChorusPanButton(isOn: wave.rawValue == selected, help: wave.displayName,
                                    action: { model.setOnce(parameter.address, Float(wave.rawValue)) }) { colour in
                        ChorusPanWaveIcon(wave: wave)
                            .stroke(colour, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                            .frame(width: 18, height: 9)
                    }
                }
            }
            Spacer(minLength: 4)
            Text("SPEED")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(MyFXPalette.heading)
            ChorusPanLamp(level: lamp.level)
        }
        .padding(.horizontal, 6)
    }

    private func fader(_ parameter: ChorusPanParameter) -> MyFXFaderColumn {
        MyFXFaderColumn(
            parameter: parameter,
            model: model,
            fraction: { ChorusPanFaderTaper.fraction(for: parameter, value: $0) },
            value: { ChorusPanFaderTaper.value(for: parameter, fraction: $0) }
        )
    }
}
