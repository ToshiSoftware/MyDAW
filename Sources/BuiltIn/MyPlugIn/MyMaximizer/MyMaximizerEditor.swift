import AudioToolbox
import SwiftUI
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

// MyMaximizer's editor, 300 x 460: header, channel name, IN/OUT meters with
// CLIP lamps, the history graph and the faders (INPUT, UPWARD, then the
// limiter's THRESH, ATTACK, RELEASE and OUTPUT). Built from MyPlugInCore's parts so
// it matches the other effects; type names start with "Maximizer" because
// MyDAW compiles this file into its own module.

/// Fader travel (0 = bottom, 1 = top): RELEASE is logarithmic (10 ms to
/// 500 ms), the rest linear in their ranges.
enum MaximizerTaper {
    static func fraction(_ parameter: MaximizerParameter, _ value: Float) -> Double {
        let low = Double(parameter.range.lowerBound)
        let high = Double(parameter.range.upperBound)
        let value = Double(parameter.clamped(value))
        if parameter == .release { return log(value / low) / log(high / low) }
        return (value - low) / (high - low)
    }

    static func value(_ parameter: MaximizerParameter, _ fraction: Double) -> Float {
        let fraction = min(max(fraction, 0), 1)
        let low = Double(parameter.range.lowerBound)
        let high = Double(parameter.range.upperBound)
        let raw = parameter == .release ? low * pow(high / low, fraction) : low + fraction * (high - low)
        var value = parameter.clamped(Float(raw))
        // INPUT settles on exactly 0 dB near it: unity gain costs nothing.
        if parameter == .inputGain && abs(value) < 0.3 { value = 0 }
        return value
    }
}

struct MaximizerEditorView: View {
    @ObservedObject var model: MyFXEditorModel
    @ObservedObject var display: MaximizerDisplayModel

    var body: some View {
        VStack(spacing: 4) {
            header
            MyFXChannelLabel(name: model.channelName)
            meters
            graph
            faders
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(minWidth: 300, maxWidth: .infinity, minHeight: 460, maxHeight: .infinity, alignment: .top)
        .background(MyFXPalette.background)
    }

    // MARK: Header and meters

    private var header: some View {
        HStack {
            Text("MyMaximizer")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white.opacity(0.75))
            Spacer()
            MyFXSubtitle(String(format: "LIMITER %.0f ms", display.latencyMilliseconds))
                .help("Look-ahead: the output lags by this much; the host compensates")
        }
        .padding(.horizontal, 2)
        .frame(height: 20)
    }

    private var meters: some View {
        MyFXStrip {
            VStack(spacing: 6) {
                MyFXMeterRow(label: "IN", state: model.input, showsClip: true) { model.input.clearPeaks() }
                MyFXMeterRow(label: "OUT", state: model.output, showsClip: true) { model.output.clearPeaks() }
                MyFXMeterTicks()
                    .frame(height: 9)
                    .padding(.leading, MyFXMeterRow.labelWidth + 6)
                    .padding(.trailing, MyFXMeterRow.readoutWidth + MyFXMeterRow.clipWidth + 12)
            }
            .padding(8)
        }
    }

    // MARK: Graph

    private var graph: some View {
        let merge = Int(display.span / MaximizerHistory.spans[0])
        return MyFXStrip {
            VStack(spacing: 4) {
                MaximizerGraph(columns: display.columns, firstIndex: display.firstIndex, merge: merge,
                               ceiling: model.value(MaximizerParameter.outputLevel.address),
                               threshold: model.value(MaximizerParameter.threshold.address))
                    // One point per point of width: scrolling moves whole pixels.
                    .frame(width: CGFloat(MaximizerHistory.viewColumns), height: 120)
                    .contentShape(Rectangle())
                    .onTapGesture { display.nextSpan() }
                    .help("Level (teal), limiter reduction (red; THRESH dotted), upward boost (green); click for 3 / 6 / 12 s")
                readouts
                    .padding(.horizontal, 6)
            }
            .padding(.vertical, 6)
        }
    }

    private var readouts: some View {
        HStack(spacing: 10) {
            readout("GR", String(format: "%.1f dB", display.reduction), color: MaximizerColors.reduction)
            readout("UP", String(format: "%+.1f dB", display.boost), color: MaximizerColors.upward)
            Spacer(minLength: 0)
            Text(String(format: "%.0f s", display.span))
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(MyFXPalette.heading)
        }
        .frame(height: 14)
    }

    private func readout(_ name: String, _ value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(name)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(MyFXPalette.heading)
            Text(value)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
                .frame(width: 52, height: 14)
                .background(RoundedRectangle(cornerRadius: 2).fill(MyFXPalette.well))
        }
    }

    // MARK: Faders

    private var faders: some View {
        MyFXStrip {
            HStack(spacing: 0) {
                fader(.inputGain)
                fader(.upward, nameColor: MaximizerColors.upward)
                fader(.threshold)
                fader(.attack)
                fader(.release)
                fader(.outputLevel)
            }
            .padding(.horizontal, 2)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .frame(height: 180)
    }

    private func fader(_ parameter: MaximizerParameter, nameColor: Color = MyFXPalette.heading) -> some View {
        MyFXFaderColumn(
            parameter: parameter,
            model: model,
            nameColor: nameColor,
            fraction: { MaximizerTaper.fraction(parameter, $0) },
            value: { MaximizerTaper.value(parameter, $0) }
        )
    }
}
