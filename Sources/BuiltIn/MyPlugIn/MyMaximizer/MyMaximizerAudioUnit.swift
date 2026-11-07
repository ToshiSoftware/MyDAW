import AudioToolbox
import SwiftUI
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

/// MyMaximizer: input gain, upward compression and a look-ahead brickwall
/// limiter. Everything Audio Unit-related comes from MyFXAudioUnit.
public final class MyMaximizerAudioUnit: MyFXAudioUnit, @unchecked Sendable {
    /// 'aufx' 'MMax' 'Toka' (app extension, tests). Inside MyDAW it is
    /// registered under MyDAW's vendor by MyPlugInCatalog.
    public override class var componentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: MyFXFourCC("MMax"),
            componentManufacturer: MyFXFourCC("Toka"),
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    public override class var displayName: String { "MyMaximizer" }

    /// Taller than the usual 424: the history graph.
    public override class var editorSize: NSSize { NSSize(width: 300, height: 460) }

    public let maximizerKernel: MaximizerKernel

    public required init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        let kernel = MaximizerKernel()
        maximizerKernel = kernel
        try super.init(
            componentDescription: componentDescription,
            options: options,
            configuration: Configuration(kernel: kernel, parameters: MaximizerParameter.self,
                                         stateKey: "MyMaximizerParameters")
        )
    }

    public override func makeEditorView(model: MyFXEditorModel) -> AnyView {
        let display = MaximizerDisplayModel(kernel: maximizerKernel, isVisible: { [weak model] in
            model?.isVisible() ?? false
        })
        return AnyView(MaximizerEditorView(model: model, display: display))
    }
}
