import AppKit
import AVFoundation
import AudioToolbox
import CoreAudioKit
import SwiftUI

/// Base of every MyPlugIn effect: a 1- or 2-channel AUv3 effect (Float32,
/// deinterleaved, input channels = output channels) around a MyFXKernel.
/// It builds the parameter tree from the effect's parameters, saves them in
/// `fullState`, handles bypass and reset, renders through MyFXRenderer, and
/// hands hosts the effect's editor.
///
/// A subclass gives its component description, display name and version,
/// overrides `init(componentDescription:options:)` to pass its
/// configuration, and `makeEditorView(model:)` to return its editor.
open class MyFXAudioUnit: AUAudioUnit, MyFXMetering, @unchecked Sendable {
    public struct Configuration {
        public let kernel: any MyFXKernel
        public let parameters: [MyFXParameterDescriptor]
        /// Key of the parameter values in `fullState`; never change it.
        public let stateKey: String

        public init<Parameter: MyFXParameter>(kernel: any MyFXKernel, parameters: Parameter.Type, stateKey: String) {
            self.kernel = kernel
            self.parameters = Parameter.descriptors
            self.stateKey = stateKey
        }
    }

    /// 'aufx' subtype 'Toka' for the app extension and tests.
    open class var componentDescription: AudioComponentDescription {
        fatalError("\(self) must override componentDescription")
    }

    /// Name without vendor ("MyReverb").
    open class var displayName: String {
        fatalError("\(self) must override displayName")
    }

    open class var version: UInt32 { 0x0001_0000 }

    /// Makes the unit available to AVAudioUnit.instantiate in this process
    /// under `description`. `name` must be "Vendor: Name".
    public class func registerInProcess(as description: AudioComponentDescription, name: String) {
        AUAudioUnit.registerSubclass(self, as: description, name: name, version: version)
    }

    public let kernel: any MyFXKernel
    private let parameters: [MyFXParameterDescriptor]
    private let stateKey: String
    private let renderer = MyFXRenderer()
    private var inputBusArray: AUAudioUnitBusArray!
    private var outputBusArray: AUAudioUnitBusArray!

    /// Subclasses override this and call `init(componentDescription:options:configuration:)`.
    public required override init(componentDescription: AudioComponentDescription,
                                  options: AudioComponentInstantiationOptions = []) throws {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_InvalidProperty),
                      userInfo: [NSLocalizedDescriptionKey: "MyFXAudioUnit is abstract"])
    }

    public init(componentDescription: AudioComponentDescription,
                options: AudioComponentInstantiationOptions,
                configuration: Configuration) throws {
        kernel = configuration.kernel
        parameters = configuration.parameters
        stateKey = configuration.stateKey
        try super.init(componentDescription: componentDescription, options: options)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        let inputBus = try AUAudioUnitBus(format: format)
        let outputBus = try AUAudioUnitBus(format: format)
        inputBus.maximumChannelCount = 2
        outputBus.maximumChannelCount = 2
        inputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        outputBusArray = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        parameterTree = Self.makeParameterTree(parameters, kernel: kernel)
        maximumFramesToRender = 4_096
    }

    // MARK: Editor

    /// The effect's editor content; the frame and meters come from MyFXEditorView.
    open func makeEditorView(model: MyFXEditorModel) -> AnyView {
        AnyView(EmptyView())
    }

    public func makeEditorViewController() -> MyFXEditorViewController {
        let model = MyFXEditorModel(parameterTree: parameterTree, metering: self)
        return MyFXEditorViewController(model: model, rootView: makeEditorView(model: model))
    }

    public override func requestViewController(completionHandler: @escaping (NSViewController?) -> Void) {
        DispatchQueue.main.async {
            completionHandler(self.makeEditorViewController())
        }
    }

    public func takeMeterPeaks() -> MyFXPeaks {
        kernel.takeMeterPeaks()
    }

    // MARK: Properties

    public override var inputBusses: AUAudioUnitBusArray { inputBusArray }
    public override var outputBusses: AUAudioUnitBusArray { outputBusArray }
    public override var channelCapabilities: [NSNumber]? { [1, 1, 2, 2] }
    public override var tailTime: TimeInterval { kernel.tailTime }
    public override var latency: TimeInterval { 0 }
    public override var supportsUserPresets: Bool { false }

    public override var shouldBypassEffect: Bool {
        get { kernel.isBypassed }
        set { kernel.isBypassed = newValue }
    }

    public override func shouldChange(to format: AVAudioFormat, for bus: AUAudioUnitBus) -> Bool {
        guard format.commonFormat == .pcmFormatFloat32,
              !format.isInterleaved,
              (1...2).contains(format.channelCount) else { return false }
        return super.shouldChange(to: format, for: bus)
    }

    /// Parameter values by identifier, on top of the base class's state, so
    /// a project restores them regardless of the host.
    public override var fullState: [String: Any]? {
        get {
            var state = super.fullState ?? [:]
            var values: [String: NSNumber] = [:]
            for parameter in parameters {
                values[parameter.identifier] = NSNumber(value: kernel.targetValue(parameter.address))
            }
            state[stateKey] = values
            return state
        }
        set {
            super.fullState = newValue
            guard let values = newValue?[stateKey] as? [String: NSNumber],
                  let tree = parameterTree else { return }
            for parameter in parameters {
                guard let value = values[parameter.identifier] else { continue }
                tree.parameter(withAddress: parameter.address)?.value = value.floatValue
            }
        }
    }

    // MARK: Render resources

    public override func allocateRenderResources() throws {
        let input = inputBusses[0].format
        let output = outputBusses[0].format
        guard input.channelCount == output.channelCount,
              (1...2).contains(output.channelCount),
              input.sampleRate == output.sampleRate else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        try super.allocateRenderResources()
        let frames = Int(maximumFramesToRender)
        renderer.allocate(frames: frames, channelCount: Int(output.channelCount))
        kernel.prepare(sampleRate: output.sampleRate, maximumFrames: frames)
    }

    public override func reset() {
        super.reset()
        kernel.requestReset()
    }

    public override var internalRenderBlock: AUInternalRenderBlock {
        renderer.makeRenderBlock(kernel: kernel)
    }

    // MARK: Private

    private static func makeParameterTree(_ parameters: [MyFXParameterDescriptor],
                                          kernel: any MyFXKernel) -> AUParameterTree {
        let byAddress = Dictionary(uniqueKeysWithValues: parameters.map { ($0.address, $0) })
        let children = parameters.map { parameter -> AUParameter in
            let auParameter = AUParameterTree.createParameter(
                withIdentifier: parameter.identifier,
                name: parameter.hostName,
                address: parameter.address,
                min: parameter.range.lowerBound,
                max: parameter.range.upperBound,
                unit: parameter.unit,
                unitName: nil,
                flags: parameter.flags.union([.flag_IsReadable, .flag_IsWritable]),
                valueStrings: parameter.valueStrings,
                dependentParameters: nil
            )
            auParameter.value = parameter.defaultValue
            return auParameter
        }
        let tree = AUParameterTree.createTree(withChildren: children)
        tree.implementorValueObserver = { [kernel] parameter, value in
            kernel.applyParameter(parameter.address, value)
        }
        tree.implementorValueProvider = { [kernel] parameter in
            kernel.targetValue(parameter.address)
        }
        tree.implementorStringFromValueCallback = { parameter, valuePointer in
            byAddress[parameter.address]?.display(valuePointer?.pointee ?? parameter.value) ?? ""
        }
        tree.implementorValueFromStringCallback = { parameter, string in
            byAddress[parameter.address]?.parse(string) ?? parameter.value
        }
        return tree
    }
}
