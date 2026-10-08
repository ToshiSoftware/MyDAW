import AudioToolbox
import SwiftUI
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

// MyDelay's editor: the shared MyFX frame (meters, MyDAW mixer look) with a
// mode menu in the header and the faders that mode uses. Type names start
// with "Delay" because MyDAW compiles this file into its own module.

/// Fader travel (0 = bottom, 1 = top) for each parameter.
enum DelayFaderTaper {
    /// Time: 1 ms to 10 s, logarithmic (four decades, 1 ms at the bottom).
    static func fraction(for parameter: DelayParameter, value: Float) -> Double {
        let value = Double(parameter.clamped(value))
        switch parameter {
        case .time:
            return log10(value / 0.001) / 4
        case .mode:
            return value / Double(parameter.range.upperBound)
        case .feedback, .width, .mix:
            return value / 100
        }
    }

    static func value(for parameter: DelayParameter, fraction: Double) -> Float {
        let fraction = min(max(fraction, 0), 1)
        switch parameter {
        case .time:
            return parameter.clamped(Float(0.001 * pow(10, 4 * fraction)))
        case .mode:
            return parameter.clamped(Float(fraction) * parameter.range.upperBound)
        case .feedback, .width, .mix:
            return parameter.clamped(Float(fraction * 100))
        }
    }

    /// The faders shown in `mode`, left to right.
    static func faders(for mode: DelayMode) -> [DelayParameter] {
        [.time]
            + (mode.usesFeedback ? [.feedback] : [])
            + (mode.usesWidth ? [.width] : [])
            + [.mix]
    }
}

struct DelayEditorView: View {
    @ObservedObject var model: MyFXEditorModel

    private var mode: DelayMode {
        DelayMode(rawValue: Int(model.value(DelayParameter.mode.address))) ?? .stereo
    }

    var body: some View {
        MyFXEditorView(model: model, title: "MyDelay") {
            MyFXMenuPicker(options: DelayMode.allCases.map(\.displayName), selection: mode.rawValue) { index in
                model.setOnce(DelayParameter.mode.address, Float(index))
            }
        } faders: {
            ForEach(DelayFaderTaper.faders(for: mode), id: \.self) { parameter in
                fader(parameter)
            }
        }
    }

    private func fader(_ parameter: DelayParameter) -> MyFXFaderColumn {
        MyFXFaderColumn(
            parameter: parameter,
            model: model,
            fraction: { DelayFaderTaper.fraction(for: parameter, value: $0) },
            value: { DelayFaderTaper.value(for: parameter, fraction: $0) }
        )
    }
}
