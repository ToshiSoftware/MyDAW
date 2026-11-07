import Foundation

public struct VST3Metadata: Sendable {
    public let uid: String
    public let name: String
    public let vendor: String
    public let version: String
}

private typealias VST3MetadataCallback = @convention(c) (
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UnsafePointer<CChar>?,
    UnsafeMutableRawPointer?
) -> Void

@_silgen_name("MyDAWVST3EnumerateAudioEffects")
private func myDAWVST3EnumerateAudioEffects(
    _ bundlePath: UnsafePointer<CChar>,
    _ callback: VST3MetadataCallback,
    _ context: UnsafeMutableRawPointer?
) -> Int32

private final class VST3MetadataCollector {
    var values: [VST3Metadata] = []

    func append(
        uid: UnsafePointer<CChar>?,
        name: UnsafePointer<CChar>?,
        vendor: UnsafePointer<CChar>?,
        version: UnsafePointer<CChar>?
    ) {
        guard let uid, let name else { return }
        values.append(
            VST3Metadata(
                uid: String(cString: uid),
                name: String(cString: name),
                vendor: vendor.map(String.init(cString:)) ?? "",
                version: version.map(String.init(cString:)) ?? ""
            )
        )
    }
}

private let vst3MetadataCallback: VST3MetadataCallback = {
    uid, name, vendor, version, context in
    guard let context else { return }
    let collector = Unmanaged<VST3MetadataCollector>
        .fromOpaque(context)
        .takeUnretainedValue()
    collector.append(uid: uid, name: name, vendor: vendor, version: version)
}

public enum VST3HostBridge {
    public static func enumerate(bundleURL: URL) -> [VST3Metadata] {
        let collector = VST3MetadataCollector()
        let context = Unmanaged.passUnretained(collector).toOpaque()
        let result = bundleURL.path.withCString { path in
            myDAWVST3EnumerateAudioEffects(path, vst3MetadataCallback, context)
        }
        return result >= 0 ? collector.values : []
    }
}
