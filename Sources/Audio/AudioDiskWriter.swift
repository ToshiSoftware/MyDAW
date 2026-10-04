import Foundation
import AVFoundation

public final class AudioDiskWriter: @unchecked Sendable {
    public let fileURL: URL
    public let sampleRate: Double
    public let channelCount: AVAudioChannelCount
    public let is24Bit: Bool

    private var audioFile: AVAudioFile?
    private let writeQueue: DispatchQueue
    private var totalFramesWritten: Int64 = 0
    private var isFinalized: Bool = false

    public init(
        destinationDirectory: URL,
        trackId: UUID,
        trackName: String,
        sampleRate: Double,
        channelCount: AVAudioChannelCount = 2,
        is24Bit: Bool = true
    ) throws {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.is24Bit = is24Bit

        // "<track name>_<take number>.wav". The file is created below, so a
        // second writer for a same-named track takes the next number.
        self.fileURL = RecordingFileName.nextURL(in: destinationDirectory, trackName: trackName)

        self.writeQueue = DispatchQueue(
            label: "com.mydaw.diskwriter.\(trackId.uuidString)",
            qos: .userInitiated
        )

        // 24-bit Linear PCM WAV configuration
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: is24Bit ? 24 : 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        // Write directly with processing format Float32 non-interleaved
        guard AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        ) != nil else {
            throw NSError(
                domain: "AudioDiskWriter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create processing audio format"]
            )
        }

        self.audioFile = try AVAudioFile(
            forWriting: fileURL,
            settings: fileSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    /// Asynchronously write incoming PCM buffer to disk to ensure zero audio glitching
    public func write(buffer: AVAudioPCMBuffer) {
        guard !isFinalized, let audioFile = self.audioFile else { return }

        // Make an exact copy of the buffer so audio thread can immediately reuse its buffer
        guard let bufferCopy = buffer.copy() as? AVAudioPCMBuffer else { return }

        writeQueue.async { [weak self] in
            guard let self = self, !self.isFinalized else { return }
            do {
                try audioFile.write(from: bufferCopy)
                self.totalFramesWritten += Int64(bufferCopy.frameLength)
            } catch {
                print("AudioDiskWriter error writing to \(self.fileURL.lastPathComponent): \(error)")
            }
        }
    }

    /// Finalize writing, flush queue, and close file
    public func finalize() async -> URL? {
        await withCheckedContinuation { continuation in
            writeQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: ())
                    return
                }
                self.isFinalized = true
                self.audioFile = nil // Flushes and closes the file descriptor
                print("AudioDiskWriter finalized: \(self.fileURL.lastPathComponent) (\(self.totalFramesWritten) frames)")
                continuation.resume(returning: ())
            }
        }
        return self.fileURL
    }
}

/// Names for files MyDAW writes into Recordings: "<name>_<number>.wav" —
/// "Bass_001.wav" for a take, "Reverse_Bass_001.wav" for a reversed clip,
/// "Import_001.wav" for an import. Channel count, rate and bit depth are in
/// the WAV header.
enum RecordingFileName {
    static let maximumNameLength = 40

    /// The track name made safe for a file name: whitespace (half- and
    /// full-width, and "_") becomes a single "_", other symbols and emoji are
    /// dropped, letters of any script are kept, in one Unicode form (NFC),
    /// at most `maximumNameLength` characters. "Track" if nothing is left.
    static func cleanTrackName(_ name: String) -> String {
        var result = ""
        var pendingSeparator = false
        for character in name.precomposedStringWithCanonicalMapping {
            if character.isWhitespace || character == "_" {
                pendingSeparator = !result.isEmpty
                continue
            }
            guard character.isLetter || character.isNumber || character == "-" else { continue }
            if pendingSeparator {
                result.append("_")
                pendingSeparator = false
            }
            result.append(character)
            if result.count >= maximumNameLength { break }
        }
        return result.isEmpty ? "Track" : result
    }

    /// The next free "<track name>_NNN.wav" in `directory`.
    static func nextURL(in directory: URL, trackName: String) -> URL {
        nextURL(in: directory, stem: cleanTrackName(trackName))
    }

    /// The next free "<stem>_NNN.wav" in `directory`: one past the highest
    /// number used there or in its Unused folder, so a file moved away and
    /// back never collides.
    static func nextURL(in directory: URL, stem: String) -> URL {
        let name = stem.precomposedStringWithCanonicalMapping
        let prefix = name + "_"
        var highest = 0
        for folder in [directory, directory.appendingPathComponent("Unused", isDirectory: true)] {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for url in files where url.pathExtension.lowercased() == "wav" {
                let stem = url.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping
                guard stem.hasPrefix(prefix) else { continue }
                let number = stem.dropFirst(prefix.count)
                guard number.count >= 3, number.allSatisfy({ $0.isASCII && $0.isNumber }),
                      let value = Int(number) else { continue }
                highest = max(highest, value)
            }
        }
        // Capped so a file numbered near Int.max cannot overflow.
        var take = min(highest, 999_999) + 1
        var url: URL
        repeat {
            url = directory.appendingPathComponent("\(name)_\(String(format: "%03d", take)).wav")
            take += 1
        } while FileManager.default.fileExists(atPath: url.path)
        return url
    }
}
