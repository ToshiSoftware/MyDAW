import AudioToolbox
import Foundation

/// A four-character code ("MRev") as an OSType.
public func MyFXFourCC(_ code: String) -> OSType {
    code.utf8.prefix(4).reduce(0) { ($0 << 8) | OSType($1) }
}

/// An effect's parameters, one enum case each. The raw value is the AU
/// parameter address, so it must never change once projects have been saved.
public protocol MyFXParameter: CaseIterable, Hashable, RawRepresentable where RawValue == Int {
    /// Key in saved state; never change it.
    var identifier: String { get }
    /// Label on the fader ("HPF").
    var displayName: String { get }
    /// Name hosts show in generic views and automation lanes.
    var hostName: String { get }
    var range: ClosedRange<Float> { get }
    var defaultValue: Float { get }
    var unit: AudioUnitParameterUnit { get }
    /// Beyond readable and writable (default: can ramp).
    var flags: AudioUnitParameterOptions { get }
    /// Names of an indexed parameter's values.
    var valueStrings: [String]? { get }

    func clamped(_ value: Float) -> Float
    func displayString(for value: Float) -> String
    func value(fromDisplayString string: String) -> Float?
}

extension MyFXParameter {
    public var address: AUParameterAddress { AUParameterAddress(rawValue) }
    public var hostName: String { displayName }
    public var flags: AudioUnitParameterOptions { [.flag_CanRamp] }
    public var valueStrings: [String]? { nil }

    public func clamped(_ value: Float) -> Float {
        guard value.isFinite else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    public static var descriptors: [MyFXParameterDescriptor] {
        allCases.map(MyFXParameterDescriptor.init)
    }
}

/// One parameter as MyFXAudioUnit builds and serves it.
public struct MyFXParameterDescriptor {
    public let address: AUParameterAddress
    public let identifier: String
    public let hostName: String
    public let range: ClosedRange<Float>
    public let defaultValue: Float
    public let unit: AudioUnitParameterUnit
    public let flags: AudioUnitParameterOptions
    public let valueStrings: [String]?
    public let clamp: (Float) -> Float
    public let display: (Float) -> String
    public let parse: (String) -> Float?

    public init<Parameter: MyFXParameter>(_ parameter: Parameter) {
        address = parameter.address
        identifier = parameter.identifier
        hostName = parameter.hostName
        range = parameter.range
        defaultValue = parameter.defaultValue
        unit = parameter.unit
        flags = parameter.flags
        valueStrings = parameter.valueStrings
        clamp = parameter.clamped
        display = parameter.displayString
        parse = parameter.value(fromDisplayString:)
    }
}

/// The DSP side of an effect, as MyFXAudioUnit drives it. Threading:
/// `prepare` while not rendering; `process` and `applyParameter` on the
/// render thread; the rest from any thread.
public protocol MyFXKernel: MyFXRenderKernel {
    func prepare(sampleRate: Double, maximumFrames: Int)
    /// Clears the audio state at the start of the next `process`.
    func requestReset()
    var isBypassed: Bool { get set }
    var tailTime: Double { get }
    /// How many samples the output lags the input (a look-ahead); hosts
    /// compensate for it. Valid after `prepare`.
    var latencySamples: Int { get }
    func takeMeterPeaks() -> MyFXPeaks
    /// The current target of a parameter (what the host reads back).
    func targetValue(_ address: AUParameterAddress) -> AUValue
}

extension MyFXKernel {
    public var latencySamples: Int { 0 }
}
