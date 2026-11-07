import AudioToolbox
import SwiftUI
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

/// MyReverb: a stereo plate reverb (see ReverbKernel). Everything Audio
/// Unit-related comes from MyFXAudioUnit.
public final class MyReverbAudioUnit: MyFXAudioUnit, @unchecked Sendable {
    /// 'aufx' 'MRev' 'Toka' (app extension, tests). Inside MyDAW it is
    /// registered under MyDAW's vendor by MyPlugInCatalog.
    public override class var componentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: MyFXFourCC("MRev"),
            componentManufacturer: MyFXFourCC("Toka"),
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    public override class var displayName: String { "MyReverb" }
    public override class var version: UInt32 { 0x0002_0000 }

    public required init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        try super.init(
            componentDescription: componentDescription,
            options: options,
            configuration: Configuration(kernel: ReverbKernel(), parameters: ReverbParameter.self,
                                         stateKey: "MyReverbParameters")
        )
    }

    public override func makeEditorView(model: MyFXEditorModel) -> AnyView {
        AnyView(ReverbEditorView(model: model))
    }
}
