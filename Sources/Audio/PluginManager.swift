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
            // A plug-in's AU and VST3 builds share code and global state, and
            // crash or corrupt each other when both are loaded in one process
            // (seen with Relab LX480 and UADx). Offer only the AU when both exist.
            let auNames = Set(audioUnits.map { Self.comparablePluginName($0.name) })
            let allVST3Plugins = self.discoverVST3Bundles(onLog: log)
            let vst3Plugins = allVST3Plugins.filter { !auNames.contains(Self.comparablePluginName($0.name)) }
            log("VST3: \(vst3Plugins.count)件（AU版があるため非表示: \(allVST3Plugins.count - vst3Plugins.count)件）")

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

    // AU names are "Vendor: Plug-in"; VST3 names are just "Plug-in".
    private static func comparablePluginName(_ name: String) -> String {
        let pluginPart = name.range(of: ": ").map { String(name[$0.upperBound...]) } ?? name
        return String(pluginPart.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
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
                    let metadata = scanVST3Bundle(bundleURL)
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

    // Loading a VST3 module runs its static initializers and registers its
    // Objective-C classes. Vendors that ship both AU and VST3 (UADx, iZotope,
    // Waves) share class names and support bundles between the two, so
    // loading every VST3 into this process corrupts the AU versions. Modules
    // are therefore enumerated in a short-lived child process instead.
    private static let scanArgument = "--scan-vst3"
    private static let scanOutputMarker = "MYDAW_VST3_SCAN_RESULT:"

    private struct ScannedVST3: Codable {
        let uid: String
        let name: String
        let vendor: String
        let version: String
    }

    private struct VST3ScanCacheEntry: Codable {
        let modified: Double
        let plugins: [ScannedVST3]
    }

    public static func runVST3ScanChildIfRequested() {
        let arguments = CommandLine.arguments
        guard let flagIndex = arguments.firstIndex(of: scanArgument),
              flagIndex + 1 < arguments.count else { return }
        let bundleURL = URL(fileURLWithPath: arguments[flagIndex + 1])
        let scanned = VST3HostBridge.enumerate(bundleURL: bundleURL).map {
            ScannedVST3(uid: $0.uid, name: $0.name, vendor: $0.vendor, version: $0.version)
        }
        let json = (try? JSONEncoder().encode(scanned)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        FileHandle.standardOutput.write(Data("\n\(scanOutputMarker)\(json)\n".utf8))
        exit(0)
    }

    private static var scanCacheURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyDAW", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("vst3-scan-cache.json")
    }

    private lazy var vst3ScanCache: [String: VST3ScanCacheEntry] = {
        guard let data = try? Data(contentsOf: Self.scanCacheURL),
              let cache = try? JSONDecoder().decode([String: VST3ScanCacheEntry].self, from: data) else {
            return [:]
        }
        return cache
    }()

    private func scanVST3Bundle(_ bundleURL: URL) -> [VST3Metadata] {
        let modified = ((try? FileManager.default.attributesOfItem(atPath: bundleURL.path))?[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        let toMetadata: ([ScannedVST3]) -> [VST3Metadata] = { plugins in
            plugins.map { VST3Metadata(uid: $0.uid, name: $0.name, vendor: $0.vendor, version: $0.version) }
        }
        if let cached = vst3ScanCache[bundleURL.path], cached.modified == modified {
            return toMetadata(cached.plugins)
        }
        guard let scanned = runScanChild(for: bundleURL) else { return [] }
        vst3ScanCache[bundleURL.path] = VST3ScanCacheEntry(modified: modified, plugins: scanned)
        if let data = try? JSONEncoder().encode(vst3ScanCache) {
            try? data.write(to: Self.scanCacheURL, options: .atomic)
        }
        return toMetadata(scanned)
    }

    // Returns nil on timeout so the bundle is retried next launch; a crashed
    // child yields [] and is cached so a broken plugin isn't reloaded forever.
    private func runScanChild(for bundleURL: URL) -> [ScannedVST3]? {
        guard let executablePath = Bundle.main.executablePath else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [Self.scanArgument, bundleURL.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        var timedOut = false
        let watchdog = DispatchWorkItem {
            if process.isRunning {
                timedOut = true
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        if timedOut { return nil }

        let text = String(decoding: data, as: UTF8.self)
        guard let line = text.split(separator: "\n").last(where: { $0.hasPrefix(Self.scanOutputMarker) }),
              let json = line.dropFirst(Self.scanOutputMarker.count).data(using: .utf8),
              let scanned = try? JSONDecoder().decode([ScannedVST3].self, from: json) else {
            return []
        }
        return scanned
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
