import AVFoundation
import Foundation

/// Turns the real-time master capture (32-bit float, hardware rate) into the
/// exported file: sample-rate conversion when needed, then a 16-bit (TPDF
/// dithered) or 24-bit WAV, or an MP3 through LAME. Runs off the main thread.
enum ExportEncoder {
    private static let chunkFrames: AVAudioFrameCount = 32768

    static func encode(
        source sourceURL: URL,
        to destinationURL: URL,
        settings: ExportSettings,
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        let input = try AVAudioFile(forReading: sourceURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: settings.sampleRate,
            channels: 2,
            interleaved: false
        ) else {
            throw exportError(String(localized: "Could not prepare the master output."))
        }

        let sink: ExportSink
        switch settings.format {
        case .wav:
            sink = try WAVSink(url: destinationURL, sampleRate: settings.sampleRate, bitDepth: settings.wavBitDepth)
        case .mp3:
            sink = try MP3Sink(url: destinationURL, settings: settings)
        }

        let totalFrames = max(1, input.length)
        let reader = SourceReader(file: input, chunkFrames: chunkFrames)
        if input.processingFormat.sampleRate == outputFormat.sampleRate {
            while let buffer = try reader.next() {
                try checkCancelled()
                try sink.write(buffer)
                progress(Double(reader.framesRead) / Double(totalFrames))
            }
        } else {
            guard let converter = AVAudioConverter(from: input.processingFormat, to: outputFormat) else {
                throw exportError(String(localized: "Could not prepare the master output."))
            }
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            let ratio = outputFormat.sampleRate / input.processingFormat.sampleRate
            let outputCapacity = AVAudioFrameCount((Double(chunkFrames) * ratio).rounded(.up)) + 64
            var readError: Error?
            while true {
                try checkCancelled()
                guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else { break }
                var conversionError: NSError?
                let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                    do {
                        if let buffer = try reader.next() {
                            inputStatus.pointee = .haveData
                            return buffer
                        }
                    } catch {
                        readError = error
                    }
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                if let readError { throw readError }
                if status == .error { throw conversionError ?? exportError(String(localized: "Could not prepare the master output.")) }
                if output.frameLength > 0 {
                    try sink.write(output)
                }
                progress(Double(reader.framesRead) / Double(totalFrames))
                if status == .endOfStream { break }
            }
        }
        try sink.finish()
        progress(1.0)
    }

    private static func checkCancelled() throws {
        if Task.isCancelled { throw CancellationError() }
    }

    static func exportError(_ message: String) -> NSError {
        NSError(domain: "MyDAW.Export", code: 10, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Reads the capture file chunk by chunk.
private final class SourceReader {
    private let file: AVAudioFile
    private let chunkFrames: AVAudioFrameCount
    private(set) var framesRead: AVAudioFramePosition = 0

    init(file: AVAudioFile, chunkFrames: AVAudioFrameCount) {
        self.file = file
        self.chunkFrames = chunkFrames
    }

    func next() throws -> AVAudioPCMBuffer? {
        guard file.framePosition < file.length,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else { return nil }
        try file.read(into: buffer, frameCount: chunkFrames)
        guard buffer.frameLength > 0 else { return nil }
        framesRead += AVAudioFramePosition(buffer.frameLength)
        return buffer
    }
}

private protocol ExportSink {
    /// `buffer` is 32-bit float, non-interleaved stereo at the export rate.
    func write(_ buffer: AVAudioPCMBuffer) throws
    func finish() throws
}

// MARK: - WAV

private final class WAVSink: ExportSink {
    private let file: AVAudioFile
    private let bitDepth: Int
    private let int16Format: AVAudioFormat?
    private var random = DitherNoise()

    init(url: URL, sampleRate: Double, bitDepth: Int) throws {
        self.bitDepth = bitDepth
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        // 16-bit samples are quantized here (with dither); 24-bit ones are
        // left to the file's own float conversion.
        let commonFormat: AVAudioCommonFormat = bitDepth == 16 ? .pcmFormatInt16 : .pcmFormatFloat32
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: commonFormat, interleaved: false)
        int16Format = bitDepth == 16
            ? AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 2, interleaved: false)
            : nil
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        guard bitDepth == 16 else {
            try file.write(from: buffer)
            return
        }
        guard let int16Format,
              let source = buffer.floatChannelData,
              let output = AVAudioPCMBuffer(pcmFormat: int16Format, frameCapacity: buffer.frameLength),
              let destination = output.int16ChannelData else { return }
        let frames = Int(buffer.frameLength)
        // TPDF dither of ±1 LSB, then round and clip.
        for channel in 0..<2 {
            let input = source[min(channel, Int(buffer.format.channelCount) - 1)]
            let samples = destination[channel]
            for frame in 0..<frames {
                let dither = random.next() - random.next()
                let value = (input[frame] * 32768.0 + dither).rounded()
                samples[frame] = Int16(max(-32768.0, min(32767.0, value)))
            }
        }
        output.frameLength = buffer.frameLength
        try file.write(from: output)
    }

    func finish() throws {
        // AVAudioFile finalizes the header when it is released.
    }
}

/// Uniform noise in 0..<1 for the dither (xorshift32: fast, and plenty
/// random for this).
private struct DitherNoise {
    private var state: UInt32 = 0x9E37_79B9

    mutating func next() -> Float {
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return Float(state >> 8) * (1.0 / 16_777_216.0)
    }
}

// MARK: - MP3 (LAME)

private final class MP3Sink: ExportSink {
    private let lame: LAMELibrary
    private let gfp: OpaquePointer
    private let handle: FileHandle
    private var outputBuffer: [UInt8]

    init(url: URL, settings: ExportSettings) throws {
        lame = try LAMELibrary.shared()
        guard let gfp = lame.initialize() else {
            throw ExportEncoder.exportError(String(localized: "Could not start the MP3 encoder."))
        }
        self.gfp = gfp
        let rate = Int32(settings.sampleRate.rounded())
        _ = lame.setNumChannels(gfp, 2)
        _ = lame.setInSampleRate(gfp, rate)
        _ = lame.setOutSampleRate(gfp, rate)
        _ = lame.setMode(gfp, LAMELibrary.jointStereo)
        _ = lame.setQuality(gfp, 2)
        switch settings.mp3Mode {
        case .constant:
            _ = lame.setVBR(gfp, LAMELibrary.vbrOff)
            _ = lame.setBitrate(gfp, Int32(settings.mp3Bitrate))
        case .variable:
            _ = lame.setVBR(gfp, LAMELibrary.vbrDefault)
            _ = lame.setVBRQuality(gfp, Int32(settings.mp3VBRQuality.rawValue))
        }
        guard lame.initParams(gfp) >= 0 else {
            lame.close(gfp)
            throw ExportEncoder.exportError(String(localized: "Could not start the MP3 encoder."))
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            lame.close(gfp)
            throw ExportEncoder.exportError(String(localized: "Could not create the export file."))
        }
        self.handle = handle
        outputBuffer = [UInt8](repeating: 0, count: 7200)
    }

    deinit {
        lame.close(gfp)
        try? handle.close()
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let frames = Int(buffer.frameLength)
        let right = buffer.format.channelCount > 1 ? channels[1] : channels[0]
        // Worst case from lame.h: 1.25 * samples + 7200 bytes.
        let needed = frames + frames / 4 + 7200
        if outputBuffer.count < needed {
            outputBuffer = [UInt8](repeating: 0, count: needed)
        }
        let capacity = Int32(outputBuffer.count)
        let bytes = outputBuffer.withUnsafeMutableBufferPointer { output in
            lame.encodeFloat(gfp, channels[0], right, Int32(frames), output.baseAddress, capacity)
        }
        try append(bytes)
    }

    func finish() throws {
        let bytes = outputBuffer.withUnsafeMutableBufferPointer { output in
            lame.flush(gfp, output.baseAddress, Int32(output.count))
        }
        try append(bytes)
        // The Xing/LAME header frame (length and seek table) goes over the
        // placeholder LAME wrote first.
        var tag = [UInt8](repeating: 0, count: 2880)
        let tagSize = tag.withUnsafeMutableBufferPointer { lame.lametagFrame(gfp, $0.baseAddress, $0.count) }
        if tagSize > 0 && tagSize <= tag.count {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: tag[0..<tagSize])
        }
        try handle.synchronize()
    }

    private func append(_ count: Int32) throws {
        guard count >= 0 else {
            throw ExportEncoder.exportError(String(localized: "The MP3 encoder reported an error."))
        }
        if count > 0 {
            try handle.write(contentsOf: outputBuffer[0..<Int(count)])
        }
    }
}

/// libmp3lame, loaded at run time from the app's Frameworks folder (it is
/// LGPL, so it stays a separate, replaceable library).
private final class LAMELibrary: @unchecked Sendable {
    static let vbrOff: Int32 = 0
    static let vbrDefault: Int32 = 4 // vbr_mtrh
    static let jointStereo: Int32 = 1

    typealias InitFunction = @convention(c) () -> OpaquePointer?
    typealias SetIntFunction = @convention(c) (OpaquePointer?, Int32) -> Int32
    typealias GFPFunction = @convention(c) (OpaquePointer?) -> Int32
    typealias EncodeFloatFunction = @convention(c) (
        OpaquePointer?, UnsafePointer<Float>?, UnsafePointer<Float>?, Int32, UnsafeMutablePointer<UInt8>?, Int32
    ) -> Int32
    typealias FlushFunction = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt8>?, Int32) -> Int32
    typealias LametagFunction = @convention(c) (OpaquePointer?, UnsafeMutablePointer<UInt8>?, Int) -> Int

    let initialize: InitFunction
    let setNumChannels: SetIntFunction
    let setInSampleRate: SetIntFunction
    let setOutSampleRate: SetIntFunction
    let setMode: SetIntFunction
    let setQuality: SetIntFunction
    let setVBR: SetIntFunction
    let setVBRQuality: SetIntFunction
    let setBitrate: SetIntFunction
    let initParams: GFPFunction
    let encodeFloat: EncodeFloatFunction
    let flush: FlushFunction
    let lametagFrame: LametagFunction
    private let closeFunction: GFPFunction

    private static let lock = NSLock()
    private static var loaded: LAMELibrary?

    static let fileName = "libmp3lame.0.dylib"

    static func shared() throws -> LAMELibrary {
        try lock.withLock {
            if let loaded { return loaded }
            let library = try LAMELibrary()
            loaded = library
            return library
        }
    }

    private init() throws {
        let notFound = ExportEncoder.exportError(String(localized: "The MP3 encoder (libmp3lame) was not found in the app."))
        guard let url = Bundle.main.privateFrameworksURL?.appendingPathComponent(Self.fileName),
              let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            throw notFound
        }
        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let pointer = dlsym(handle, name) else { throw notFound }
            return unsafeBitCast(pointer, to: type)
        }
        initialize = try symbol("lame_init", as: InitFunction.self)
        setNumChannels = try symbol("lame_set_num_channels", as: SetIntFunction.self)
        setInSampleRate = try symbol("lame_set_in_samplerate", as: SetIntFunction.self)
        setOutSampleRate = try symbol("lame_set_out_samplerate", as: SetIntFunction.self)
        setMode = try symbol("lame_set_mode", as: SetIntFunction.self)
        setQuality = try symbol("lame_set_quality", as: SetIntFunction.self)
        setVBR = try symbol("lame_set_VBR", as: SetIntFunction.self)
        setVBRQuality = try symbol("lame_set_VBR_q", as: SetIntFunction.self)
        setBitrate = try symbol("lame_set_brate", as: SetIntFunction.self)
        initParams = try symbol("lame_init_params", as: GFPFunction.self)
        encodeFloat = try symbol("lame_encode_buffer_ieee_float", as: EncodeFloatFunction.self)
        flush = try symbol("lame_encode_flush", as: FlushFunction.self)
        lametagFrame = try symbol("lame_get_lametag_frame", as: LametagFunction.self)
        closeFunction = try symbol("lame_close", as: GFPFunction.self)
    }

    func close(_ gfp: OpaquePointer) {
        _ = closeFunction(gfp)
    }

    /// True when the library can be loaded (the dialog offers MP3 then).
    static var isAvailable: Bool {
        (try? shared()) != nil
    }
}

extension ExportEncoder {
    static var isMP3Available: Bool { LAMELibrary.isAvailable }
}
