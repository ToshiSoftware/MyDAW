import AppKit
import AudioToolbox
import CoreAudioKit

/// Principal class of an effect's AUv3 app extension (com.apple.AudioUnit-UI):
/// creates the audio unit and shows its editor in other hosts (Logic, ...).
/// An extension subclasses it and overrides `makeAudioUnit`.
open class MyFXExtensionViewController: AUViewController, AUAudioUnitFactory {
    private var audioUnit: MyFXAudioUnit?
    private var editor: MyFXEditorViewController?

    open func makeAudioUnit(componentDescription: AudioComponentDescription) throws -> MyFXAudioUnit {
        fatalError("\(type(of: self)) must override makeAudioUnit")
    }

    public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let unit = try makeAudioUnit(componentDescription: componentDescription)
        audioUnit = unit
        DispatchQueue.main.async { self.installEditor() }
        return unit
    }

    open override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: MyFXEditorViewController.preferredSize))
        preferredContentSize = MyFXEditorViewController.preferredSize
    }

    open override func viewDidLoad() {
        super.viewDidLoad()
        installEditor()
    }

    /// Once both the view and the unit exist (in either order).
    private func installEditor() {
        guard isViewLoaded, editor == nil, let audioUnit else { return }
        let editor = audioUnit.makeEditorViewController()
        addChild(editor)
        editor.view.frame = view.bounds
        editor.view.autoresizingMask = [.width, .height]
        view.addSubview(editor.view)
        self.editor = editor
        preferredContentSize = editor.size
    }
}
