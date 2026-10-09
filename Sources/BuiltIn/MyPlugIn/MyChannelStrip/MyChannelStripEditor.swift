import AudioToolbox
import SwiftUI
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

// MyChannelStrip's editor, 300 x 464: header, channel name, IN meter, the EQ and
// compressor sections in signal order (each with its ON switch on top),
// output gain, OUT meter. Built from
// MyPlugInCore's parts (palette, strips, meter rows) so it matches the
// other effects; type names start with "ChannelStrip" because MyDAW
// compiles this file into its own module.

struct ChannelStripEditorView: View {
    @ObservedObject var model: MyFXEditorModel
    @ObservedObject var display: ChannelStripDisplayModel
    @State private var selectedBand = 0

    private var order: ChannelStripOrder {
        ChannelStripOrder(rawValue: Int(model.value(ChannelStripParameter.order.address))) ?? .eqFirst
    }

    var body: some View {
        VStack(spacing: 4) {
            header
            MyFXChannelLabel(name: model.channelName)
            MyFXMeterRow(label: "IN", state: model.input) { model.input.maximum = 0 }
            if order == .eqFirst {
                eqSection
                compSection
            } else {
                compSection
                eqSection
            }
            outputRow
            MyFXMeterRow(label: "OUT", state: model.output) { model.output.maximum = 0 }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .frame(minWidth: 300, maxWidth: .infinity, minHeight: 464, maxHeight: .infinity, alignment: .top)
        .background(MyFXPalette.background)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 4) {
            Text("MyChannelStrip")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white.opacity(0.75))
            Spacer(minLength: 4)
            ChannelStripButton(isOn: false, action: {
                let next: ChannelStripOrder = order == .eqFirst ? .compFirst : .eqFirst
                model.setOnce(ChannelStripParameter.order.address, Float(next.rawValue))
            }, label: {
                Text(order == .eqFirst ? "EQ ▸ COMP" : "COMP ▸ EQ").foregroundColor(MyFXPalette.value)
            })
            .frame(width: 64, height: 16)
            .help("Processing order")
        }
        .padding(.horizontal, 2)
        .frame(height: 20)
    }

    // MARK: Sections

    /// A section's ON switch and name, above its view.
    private func sectionHeader(_ parameter: ChannelStripParameter, title: String, subtitle: String) -> some View {
        let isOn = model.value(parameter.address) >= 0.5
        return HStack(spacing: 6) {
            ChannelStripButton(isOn: isOn, action: {
                model.setOnce(parameter.address, isOn ? 0 : 1)
            }, label: {
                HStack(spacing: 3) {
                    Image(systemName: "power").font(.system(size: 7, weight: .bold))
                    Text(title)
                }
            })
            .frame(width: 58, height: 16)
            .help("\(title) on/off")
            Spacer(minLength: 0)
            MyFXSubtitle(subtitle)
        }
        .padding(.horizontal, 2)
    }

    private func isOn(_ parameter: ChannelStripParameter) -> Bool {
        model.value(parameter.address) >= 0.5
    }

    // MARK: EQ

    private var eqSection: some View {
        MyFXStrip {
            VStack(spacing: 3) {
                sectionHeader(.eqOn, title: "EQ", subtitle: "4-BAND EQ")
                eqBody
                    .opacity(isOn(.eqOn) ? 1 : 0.55)
            }
            .padding(4)
        }
    }

    private var eqBody: some View {
        VStack(spacing: 3) {
            ChannelStripEQGraph(model: model, display: display, selectedBand: $selectedBand)
                .frame(height: 122)
            bandRow
                .frame(height: 40)
        }
    }

    /// The selected band: on, number (click for the next), gain (slope on
    /// cuts), frequency, Q, type.
    private var bandRow: some View {
        let band = selectedBand
        let tint = ChannelStripColors.band(band)
        let onAddress = ChannelStripParameter.band(band, .on).address
        let isOn = model.value(onAddress) >= 0.5
        let type = ChannelStripFilterType(rawValue: Int(model.value(ChannelStripParameter.band(band, .type).address))) ?? .bell
        return HStack(spacing: 4) {
            VStack(spacing: 4) {
                ChannelStripButton(isOn: isOn, tint: tint, action: {
                    model.setOnce(onAddress, isOn ? 0 : 1)
                }, label: {
                    Image(systemName: "power").font(.system(size: 8, weight: .bold))
                })
                .help("Band on/off")
                ChannelStripButton(isOn: false, action: {
                    selectedBand = (band + 1) % ChannelStripParameter.bandCount
                }, label: {
                    Text("\(band + 1)").font(.system(size: 9, weight: .heavy)).foregroundColor(tint)
                })
                .help("Next band")
            }
            .frame(width: 20)
            .padding(.vertical, 1)

            Group {
                if type.isCut {
                    slopeSwitch(band, tint: tint)
                } else {
                    ChannelStripKnob(.band(band, .gain), model: model, tint: tint)
                }
                ChannelStripKnob(.band(band, .frequency), model: model, tint: tint)
                ChannelStripKnob(.band(band, .q), model: model, tint: tint)
            }
            .frame(width: 44)

            HStack(spacing: 2) {
                ForEach(ChannelStripFilterType.allCases, id: \.self) { candidate in
                    typeButton(candidate, band: band, selected: candidate == type, tint: tint)
                }
            }
        }
        .opacity(isOn ? 1 : 0.6)
    }

    private func slopeSwitch(_ band: Int, tint: Color) -> some View {
        let address = ChannelStripParameter.band(band, .slope).address
        let steep = model.value(address) >= 0.5
        return VStack(spacing: 2) {
            Text("SLOPE")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundColor(MyFXPalette.heading)
                .frame(height: 9)
            HStack(spacing: 2) {
                ChannelStripButton(isOn: !steep, tint: tint, action: { model.setOnce(address, 0) }, label: { Text("12") })
                ChannelStripButton(isOn: steep, tint: tint, action: { model.setOnce(address, 1) }, label: { Text("24") })
            }
            .frame(height: 15)
            Text("dB/oct")
                .font(.system(size: 7))
                .foregroundColor(MyFXPalette.heading)
        }
        .help("Cut slope")
    }

    private func typeButton(_ type: ChannelStripFilterType, band: Int, selected: Bool, tint: Color) -> some View {
        ChannelStripTypeIcon(type: type)
            .stroke(selected ? Color.black.opacity(0.85) : MyFXPalette.value, lineWidth: 1.3)
            .frame(width: 12, height: 8)
            .frame(width: 20, height: 24)
            .background(RoundedRectangle(cornerRadius: 3).fill(selected ? tint : MyFXPalette.well))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(MyFXPalette.border, lineWidth: 1))
            .contentShape(Rectangle())
            .onTapGesture {
                model.setOnce(ChannelStripParameter.band(band, .type).address, Float(type.rawValue))
            }
            .help(type.displayName)
    }

    // MARK: Compressor

    private var compSection: some View {
        MyFXStrip {
            VStack(spacing: 3) {
                sectionHeader(.compOn, title: "COMP", subtitle: "COMPRESSOR")
                compBody
                    .opacity(isOn(.compOn) ? 1 : 0.55)
            }
            .padding(4)
        }
    }

    private var compBody: some View {
        HStack(spacing: 5) {
            ChannelStripCompCurve(model: model, display: display)
                .frame(width: 116, height: 116)
            ChannelStripReductionMeter(reduction: display.reduction)
                .frame(width: 7, height: 116)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ChannelStripKnob(.compThreshold, model: model)
                    ChannelStripKnob(.compRatio, model: model)
                    ChannelStripKnob(.compKnee, model: model)
                }
                HStack(spacing: 0) {
                    ChannelStripKnob(.compAttack, model: model)
                    ChannelStripKnob(.compRelease, model: model)
                    ChannelStripKnob(.compMakeup, model: model)
                }
                HStack(spacing: 6) {
                    VStack(spacing: 4) {
                        ChannelStripButton(.compAutoMakeup, model: model, tint: ChannelStripColors.compCurve)
                            .frame(height: 15)
                            .help("Adds the makeup gain the threshold and ratio take away")
                        ChannelStripButton(.compLink, model: model, tint: ChannelStripColors.compCurve)
                            .frame(height: 15)
                            .help("One gain reduction for both channels, from the louder")
                    }
                    .padding(.leading, 4)
                    ChannelStripKnob(.compMix, model: model)
                        .frame(width: 44)
                }
                .frame(height: 38)
            }
        }
    }

    // MARK: Output

    private var outputRow: some View {
        let parameter = ChannelStripParameter.outputGain
        let address = parameter.address
        let value = model.value(address)
        return HStack(spacing: 6) {
            Text("GAIN")
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(MyFXPalette.heading)
                .frame(width: MyFXMeterRow.labelWidth, alignment: .leading)
            MyFXHorizontalFader(
                fraction: ChannelStripTaper.fraction(parameter, value),
                onBegin: { model.set(address, model.value(address), event: .touch) },
                onChange: { fraction in
                    var gain = ChannelStripTaper.value(parameter, fraction)
                    // Settle on exactly 0 dB near it: unity gain costs nothing.
                    if abs(gain) < 0.3 { gain = 0 }
                    model.set(address, gain)
                },
                onEnd: { model.set(address, model.value(address), event: .release) },
                onReset: { model.setOnce(address, parameter.defaultValue) }
            )
            .frame(height: 16)
            .help("Output gain, ±24 dB; ⌥-click or double-click for 0 dB")
            MyFXEditableValue(text: parameter.displayString(for: value) + " dB") { text in
                if let typed = parameter.value(fromDisplayString: text) { model.setOnce(address, typed) }
            }
            .frame(width: MyFXMeterRow.readoutWidth + 8, height: 14)
            .background(RoundedRectangle(cornerRadius: 2).fill(MyFXPalette.well))
        }
        .frame(height: 18)
    }
}
