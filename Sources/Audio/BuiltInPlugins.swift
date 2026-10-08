import AudioToolbox

/// Effects that ship inside MyDAW: every effect of MyPlugIn (Sources/BuiltIn,
/// copied by scripts/sync-myplugin.sh). They are registered in-process and
/// then listed and inserted like any installed Audio Unit.
enum BuiltInPlugins {
    /// Built-in effects use vendor 'MyDA' ("MyDAW: MyReverb", ...). Not
    /// 'MyDW': PluginManager hides that vendor's units (MyDAW's internal
    /// processing). Projects save these codes, so they must not change.
    static let manufacturer = MyFXFourCC("MyDA")

    /// Must run before the plug-in scan and before a project instantiates
    /// its inserts.
    static let registration: Void = {
        MyPlugInCatalog.registerAll(manufacturer: manufacturer, vendorName: "MyDAW")
    }()
}
