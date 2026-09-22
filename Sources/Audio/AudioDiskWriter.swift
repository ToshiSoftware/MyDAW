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

        let cleanName = trackName
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        let timestamp = Int(Date().timeIntervalSince1970)
        let sampleRateLabel = String(format: "%.0fHz", sampleRate)
        let bitDepth = is24Bit ? 24 : 16
        let fileName = "Rec_\(cleanName.isEmpty ? "Track" : cleanName)_\(trackId.uuidString.prefix(6))_\(channelCount)ch_\(sampleRateLabel)_\(bitDepth)bit_\(timestamp).wav"
        self.fileURL = destinationDirectory.appendingPathComponent(fileName)

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
