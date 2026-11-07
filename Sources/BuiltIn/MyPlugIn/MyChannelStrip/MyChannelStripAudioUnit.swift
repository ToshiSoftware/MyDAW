import AudioToolbox
import SwiftUI
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif

/// MyChannelStrip: 4-band EQ, compressor and output gain. Everything Audio
/// Unit-related comes from MyFXAudioUnit.
public final class MyChannelStripAudioUnit: MyFXAudioUnit, @unchecked Sendable {
    /// 'aufx' 'MStp' 'Toka' (app extension, tests). Inside MyDAW it is
    /// registered under MyDAW's vendor by MyPlugInCatalog.
    public override class var componentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: MyFXFourCC("MStp"),
            componentManufacturer: MyFXFourCC("Toka"),
            componentFlags: 0,
            componentFlagsMask: 0
        )
    }

    public override class var displayName: String { "MyChannelStrip" }

    /// Taller than the usual 424: each section has its own header.
    public override class var editorSize: NSSize { NSSize(width: 300, height: 464) }

    public let stripKernel: ChannelStripKernel

    public required init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {
        let kernel = ChannelStripKernel()
        stripKernel = kernel
        try super.init(
            componentDescription: componentDescription,
            options: options,
            configuration: Configuration(kernel: kernel, parameters: ChannelStripParameter.self,
                                         stateKey: "MyChannelStripParameters")
        )
    }

    public override func makeEditorView(model: MyFXEditorModel) -> AnyView {
        let display = ChannelStripDisplayModel(kernel: stripKernel, isVisible: { [weak model] in
            model?.isVisible() ?? false
        })
        return AnyView(ChannelStripEditorView(model: model, display: display))
    }
}
