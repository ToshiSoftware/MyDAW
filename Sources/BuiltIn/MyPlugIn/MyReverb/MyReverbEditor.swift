import AudioToolbox
import SwiftUI
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

// MyReverb's editor: the shared MyFX frame (meters, MyDAW mixer look) with
// one fader per parameter. Type names start with "Reverb" because MyDAW
// compiles this file into its own module next to its mixer views.

// MARK: - Scales

/// Fader travel (0 = bottom, 1 = top) for each parameter, giving the useful
/// part of each range most of the travel.
enum ReverbFaderTaper {
    /// HPF: bottom 4 % is Thru, then 20 Hz to 1 kHz, logarithmic.
    private static let highPassThruZone = 0.04
    /// LPF: 200 Hz to 24 kHz, logarithmic; the top 3 % is Thru.
    private static let lowPassThruZone = 0.03

    static func fraction(for parameter: ReverbParameter, value: Float) -> Double {
        let value = Double(parameter.clamped(value))
        switch parameter {
        case .hpf:
            guard !ReverbParameter.isHighPassThru(Float(value)) else { return 0 }
            let span = 1 - highPassThruZone
            return highPassThruZone + span * max(0, log(max(value, 20) / 20) / log(50))
        case .lpf:
            guard !ReverbParameter.isLowPassThru(Float(value)) else { return 1 }
            return (1 - lowPassThruZone) * log(value / 200) / log(120)
        case .rt:
            return log(value / 0.1) / log(600)
        case .preDelay:
            return value.squareRoot()
        case .mix:
            return value / 100
        }
    }

    static func value(for parameter: ReverbParameter, fraction: Double) -> Float {
        let fraction = min(max(fraction, 0), 1)
        let value: Double
        switch parameter {
        case .hpf:
            value = fraction < highPassThruZone
                ? 0
                : 20 * pow(50, (fraction - highPassThruZone) / (1 - highPassThruZone))
        case .lpf:
            value = fraction >= 1 - lowPassThruZone ? 24_000 : 200 * pow(120, fraction / (1 - lowPassThruZone))
        case .rt:
            value = 0.1 * pow(600, fraction)
        case .preDelay:
            value = fraction * fraction
        case .mix:
            value = fraction * 100
        }
        return parameter.clamped(Float(value))
    }
}

/// Five faders, one per parameter, in address order.
struct ReverbEditorView: View {
    @ObservedObject var model: MyFXEditorModel

    var body: some View {
        MyFXEditorView(model: model, title: "MyReverb") {
            MyFXSubtitle("PLATE REVERB")
        } faders: {
            ForEach(ReverbParameter.allCases, id: \.self) { parameter in
                fader(parameter)
            }
        }
    }

    private func fader(_ parameter: ReverbParameter) -> MyFXFaderColumn {
        MyFXFaderColumn(
            parameter: parameter,
            model: model,
            fraction: { ReverbFaderTaper.fraction(for: parameter, value: $0) },
            value: { ReverbFaderTaper.value(for: parameter, fraction: $0) }
        )
    }
}
