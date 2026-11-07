import AudioToolbox
import SwiftUI
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

/// MyDeEsser: turns down only the consonant band (above FREQ) with a 2 ms
/// look-ahead limiter. Everything Audio Unit-related comes from MyFXAudioUnit.
public final class MyDeEsserAudioUnit: MyFXAudioUnit, @unchecked Sendable {
    /// 'aufx' 'MDes' 'Toka' (app extension, tests). Inside MyDAW it is
    /// registered under MyDAW's vendor by MyPlugInCatalog.
    public override class var componentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: MyFXFourCC("MDes"),
            componentManufacturer: MyFXFourCC("Toka"),
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    public override class var displayName: String { "MyDeEsser" }

    /// Taller than the usual 424: the band graph and the consonant meters.
    public override class var editorSize: NSSize { NSSize(width: 300, height: 500) }

    public let deEsserKernel: DeEsserKernel

    public required init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        let kernel = DeEsserKernel()
        deEsserKernel = kernel
        try super.init(
            componentDescription: componentDescription,
            options: options,
            configuration: Configuration(kernel: kernel, parameters: DeEsserParameter.self,
                                         stateKey: "MyDeEsserParameters")
        )
    }

    public override func makeEditorView(model: MyFXEditorModel) -> AnyView {
        let display = DeEsserDisplayModel(kernel: deEsserKernel, isVisible: { [weak model] in
            model?.isVisible() ?? false
        })
        return AnyView(DeEsserEditorView(model: model, display: display))
    }
}
