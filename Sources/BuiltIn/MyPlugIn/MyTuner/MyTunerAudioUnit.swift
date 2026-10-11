import AudioToolbox
import SwiftUI
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

/// MyTuner: a chromatic / guitar tuner that passes the sound through
/// (Docs/MyTuner.md). MyDAW opens it from the transport bar instead of a
/// channel insert. Everything Audio Unit-related comes from MyFXAudioUnit.
public final class MyTunerAudioUnit: MyFXAudioUnit, @unchecked Sendable {
    /// 'aufx' 'MTun' 'Toka' (app extension, tests). Inside MyDAW it is
    /// registered under MyDAW's vendor by MyPlugInCatalog.
    public override class var componentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: MyFXFourCC("MTun"),
            componentManufacturer: MyFXFourCC("Toka"),
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    public override class var displayName: String { "MyTuner" }

    /// No faders: lower than the usual 424.
    public override class var editorSize: NSSize { NSSize(width: 300, height: 300) }

    public let tunerKernel: TunerKernel

    public required init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        let kernel = TunerKernel()
        tunerKernel = kernel
        try super.init(
            componentDescription: componentDescription,
            options: options,
            configuration: Configuration(kernel: kernel, parameters: TunerParameter.self,
                                         stateKey: "MyTunerParameters")
        )
    }

    public override func makeEditorView(model: MyFXEditorModel) -> AnyView {
        let display = TunerDisplayModel(
            kernel: tunerKernel,
            isVisible: { [weak model] in model?.isVisible() ?? false },
            calibration: { [weak model] in Double(model?.value(TunerParameter.calibration.address) ?? 440) },
            mode: { [weak model] in
                TunerMode(rawValue: Int((model?.value(TunerParameter.mode.address) ?? 0).rounded())) ?? .chromatic
            }
        )
        return AnyView(TunerEditorView(model: model, display: display))
    }
}
