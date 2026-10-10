import AudioToolbox
import SwiftUI
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

/// MyChorusPan: stereo chorus / flanger and auto pan (Docs/MyChorusPan.md).
/// Everything Audio Unit-related comes from MyFXAudioUnit.
public final class MyChorusPanAudioUnit: MyFXAudioUnit, @unchecked Sendable {
    /// 'aufx' 'MChP' 'Toka' (app extension, tests). Inside MyDAW it is
    /// registered under MyDAW's vendor by MyPlugInCatalog.
    public override class var componentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: MyFXFourCC("MChP"),
            componentManufacturer: MyFXFourCC("Toka"),
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    public override class var displayName: String { "MyChorusPan" }

    /// Taller than the usual 424: the LFO row sits above the faders.
    public override class var editorSize: NSSize { NSSize(width: 300, height: 460) }

    public let chorusPanKernel: ChorusPanKernel

    public required init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        let kernel = ChorusPanKernel()
        chorusPanKernel = kernel
        try super.init(
            componentDescription: componentDescription,
            options: options,
            configuration: Configuration(kernel: kernel, parameters: ChorusPanParameter.self,
                                         stateKey: "MyChorusPanParameters")
        )
    }

    public override func makeEditorView(model: MyFXEditorModel) -> AnyView {
        let lamp = ChorusPanLampModel(kernel: chorusPanKernel, isVisible: { [weak model] in
            model?.isVisible() ?? false
        })
        return AnyView(ChorusPanEditorView(model: model, lamp: lamp))
    }
}
