import Foundation

/// The file format chosen in the master export dialog; saved with the project.
public struct ExportSettings: Codable, Equatable {
    public enum FileFormat: String, Codable, CaseIterable {
        case wav, mp3

        public var fileExtension: String { rawValue }
    }

    public enum MP3Mode: String, Codable, CaseIterable {
        case constant, variable
    }

    /// LAME VBR quality presets (V0 = highest).
    public enum MP3VBRQuality: Int, Codable, CaseIterable {
        case v0 = 0, v2 = 2, v4 = 4
    }

    public static let sampleRates: [Double] = [44100.0, 48000.0, 96000.0]
    /// MPEG-1 Layer III stops at 48 kHz.
    public static let mp3SampleRates: [Double] = [44100.0, 48000.0]
    public static let wavBitDepths: [Int] = [16, 24]
    public static let mp3Bitrates: [Int] = [128, 192, 256, 320]

    public var format: FileFormat = .wav
    public var sampleRate: Double = 48000.0
    public var wavBitDepth: Int = 24
    public var mp3Mode: MP3Mode = .constant
    public var mp3Bitrate: Int = 320
    public var mp3VBRQuality: MP3VBRQuality = .v0

    public init() {}

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ExportSettings()
        format = try values.decodeIfPresent(FileFormat.self, forKey: .format) ?? defaults.format
        sampleRate = try values.decodeIfPresent(Double.self, forKey: .sampleRate) ?? defaults.sampleRate
        wavBitDepth = try values.decodeIfPresent(Int.self, forKey: .wavBitDepth) ?? defaults.wavBitDepth
        mp3Mode = try values.decodeIfPresent(MP3Mode.self, forKey: .mp3Mode) ?? defaults.mp3Mode
        mp3Bitrate = try values.decodeIfPresent(Int.self, forKey: .mp3Bitrate) ?? defaults.mp3Bitrate
        mp3VBRQuality = try values.decodeIfPresent(MP3VBRQuality.self, forKey: .mp3VBRQuality) ?? defaults.mp3VBRQuality
        normalize()
    }

    /// Pulls any value outside the supported choices back to one of them.
    public mutating func normalize() {
        let rates = format == .mp3 ? Self.mp3SampleRates : Self.sampleRates
        if !rates.contains(sampleRate) {
            sampleRate = rates.min(by: { abs($0 - sampleRate) < abs($1 - sampleRate) }) ?? 48000.0
        }
        if !Self.wavBitDepths.contains(wavBitDepth) { wavBitDepth = 24 }
        if !Self.mp3Bitrates.contains(mp3Bitrate) { mp3Bitrate = 320 }
    }
}
