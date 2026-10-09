import AudioToolbox
#if canImport(MyPlugInCore)
import MyPlugInCore
#endif
#if canImport(MyReverb)
import MyReverb
#endif
#if canImport(MyDelay)
import MyDelay
#endif
#if canImport(MyChannelStrip)
import MyChannelStrip
#endif
#if canImport(MyMaximizer)
import MyMaximizer
#endif
// new-plugin.sh: imports

/// Every MyPlugIn effect, in menu order. A host registers them all with
/// `registerAll`; adding an effect here (Tools/new-plugin.sh does it) is all
/// MyDAW needs to list it after the next sync.
public enum MyPlugInCatalog {
    public static let plugIns: [MyFXAudioUnit.Type] = [
        MyReverbAudioUnit.self,
        MyDelayAudioUnit.self,
        MyChannelStripAudioUnit.self,
        MyMaximizerAudioUnit.self,
        // new-plugin.sh: catalog
    ]

    /// The component an effect is registered as: its own type and subtype
    /// under `manufacturer` (MyDAW uses 'MyDA').
    public static func componentDescription(of plugIn: MyFXAudioUnit.Type,
                                            manufacturer: OSType) -> AudioComponentDescription {
        var description = plugIn.componentDescription
        description.componentManufacturer = manufacturer
        return description
    }

    /// Registers every effect in this process as "`vendorName`: Name".
    public static func registerAll(manufacturer: OSType, vendorName: String) {
        for plugIn in plugIns {
            plugIn.registerInProcess(as: componentDescription(of: plugIn, manufacturer: manufacturer),
                                     name: "\(vendorName): \(plugIn.displayName)")
        }
    }
}
