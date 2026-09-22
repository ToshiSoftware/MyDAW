import Foundation
import AVFoundation
import AudioToolbox

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
    public var enabled: Bool
    public var compatibility: PluginCompatibilityProfile

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, bundleURL, componentType, componentSubType
        case componentManufacturer, componentFlags, enabled, compatibility
    }

    public var isLoadable: Bool {
        kind == .au && componentType != 0
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
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        compatibility = try values.decodeIfPresent(
            PluginCompatibilityProfile.self,
            forKey: .compatibility
        ) ?? .automatic
    }

    public var resolvedCompatibility: PluginCompatibilityProfile {
        compatibility
    }
}

public final class PluginManager: ObservableObject {
    @Published public var availablePlugins: [TrackPluginDescriptor] = []

    public init() {
        discoverAvailablePlugins()
    }

    public func discoverAvailablePlugins() {
        let discovered = discoverAUComponents()

        let unique = Dictionary(uniqueKeysWithValues: discovered.map { ($0.id, $0) })
        availablePlugins = Array(unique.values).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
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
}
