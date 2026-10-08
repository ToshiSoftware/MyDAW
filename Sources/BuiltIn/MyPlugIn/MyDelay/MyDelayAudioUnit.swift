import AudioToolbox
import SwiftUI
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

/// MyDelay: mono, stereo, doubler and ping-pong delay (see DelayKernel).
/// Everything Audio Unit-related comes from MyFXAudioUnit.
public final class MyDelayAudioUnit: MyFXAudioUnit, @unchecked Sendable {
    /// 'aufx' 'MDly' 'Toka' (app extension, tests). Inside MyDAW it is
    /// registered under MyDAW's vendor by MyPlugInCatalog.
    public override class var componentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: MyFXFourCC("MDly"),
            componentManufacturer: MyFXFourCC("Toka"),
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    public override class var displayName: String { "MyDelay" }

    public required init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        try super.init(
            componentDescription: componentDescription,
            options: options,
            configuration: Configuration(kernel: DelayKernel(), parameters: DelayParameter.self,
                                         stateKey: "MyDelayParameters")
        )
    }

    public override func makeEditorView(model: MyFXEditorModel) -> AnyView {
        AnyView(DelayEditorView(model: model))
    }
}
