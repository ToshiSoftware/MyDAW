import AudioToolbox
import SwiftUI
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

// MyDeEsser's editor, 300 x 500: header, channel name, IN/OUT meters with
// CLIP lamps, the band graph, the consonant section (STEREO LINK, LISTEN,
// SIB and GR meters) and the faders (INPUT, FREQ, THRESH, ATTACK,
// RELEASE). Built from MyPlugInCore's parts so it matches the other
// effects; type names start with "DeEsser" because MyDAW compiles this
// file into its own module.

/// Fader travel (0 = bottom, 1 = top): FREQ and RELEASE are logarithmic,
/// the rest linear in their ranges.
enum DeEsserTaper {
    static func fraction(_ parameter: DeEsserParameter, _ value: Float) -> Double {
        let low = Double(parameter.range.lowerBound)
        let high = Double(parameter.range.upperBound)
        let value = Double(parameter.clamped(value))
        if isLogarithmic(parameter) { return log(value / low) / log(high / low) }
        return (value - low) / (high - low)
    }

    static func value(_ parameter: DeEsserParameter, _ fraction: Double) -> Float {
        let fraction = min(max(fraction, 0), 1)
        let low = Double(parameter.range.lowerBound)
        let high = Double(parameter.range.upperBound)
        let raw = isLogarithmic(parameter) ? low * pow(high / low, fraction) : low + fraction * (high - low)
        var value = parameter.clamped(Float(raw))
        // INPUT settles on exactly 0 dB near it: unity gain costs nothing.
        if parameter == .inputGain && abs(value) < 0.3 { value = 0 }
        return value
    }

    private static func isLogarithmic(_ parameter: DeEsserParameter) -> Bool {
        parameter == .frequency || parameter == .release
    }
}

struct DeEsserEditorView: View {
    @ObservedObject var model: MyFXEditorModel
    @ObservedObject var display: DeEsserDisplayModel

    var body: some View {
        VStack(spacing: 4) {
            header
            MyFXChannelLabel(name: model.channelName)
            meters
            graph
            consonants
            faders
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(minWidth: 300, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity, alignment: .top)
        .background(MyFXPalette.background)
    }

    private func value(_ parameter: DeEsserParameter) -> Float {
        model.value(parameter.address)
    }

    // MARK: Header and meters

    private var header: some View {
        HStack {
            Text("MyDeEsser")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white.opacity(0.75))
            Spacer()
            MyFXSubtitle(String(format: "SPLIT %.1f kHz", value(.frequency) / 1_000))
                .help("Only the band above this frequency is limited")
        }
        .padding(.horizontal, 2)
        .frame(height: 20)
    }

    private var meters: some View {
        MyFXStrip {
            VStack(spacing: 6) {
                MyFXMeterRow(label: "IN", state: model.input, showsClip: true) { model.input.clearPeaks() }
                    .help("Input after INPUT gain")
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
        let frequency = DeEsserParameter.frequency
        return MyFXStrip {
            DeEsserBandGraph(
                frequency: Double(value(.frequency)),
                gain: display.graphGain,
                sampleRate: display.sampleRate,
                isListening: value(.listen) >= 0.5,
                isBypassed: display.isBypassed,
                onBegin: { model.set(frequency.address, value(.frequency), event: .touch) },
                onChange: { model.set(frequency.address, frequency.clamped(Float($0))) },
                onEnd: { model.set(frequency.address, value(.frequency), event: .release) },
                onReset: { model.setOnce(frequency.address, frequency.defaultValue) }
            )
            .frame(height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .padding(3)
            .help("Drag sideways to move FREQ; red is the consonant band and how far it is turned down now")
        }
    }

    // MARK: Consonant section

    private var consonants: some View {
        let threshold = DeEsserParameter.threshold
        return MyFXStrip {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    Text("SIBILANCE")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(MyFXPalette.heading)
                    Spacer(minLength: 0)
                    DeEsserButton(parameter: .stereoLink, model: model, tint: DeEsserColors.link)
                        .frame(width: 76)
                        .help("On: both channels turned down together, from the louder. Off: each on its own")
                    DeEsserButton(parameter: .listen, model: model, tint: DeEsserColors.listen)
                        .frame(width: 52)
                        .help("Hear only the consonant band (to set FREQ); turn off when done")
                }
                .frame(height: 16)
                row("SIB") {
                    DeEsserSibilanceMeter(
                        state: display.sibilance,
                        threshold: Double(value(.threshold)),
                        onBegin: { model.set(threshold.address, value(.threshold), event: .touch) },
                        onChange: { model.set(threshold.address, threshold.clamped(Float($0))) },
                        onEnd: { model.set(threshold.address, value(.threshold), event: .release) },
                        onReset: { model.setOnce(threshold.address, threshold.defaultValue) }
                    )
                    .help("Consonant band level; the red marker is THRESH (drag it)")
                } readout: {
                    DeEsserReadout(text: MyFXMeterScale.label(forLevel: display.sibilance.maximum),
                                   color: MyFXPalette.value, onClear: display.clearSibilance)
                }
                row("GR") {
                    DeEsserReductionMeter(left: display.reductionLeft, right: display.reductionRight)
                        .help("How far the consonant band is turned down (0 to -24 dB)")
                } readout: {
                    DeEsserReadout(text: String(format: "%.1f", display.maximumReduction),
                                   color: DeEsserColors.reduction, onClear: display.clearReduction)
                }
                ticks
                    .frame(height: 9)
                    .padding(.leading, MyFXMeterRow.labelWidth + 6)
                    .padding(.trailing, MyFXMeterRow.readoutWidth + 6)
            }
            .padding(8)
        }
    }

    private func row<Meter: View, Readout: View>(_ label: String, @ViewBuilder meter: () -> Meter,
                                                 @ViewBuilder readout: () -> Readout) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(MyFXPalette.heading)
                .frame(width: MyFXMeterRow.labelWidth, alignment: .leading)
            meter()
                .frame(height: 11)
            readout()
        }
    }

    private var ticks: some View {
        GeometryReader { geometry in
            ForEach(DeEsserSibilanceScale.ticks, id: \.self) { decibels in
                Text("\(Int(decibels))")
                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(decibels == 0 ? 0.85 : 0.5))
                    .fixedSize()
                    .position(x: CGFloat(DeEsserSibilanceScale.fraction(forDecibels: decibels)) * geometry.size.width,
                              y: geometry.size.height / 2)
            }
        }
    }

    // MARK: Faders

    private var faders: some View {
        MyFXStrip {
            HStack(spacing: 0) {
                fader(.inputGain)
                fader(.frequency)
                fader(.threshold, nameColor: DeEsserColors.reduction)
                fader(.attack)
                fader(.release)
            }
            .padding(.horizontal, 2)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .frame(height: 180)
    }

    private func fader(_ parameter: DeEsserParameter, nameColor: Color = MyFXPalette.heading) -> some View {
        MyFXFaderColumn(
            parameter: parameter,
            model: model,
            nameColor: nameColor,
            fraction: { DeEsserTaper.fraction(parameter, $0) },
            value: { DeEsserTaper.value(parameter, $0) }
        )
    }
}
