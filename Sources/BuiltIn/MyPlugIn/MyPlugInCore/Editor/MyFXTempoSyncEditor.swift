import AudioToolbox
import SwiftUI

// Tempo sync in an editor: a SYNC row (switch, note type, the resulting
// time at the host's tempo) and the synced fader, which steps through the
// note lengths (MyFXTempo).

/// A small switch-like button, lit when on.
public struct MyFXToggleButton: View {
    public static var lit: Color { Color(red: 1.0, green: 0.62, blue: 0.25) }

    let title: String
    let isOn: Bool
    let isEnabled: Bool
    let width: CGFloat
    let help: String
    let action: () -> Void

    public init(_ title: String, isOn: Bool, isEnabled: Bool = true, width: CGFloat = 30,
                help: String, action: @escaping () -> Void) {
        self.title = title
        self.isOn = isOn
        self.isEnabled = isEnabled
        self.width = width
        self.help = help
        self.action = action
    }

    public var body: some View {
        Text(title)
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(isOn ? Color.black.opacity(0.85) : MyFXPalette.heading)
            .frame(width: width, height: 20)
            .background(RoundedRectangle(cornerRadius: 3).fill(isOn ? Self.lit : MyFXPalette.well))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(MyFXPalette.border, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onTapGesture { if isEnabled { action() } }
            .help(help)
    }
}

/// SYNC, the note type (normal, triplet, dotted) and, while synced, the
/// host's tempo with the time it gives. The three addresses are the
/// effect's sync switch, note length and note type parameters.
public struct MyFXTempoSyncRow: View {
    @ObservedObject var model: MyFXEditorModel
    let tempo: MyFXTempo
    let syncAddress: AUParameterAddress
    let lengthAddress: AUParameterAddress
    let typeAddress: AUParameterAddress
    /// How the time reads: a delay in ms, an LFO period or rate.
    let readout: (Double) -> String

    public init(model: MyFXEditorModel, tempo: MyFXTempo, syncAddress: AUParameterAddress,
                lengthAddress: AUParameterAddress, typeAddress: AUParameterAddress,
                readout: @escaping (Double) -> String = MyFXTempoSyncRow.milliseconds) {
        self.model = model
        self.tempo = tempo
        self.syncAddress = syncAddress
        self.lengthAddress = lengthAddress
        self.typeAddress = typeAddress
        self.readout = readout
    }

    public static func milliseconds(_ seconds: Double) -> String {
        seconds < 10 ? String(format: "%.0f ms", seconds * 1_000) : String(format: "%.1f s", seconds)
    }

    public var body: some View {
        let isSynced = model.value(syncAddress) >= 0.5
        let type = MyFXNoteType(rawValue: Int(model.value(typeAddress))) ?? .normal
        HStack(spacing: 6) {
            MyFXToggleButton("SYNC", isOn: isSynced, width: 40,
                             help: "Follow the host's tempo") {
                model.setOnce(syncAddress, isSynced ? 0 : 1)
            }
            ForEach(MyFXNoteType.allCases, id: \.self) { candidate in
                MyFXToggleButton(candidate == .normal ? "N" : candidate.suffix,
                                 isOn: isSynced && candidate == type, isEnabled: isSynced, width: 22,
                                 help: candidate.displayName) {
                    model.setOnce(typeAddress, Float(candidate.rawValue))
                }
            }
            Spacer(minLength: 4)
            if isSynced {
                // The tempo arrives with the audio, so poll it.
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    Text(String(format: "%.0f BPM  ", tempo.beatsPerMinute) + readout(seconds))
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundColor(MyFXPalette.heading)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 6)
    }

    private var seconds: Double {
        tempo.seconds(MyFXNoteLength(rawValue: Int(model.value(lengthAddress))) ?? .quarter,
                      MyFXNoteType(rawValue: Int(model.value(typeAddress))) ?? .normal)
    }
}

extension MyFXFaderColumn {
    /// A fader that steps through the note lengths (shortest at the
    /// bottom), showing the length with the note type ("1/8T"). Typing
    /// "1/8D" sets both.
    public init(syncedName name: String, model: MyFXEditorModel, nameColor: Color = MyFXPalette.heading,
                lengthAddress: AUParameterAddress, typeAddress: AUParameterAddress) {
        let steps = Double(MyFXNoteLength.allCases.count - 1)
        let length = MyFXNoteLength(rawValue: Int(model.value(lengthAddress))) ?? .quarter
        let type = MyFXNoteType(rawValue: Int(model.value(typeAddress))) ?? .normal
        self.init(
            name: name,
            nameColor: nameColor,
            valueText: MyFXNoteValue.displayString(length, type),
            fraction: Double(length.rawValue) / steps,
            onType: { text in
                guard let (length, type) = MyFXNoteValue.parse(text) else { return }
                model.setOnce(lengthAddress, Float(length.rawValue))
                model.setOnce(typeAddress, Float(type.rawValue))
            },
            onBegin: { model.set(lengthAddress, model.value(lengthAddress), event: .touch) },
            onChange: { fraction in
                let step = (min(max(fraction, 0), 1) * steps).rounded()
                if Float(step) != model.value(lengthAddress) { model.set(lengthAddress, Float(step)) }
            },
            onEnd: { model.set(lengthAddress, model.value(lengthAddress), event: .release) },
            onReset: { model.setOnce(lengthAddress, Float(MyFXNoteLength.quarter.rawValue)) }
        )
    }
}
