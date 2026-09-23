import Foundation
import AVFoundation
import AudioToolbox
import CryptoKit

public enum TrackPluginKind: String, Codable, Sendable {
    case au = "AU"
    case vst3 = "VST3"
}

public enum PluginUICompatibility: String, Codable, Hashable, Sendable {
    case automatic
    case custom
    case customMainThread
    case genericOnly
    case disabled
}

public struct PluginCompatibilityProfile: Codable, Hashable, Sendable {
    public let ui: PluginUICompatibility
    public let requestTimeoutMs: Int
    public let notes: String?

    public static let automatic = PluginCompatibilityProfile(
        ui: .automatic,
        requestTimeoutMs: 3000,
        notes: nil
    )

}

public struct TrackPluginDescriptor: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let kind: TrackPluginKind
    public let bundleURL: String?
    public let componentType: UInt32
    public let componentSubType: UInt32
    public let componentManufacturer: UInt32
    public let componentFlags: UInt32
    public let pluginUID: String?
    public let version: String?
    public var enabled: Bool
    public var compatibility: PluginCompatibilityProfile

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, bundleURL, componentType, componentSubType
        case componentManufacturer, componentFlags, pluginUID, version
        case enabled, compatibility
    }

    public var isLoadable: Bool {
        switch kind {
        case .au:
            return componentType != 0
        case .vst3:
            return bundleURL != nil
        }
    }

    public var audioComponentDescription: AudioComponentDescription {
        AudioComponentDescription(
            componentType: componentType,
            componentSubType: componentSubType,
            componentManufacturer: componentManufacturer,
            componentFlags: componentFlags,
            componentFlagsMask: 0
        )
    }

    public init(
        id: UUID = UUID(),
        name: String,
        kind: TrackPluginKind,
        bundleURL: String? = nil,
        componentType: UInt32 = 0,
        componentSubType: UInt32 = 0,
        componentManufacturer: UInt32 = 0,
        componentFlags: UInt32 = 0,
        pluginUID: String? = nil,
        version: String? = nil,
        enabled: Bool = true,
        compatibility: PluginCompatibilityProfile = .automatic
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.bundleURL = bundleURL
        self.componentType = componentType
        self.componentSubType = componentSubType
        self.componentManufacturer = componentManufacturer
        self.componentFlags = componentFlags
        self.pluginUID = pluginUID
        self.version = version
        self.enabled = enabled
        self.compatibility = compatibility
    }

    public func newInstance() -> TrackPluginDescriptor {
        TrackPluginDescriptor(
            name: name,
            kind: kind,
            bundleURL: bundleURL,
            componentType: componentType,
            componentSubType: componentSubType,
            componentManufacturer: componentManufacturer,
            componentFlags: componentFlags,
            pluginUID: pluginUID,
            version: version,
            enabled: enabled,
            compatibility: compatibility
        )
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "Audio Unit"
        let kindValue = try values.decodeIfPresent(String.self, forKey: .kind)
        kind = TrackPluginKind(rawValue: kindValue ?? "AU") ?? .vst3
        bundleURL = try values.decodeIfPresent(String.self, forKey: .bundleURL)
        componentType = try values.decodeIfPresent(UInt32.self, forKey: .componentType) ?? 0
        componentSubType = try values.decodeIfPresent(UInt32.self, forKey: .componentSubType) ?? 0
        componentManufacturer = try values.decodeIfPresent(UInt32.self, forKey: .componentManufacturer) ?? 0
        componentFlags = try values.decodeIfPresent(UInt32.self, forKey: .componentFlags) ?? 0
        pluginUID = try values.decodeIfPresent(String.self, forKey: .pluginUID)
        version = try values.decodeIfPresent(String.self, forKey: .version)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        compatibility = try values.decodeIfPresent(
            PluginCompatibilityProfile.self,
            forKey: .compatibility
        ) ?? .automatic
    }

    public var resolvedCompatibility: PluginCompatibilityProfile {
        compatibility
    }

    public var menuDisplayName: String {
        let format = kind == .au ? "AU" : "VST"
        return "\(format): \(name)"
    }
}

public final class PluginManager: ObservableObject {
    @Published public var availablePlugins: [TrackPluginDescriptor] = []
    public let vst3Host: any VST3Host

    public init(vst3Host: (any VST3Host)? = nil) {
        self.vst3Host = vst3Host ?? UnavailableVST3Host()
    }

    public func discoverAvailablePlugins(
        onLog: @escaping (String) -> Void = { _ in },
        completion: @escaping () -> Void = {}
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let log: (String) -> Void = { message in
                DispatchQueue.main.async {
                    onLog(message)
                }
            }

            log("Audio Unitプラグインを検出中...")
            let audioUnits = self.discoverAUComponents()
            log("Audio Unit: \(audioUnits.count)件")

            log("VST3プラグインを検出中...")
            let vst3Plugins = self.discoverVST3Bundles(onLog: log)
            let discovered = audioUnits + vst3Plugins
            let unique = Dictionary(uniqueKeysWithValues: discovered.map { ($0.id, $0) })
            let sorted = Array(unique.values).sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }

            DispatchQueue.main.async {
                self.availablePlugins = sorted
                onLog("プラグイン検出完了: \(sorted.count)件")
                completion()
            }
        }
    }

    private func discoverAUComponents() -> [TrackPluginDescriptor] {
        var plugins: [TrackPluginDescriptor] = []
        var effectDescription = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: 0,
            componentManufacturer: 0,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        var component = AudioComponentFindNext(nil, &effectDescription)
        while let validComponent = component {
            var nameRef: Unmanaged<CFString>?
            let nameStatus = AudioComponentCopyName(validComponent, &nameRef)
            let componentName: String
            if nameStatus == noErr, let nameRef {
                componentName = nameRef.takeRetainedValue() as String
            } else {
                componentName = "Audio Unit"
            }

            var desc = AudioComponentDescription()
            AudioComponentGetDescription(validComponent, &desc)
            let descriptor = TrackPluginDescriptor(
                name: componentName,
                kind: .au,
                bundleURL: nil,
                componentType: desc.componentType,
                componentSubType: desc.componentSubType,
                componentManufacturer: desc.componentManufacturer,
                componentFlags: desc.componentFlags
            )
            plugins.append(descriptor)
            component = AudioComponentFindNext(validComponent, &effectDescription)
        }

        return plugins
    }

    private func discoverVST3Bundles(onLog: @escaping (String) -> Void = { _ in }) -> [TrackPluginDescriptor] {
        let fileManager = FileManager.default
        let searchDirectories = [
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Audio/Plug-Ins/VST3"),
            URL(fileURLWithPath: "/Library/Audio/Plug-Ins/VST3")
        ]

        return searchDirectories.flatMap { directoryURL -> [TrackPluginDescriptor] in
            guard let urls = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }

            let bundles = urls
                .filter { $0.pathExtension.lowercased() == "vst3" }
            return bundles.flatMap { bundleURL in
                    onLog("VST3: \(bundleURL.lastPathComponent)")
                    // Third-party VST3 modules register Objective-C classes while
                    // loading. Keep module loading on the main thread on macOS.
                    let metadata = DispatchQueue.main.sync {
                        VST3HostBridge.enumerate(bundleURL: bundleURL)
                    }
                    return metadata.map { metadata in
                        TrackPluginDescriptor(
                            id: stablePluginID(
                                kind: .vst3,
                                value: "\(bundleURL.path):\(metadata.uid)"
                            ),
                            name: metadata.name,
                            kind: .vst3,
                            bundleURL: bundleURL.path,
                            pluginUID: metadata.uid,
                            version: metadata.version
                        )
                    }
                }
        }
    }

    private func stablePluginID(kind: TrackPluginKind, value: String) -> UUID {
        let digest = SHA256.hash(data: Data("\(kind.rawValue):\(value)".utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    public func instantiateAudioUnit(
        for descriptor: TrackPluginDescriptor,
        completion: @escaping (AVAudioUnit?) -> Void
    ) {
        guard descriptor.isLoadable else {
            completion(nil)
            return
        }

        AVAudioUnit.instantiate(
            with: descriptor.audioComponentDescription,
            options: [],
            completionHandler: { audioUnit, error in
                if let error {
                    print("Failed to create AU effect \(descriptor.name): \(error)")
                }
                completion(audioUnit)
            }
        )
    }

    public func instantiateVST3(
        for descriptor: TrackPluginDescriptor,
        sampleRate: Double,
        maxFrames: AVAudioFrameCount
    ) throws -> any VST3PluginInstance {
        guard descriptor.kind == .vst3,
              let bundlePath = descriptor.bundleURL,
              let pluginUID = descriptor.pluginUID else {
            throw VST3HostError.invalidBundle(URL(fileURLWithPath: descriptor.bundleURL ?? ""))
        }
        return try vst3Host.instantiate(
            bundleURL: URL(fileURLWithPath: bundlePath),
            pluginUID: pluginUID,
            sampleRate: sampleRate,
            maxFrames: maxFrames
        )
    }
}
