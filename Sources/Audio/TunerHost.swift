import AppKit
import AudioToolbox
import AVFoundation
import SwiftUI

/// The tuner opened from the transport bar's tuning-fork button: one
/// MyTuner audio unit, its window, and the input channel it listens to
/// (MyPlugIn/Docs/MyTuner.md §4).
///
/// The unit is never attached to the AVAudioEngine: rewiring a running
/// engine queues and collides connections. `TunerFeed` renders it from the
/// input tap instead, so opening and closing the tuner never touches the
/// audio path, even while playing or recording.
@MainActor
final class TunerHost: NSObject, NSWindowDelegate {
    private static let channelKey = "TunerInputChannel"
    private static let parametersKey = "TunerParameters"
    private static let windowAutosaveName = "MyDAWTunerWindow"

    /// Rendered from the input tap's thread.
    nonisolated let feed = TunerFeed()
    /// Called when the window's own close button hides it.
    var onClose: (() -> Void)?

    private var unit: MyTunerAudioUnit?
    private var window: NSWindow?
    private var parameterObserver: AUParameterObserverToken?
    private let inputModel = TunerInputModel()

    override init() {
        super.init()
        inputModel.channel = max(0, UserDefaults.standard.integer(forKey: Self.channelKey))
        inputModel.onSelect = { [weak self] channel in self?.select(channel: channel) }
        feed.setChannel(inputModel.channel)
    }

    /// Hardware input channels, for the input menu.
    func setInputChannelCount(_ count: Int, hasInput: Bool) {
        inputModel.channelCount = hasInput ? count : 0
    }

    /// Listens to `channel` (0-based) from now on and remembers it.
    func select(channel: Int) {
        inputModel.channel = max(0, channel)
        feed.setChannel(inputModel.channel)
        UserDefaults.standard.set(inputModel.channel, forKey: Self.channelKey)
    }

    func show() {
        guard let unit = makeUnitIfNeeded() else { return }
        if window == nil {
            window = makeWindow(unit: unit)
        }
        feed.setActive(true)
        window?.makeKeyAndOrderFront(nil)
    }

    func hide() {
        feed.setActive(false)
        window?.orderOut(nil)
    }

    // MARK: Window

    /// The red button only hides the window, like other plug-in windows,
    /// so the next open is instant.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        onClose?()
        return false
    }

    func windowDidBecomeKey(_ notification: Notification) {
        window?.orderFront(nil)
    }

    private func makeWindow(unit: MyTunerAudioUnit) -> NSWindow {
        let editor = unit.makeEditorViewController()
        let editorSize = editor.size
        let rowHeight = TunerInputRow.height
        let content = NSView(frame: NSRect(x: 0, y: 0, width: editorSize.width, height: editorSize.height + rowHeight))
        let row = NSHostingView(rootView: TunerInputRow(model: inputModel))
        row.frame = NSRect(x: 0, y: editorSize.height, width: editorSize.width, height: rowHeight)
        row.autoresizingMask = [.width, .minYMargin]
        editor.view.frame = NSRect(origin: .zero, size: editorSize)
        editor.view.autoresizingMask = [.width, .height]
        content.addSubview(editor.view)
        content.addSubview(row)

        let window = NSWindow(contentRect: content.frame, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = String(localized: "Tuner")
        window.contentViewController = TunerWindowController(editor: editor, content: content)
        window.setContentSize(content.frame.size)
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Same as plug-in windows: Space runs the transport, floats above
        // the main window, stays visible (at the normal level, above
        // MyDAW) while MyDAW is in the background.
        window.identifier = AudioEngineManager.pluginWindowIdentifier
        window.level = NSApp.isActive ? .floating : .normal
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.center()
        window.setFrameAutosaveName(Self.windowAutosaveName)
        return window
    }

    // MARK: Unit

    private func makeUnitIfNeeded() -> MyTunerAudioUnit? {
        if let unit { return unit }
        _ = BuiltInPlugins.registration
        let description = MyPlugInCatalog.componentDescription(of: MyTunerAudioUnit.self,
                                                               manufacturer: BuiltInPlugins.manufacturer)
        guard let unit = try? MyTunerAudioUnit(componentDescription: description) else {
            print("Tuner: could not create MyTuner")
            return nil
        }
        restoreParameters(of: unit)
        parameterObserver = unit.parameterTree?.token(byAddingParameterObserver: { [weak self] _, _ in
            DispatchQueue.main.async { self?.saveParameters() }
        })
        self.unit = unit
        feed.setUnit(unit)
        return unit
    }

    /// Calibration, mode and strobe are the app's, not a project's: the
    /// tuner is a tool for the guitar, not part of a song.
    private func restoreParameters(of unit: MyTunerAudioUnit) {
        guard let saved = UserDefaults.standard.dictionary(forKey: Self.parametersKey) as? [String: Float] else { return }
        for parameter in unit.parameterTree?.allParameters ?? [] {
            if let value = saved[parameter.identifier] { parameter.value = value }
        }
    }

    private func saveParameters() {
        guard let parameters = unit?.parameterTree?.allParameters else { return }
        let values = Dictionary(uniqueKeysWithValues: parameters.map { ($0.identifier, $0.value) })
        UserDefaults.standard.set(values, forKey: Self.parametersKey)
    }
}

/// Keeps the editor's controller alive (its viewDidAppear starts the
/// display) inside the window's content.
private final class TunerWindowController: NSViewController {
    private let editor: NSViewController
    private let content: NSView

    init(editor: NSViewController, content: NSView) {
        self.editor = editor
        self.content = content
        super.init(nibName: nil, bundle: nil)
        addChild(editor)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        view = content
    }
}

// MARK: - Input row

@MainActor
final class TunerInputModel: ObservableObject {
    @Published var channel = 0
    @Published var channelCount = 2
    var onSelect: ((Int) -> Void)?
}

/// A microphone and the input menu (drawn like the tuner's Chromatic /
/// Guitar menu) above the tuner's own editor.
struct TunerInputRow: View {
    static let height: CGFloat = 30
    @ObservedObject var model: TunerInputModel

    var body: some View {
        HStack(spacing: 6) {
            // The track header's input mark.
            Image(systemName: "mic.fill")
                .font(.system(size: 11))
                .foregroundColor(MyFXPalette.heading)
            if model.channelCount > 0 {
                MyFXMenuPicker(
                    options: (0..<model.channelCount).map { String(localized: "Input \($0 + 1)") },
                    selection: min(model.channel, model.channelCount - 1)
                ) { channel in
                    model.onSelect?(channel)
                }
                .help("The input channel the tuner listens to")
            } else {
                Text("No Input")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.orange)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background(MyFXPalette.background)
    }
}

// MARK: - Feed

/// Hands one input channel from the input tap to the tuner unit's render
/// block, in pieces of at most `maximumFrames`. Thread-safe: settings come
/// from the main thread, `process` from the tap's thread (not real time).
final class TunerFeed: @unchecked Sendable {
    private static let maximumFrames = 1_024

    private let lock = NSLock()
    private var unit: AUAudioUnit?
    private var renderBlock: AURenderBlock?
    private var preparedRate = 0.0
    private var channel = 0
    private var isActive = false
    private var sampleTime = 0.0
    private let input = UnsafeMutablePointer<Float>.allocate(capacity: TunerFeed.maximumFrames)
    private let output = UnsafeMutablePointer<Float>.allocate(capacity: TunerFeed.maximumFrames)
    private let outputList = AudioBufferList.allocate(maximumBuffers: 1)
    private var pullInput: AURenderPullInputBlock?

    init() {
        input.initialize(repeating: 0, count: Self.maximumFrames)
        output.initialize(repeating: 0, count: Self.maximumFrames)
        pullInput = { [input] _, _, frameCount, _, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            let byteSize = frameCount * UInt32(MemoryLayout<Float>.size)
            for index in 0..<buffers.count {
                if let data = buffers[index].mData {
                    data.copyMemory(from: input, byteCount: Int(byteSize))
                } else {
                    buffers[index].mData = UnsafeMutableRawPointer(input)
                }
                buffers[index].mDataByteSize = byteSize
            }
            return noErr
        }
    }

    deinit {
        input.deallocate()
        output.deallocate()
        free(outputList.unsafeMutablePointer)
    }

    func setUnit(_ unit: AUAudioUnit) {
        lock.withLock {
            self.unit = unit
            preparedRate = 0
            renderBlock = nil
        }
    }

    func setChannel(_ channel: Int) {
        lock.withLock { self.channel = channel }
    }

    func setActive(_ active: Bool) {
        lock.withLock { isActive = active }
    }

    /// From the input tap: every hardware channel of one buffer.
    func process(_ buffer: AVAudioPCMBuffer) {
        // The main thread holds the lock only briefly; skipping one buffer
        // then is harmless.
        guard lock.try() else { return }
        defer { lock.unlock() }
        guard isActive, let unit, let channels = buffer.floatChannelData,
              buffer.format.channelCount > 0 else { return }
        let rate = buffer.format.sampleRate
        if rate != preparedRate {
            guard prepare(unit, sampleRate: rate) else { return }
        }
        guard let renderBlock, let pullInput else { return }
        let source = channels[min(channel, Int(buffer.format.channelCount) - 1)]
        let frameCount = Int(buffer.frameLength)
        var start = 0
        while start < frameCount {
            let count = min(Self.maximumFrames, frameCount - start)
            input.update(from: source + start, count: count)
            outputList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(count * MemoryLayout<Float>.size),
                                        mData: UnsafeMutableRawPointer(output))
            var flags = AudioUnitRenderActionFlags()
            var timestamp = AudioTimeStamp()
            timestamp.mSampleTime = sampleTime
            timestamp.mFlags = .sampleTimeValid
            _ = renderBlock(&flags, &timestamp, AUAudioFrameCount(count), 0, outputList.unsafeMutablePointer, pullInput)
            sampleTime += Double(count)
            start += count
        }
    }

    /// Mono at the tap's rate. Under the lock.
    private func prepare(_ unit: AUAudioUnit, sampleRate: Double) -> Bool {
        renderBlock = nil
        preparedRate = sampleRate
        if unit.renderResourcesAllocated { unit.deallocateRenderResources() }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else { return false }
        do {
            try unit.inputBusses[0].setFormat(format)
            try unit.outputBusses[0].setFormat(format)
            unit.maximumFramesToRender = AUAudioFrameCount(Self.maximumFrames)
            try unit.allocateRenderResources()
        } catch {
            print("Tuner: could not prepare at \(sampleRate) Hz: \(error)")
            return false
        }
        renderBlock = unit.renderBlock
        sampleTime = 0
        return true
    }
}
