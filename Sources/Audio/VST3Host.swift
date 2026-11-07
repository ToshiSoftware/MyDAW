import Foundation
import AVFoundation
import AppKit

public enum VST3HostError: LocalizedError {
    case unavailable
    case invalidBundle(URL)
    case pluginNotFound(String)
    case instantiationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "VST3 hosting is not available in this build."
        case let .invalidBundle(url):
            return "The VST3 bundle is invalid: \(url.path)"
        case let .pluginNotFound(uid):
            return "The VST3 plug-in was not found: \(uid)"
        case let .instantiationFailed(name):
            return "The VST3 plug-in could not be instantiated: \(name)"
        }
    }
}

public protocol VST3PluginInstance: AnyObject {
    var latencySamples: Int { get }
    var hasEditor: Bool { get }

    func prepare(sampleRate: Double, maxFrames: AVAudioFrameCount) throws
    func process(input: AVAudioPCMBuffer, output: AVAudioPCMBuffer) throws
    func saveState() throws -> Data
    func restoreState(_ data: Data) throws
    func editorView() throws -> NSView
}

public protocol VST3Host: AnyObject {
    var isAvailable: Bool { get }

    func instantiate(
        bundleURL: URL,
        pluginUID: String,
        sampleRate: Double,
        maxFrames: AVAudioFrameCount
    ) throws -> any VST3PluginInstance
}

public final class UnavailableVST3Host: VST3Host {
    public let isAvailable = false

    public init() {}

    public func instantiate(
        bundleURL: URL,
        pluginUID: String,
        sampleRate: Double,
        maxFrames: AVAudioFrameCount
    ) throws -> any VST3PluginInstance {
        throw VST3HostError.unavailable
    }
}
