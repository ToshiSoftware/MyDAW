import AudioToolbox
import SwiftUI
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

// MyTuner's editor (Docs/MyTuner.md §1): a needle meter (or the strobe
// band), the note with flat/sharp arrows, Hz and cents readouts, and the
// mode, strobe and calibration controls. It replaces MyFXEditorView: a
// tuner has no IN/OUT meters or faders.

enum TunerColours {
    static let accent = Color(red: 0.25, green: 0.63, blue: 1.0)
    static let inTune = Color(red: 0.32, green: 0.9, blue: 0.45)
    static let orange = Color(red: 1.0, green: 0.62, blue: 0.25)
}

struct TunerEditorView: View {
    @ObservedObject var model: MyFXEditorModel
    @ObservedObject var display: TunerDisplayModel

    private var calibration: Double { Double(model.value(TunerParameter.calibration.address)) }
    private var mode: TunerMode {
        TunerMode(rawValue: Int(model.value(TunerParameter.mode.address).rounded())) ?? .chromatic
    }
    private var isStrobe: Bool { model.value(TunerParameter.strobe.address) >= 0.5 }

    var body: some View {
        let state = display.state
        let note = state.note(calibration: calibration, mode: mode)
        let colour = state.isInTune ? TunerColours.inTune : TunerColours.accent
        VStack(spacing: 6) {
            HStack(alignment: .center) {
                Text("MyTuner")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.75))
                Spacer()
                MyFXMenuPicker(options: TunerMode.allCases.map(\.displayName), selection: mode.rawValue) { index in
                    model.setOnce(TunerParameter.mode.address, Float(index))
                }
            }
            .padding(.horizontal, 4)
            .frame(height: 24)
            MyFXStrip {
                TunerMeter(state: state, isStrobe: isStrobe, colour: colour)
                    .frame(height: 128)
            }
            MyFXStrip {
                VStack(spacing: 4) {
                    TunerNoteRow(state: state, note: note, colour: colour)
                        .frame(height: 46)
                    TunerReadouts(state: state, note: note)
                }
                .padding(.vertical, 6)
            }
            MyFXStrip {
                controls
                    .padding(.horizontal, 8)
                    .frame(height: 30)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .frame(minWidth: 300, maxWidth: .infinity, minHeight: MyTunerAudioUnit.editorSize.height,
               maxHeight: .infinity)
        .background(MyFXPalette.background)
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Text("STROBE")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(isStrobe ? .black.opacity(0.85) : MyFXPalette.heading)
                .frame(width: 58, height: 20)
                .background(RoundedRectangle(cornerRadius: 3).fill(isStrobe ? TunerColours.orange : MyFXPalette.well))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(MyFXPalette.border, lineWidth: 1))
                .contentShape(Rectangle())
                .onTapGesture { model.setOnce(TunerParameter.strobe.address, isStrobe ? 0 : 1) }
                .help("Strobe display: the stripes stand still when in tune")
            Spacer(minLength: 4)
            Text("CAL")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(MyFXPalette.heading)
            TunerStepButton(symbol: "minus") { step(-0.5) }
            MyFXEditableValue(text: TunerParameter.calibration.displayString(for: Float(calibration))) { text in
                if let value = TunerParameter.calibration.value(fromDisplayString: text) {
                    model.setOnce(TunerParameter.calibration.address, value)
                }
            }
            .frame(width: 66, height: 20)
            .background(RoundedRectangle(cornerRadius: 3).fill(MyFXPalette.well))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(MyFXPalette.border, lineWidth: 1))
            .help("Calibration: the pitch of A4 (430 to 450 Hz). Double-click to type.")
            TunerStepButton(symbol: "plus") { step(0.5) }
        }
    }

    private func step(_ hertz: Float) {
        let parameter = TunerParameter.calibration
        model.setOnce(parameter.address, parameter.clamped(Float(calibration) + hertz))
    }
}

struct TunerStepButton: View {
    let symbol: String
    let action: () -> Void

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(MyFXPalette.value)
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 3).fill(MyFXPalette.well))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(MyFXPalette.border, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
    }
}

// MARK: - Meter

/// The −50 to +50 cents scale on an arc bowed upwards, with a needle from a
/// pivot below the view, or in strobe mode a band of moving stripes.
struct TunerMeter: View {
    /// Half the scale's angle: ±50 cents swing the needle ±50°.
    static let halfAngle = 50.0 * Double.pi / 180

    let state: TunerDisplayState
    let isStrobe: Bool
    let colour: Color

    var body: some View {
        Canvas { context, size in
            let radius = size.height + 12
            let pivot = CGPoint(x: size.width / 2, y: size.height + radius - 104)
            let dim = 0.35 + 0.65 * state.brightness
            func point(_ cents: Double, _ distance: Double) -> CGPoint {
                let angle = cents / 50 * Self.halfAngle
                return CGPoint(x: pivot.x + distance * sin(angle), y: pivot.y - distance * cos(angle))
            }

            // Arc and ticks.
            var arc = Path()
            arc.addArc(center: pivot, radius: radius, startAngle: .radians(-.pi / 2 - Self.halfAngle),
                       endAngle: .radians(-.pi / 2 + Self.halfAngle), clockwise: false)
            let arcColour = state.frequency == nil ? MyFXPalette.heading : colour
            context.stroke(arc, with: .color(arcColour.opacity(0.35 * dim)), lineWidth: 6)
            context.stroke(arc, with: .color(arcColour.opacity(dim)), lineWidth: 1.5)
            for cents in stride(from: -50, through: 50, by: 10) {
                let isCentre = cents == 0
                var tick = Path()
                tick.move(to: point(Double(cents), radius + 2))
                tick.addLine(to: point(Double(cents), radius + (isCentre ? 16 : 7)))
                context.stroke(tick, with: .color(.white.opacity(isCentre ? 0.8 : 0.4)), lineWidth: isCentre ? 2 : 1)
            }
            let labelFont = Font.system(size: 9, weight: .semibold)
            context.draw(Text("−50 ct").font(labelFont).foregroundColor(MyFXPalette.heading),
                         at: CGPoint(x: point(-50, radius).x + 14, y: point(-50, radius).y + 32))
            context.draw(Text("+50 ct").font(labelFont).foregroundColor(MyFXPalette.heading),
                         at: CGPoint(x: point(50, radius).x - 14, y: point(50, radius).y + 32))

            if isStrobe {
                drawStrobe(in: context, pivot: pivot, radius: radius)
            } else if state.frequency != nil {
                var needle = Path()
                needle.move(to: point(state.needleCents, radius - 120))
                needle.addLine(to: point(state.needleCents, radius + 12))
                let needleColour = colour.opacity(state.brightness)
                context.stroke(needle, with: .color(needleColour.opacity(0.3)),
                               style: StrokeStyle(lineWidth: 6, lineCap: .round))
                context.stroke(needle, with: .color(needleColour), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
        .drawingGroup()
    }

    /// Stripes inside the arc, moving right when sharp and left when flat.
    private func drawStrobe(in context: GraphicsContext, pivot: CGPoint, radius: Double) {
        let inner = radius - 26
        let outer = radius - 10
        let stripes = 24
        let stripeAngle = 2 * Self.halfAngle / Double(stripes)
        let isSounding = state.frequency != nil
        let colour = (state.isInTune ? TunerColours.inTune : TunerColours.accent)
            .opacity(isSounding ? state.brightness : 0.2)
        var clip = Path()
        clip.addArc(center: pivot, radius: outer, startAngle: .radians(-.pi / 2 - Self.halfAngle),
                    endAngle: .radians(-.pi / 2 + Self.halfAngle), clockwise: false)
        clip.addArc(center: pivot, radius: inner, startAngle: .radians(-.pi / 2 + Self.halfAngle),
                    endAngle: .radians(-.pi / 2 - Self.halfAngle), clockwise: true)
        clip.closeSubpath()
        var band = context
        band.clip(to: clip)
        band.fill(clip, with: .color(Color.black.opacity(0.45)))
        for index in -1...stripes {
            let start = -.pi / 2 - Self.halfAngle + (Double(index) + state.strobePhase) * stripeAngle
            var stripe = Path()
            stripe.move(to: CGPoint(x: pivot.x + inner * cos(start), y: pivot.y + inner * sin(start)))
            stripe.addArc(center: pivot, radius: outer + 1, startAngle: .radians(start),
                          endAngle: .radians(start + stripeAngle / 2), clockwise: false)
            stripe.addArc(center: pivot, radius: inner - 1, startAngle: .radians(start + stripeAngle / 2),
                          endAngle: .radians(start), clockwise: true)
            stripe.closeSubpath()
            band.fill(stripe, with: .color(colour))
        }
    }
}

// MARK: - Note and readouts

/// ▶ (flat) note ◀ (sharp); both lit and green when in tune.
struct TunerNoteRow: View {
    let state: TunerDisplayState
    let note: TunerNote?
    let colour: Color

    var body: some View {
        let isSounding = note != nil
        let flatLit = isSounding && (state.isInTune || state.needleCents < -TunerDisplayState.inTuneCents)
        let sharpLit = isSounding && (state.isInTune || state.needleCents > TunerDisplayState.inTuneCents)
        HStack(spacing: 0) {
            arrow("arrowtriangle.right.fill", lit: flatLit)
                .help("Flat: tune up")
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(note?.name ?? "–")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundColor(isSounding ? (state.isInTune ? TunerColours.inTune : MyFXPalette.value)
                        : MyFXPalette.heading)
                Text(note.map { "\($0.octave)" } ?? "")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(MyFXPalette.heading)
                    .frame(minWidth: 10, alignment: .leading)
            }
            .opacity(isSounding ? 0.4 + 0.6 * state.brightness : 1)
            .frame(width: 110)
            .overlay(alignment: .trailing) {
                if let string = note?.guitarString {
                    Text("\(string)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(MyFXPalette.value)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().stroke(MyFXPalette.heading, lineWidth: 1))
                        .offset(x: 6)
                        .help("Guitar string")
                }
            }
            arrow("arrowtriangle.left.fill", lit: sharpLit)
                .help("Sharp: tune down")
        }
        .frame(maxWidth: .infinity)
    }

    private func arrow(_ symbol: String, lit: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 22))
            .foregroundColor(lit ? colour.opacity(0.4 + 0.6 * state.brightness) : Color.white.opacity(0.12))
            .frame(width: 60)
    }
}

/// Frequency | Difference.
struct TunerReadouts: View {
    let state: TunerDisplayState
    let note: TunerNote?

    var body: some View {
        HStack(spacing: 0) {
            readout(state.frequency.map { String(format: "%.1f Hz", $0) } ?? "— Hz", label: "Frequency")
            Rectangle()
                .fill(MyFXPalette.border)
                .frame(width: 1, height: 30)
            readout(note.map { String(format: "%+.1f cents", $0.cents).replacingOccurrences(of: "-", with: "−") }
                        ?? "— cents",
                    label: "Difference")
        }
    }

    private func readout(_ value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                .foregroundColor(note == nil ? MyFXPalette.heading : MyFXPalette.value)
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(MyFXPalette.heading)
        }
        .frame(maxWidth: .infinity)
    }
}
