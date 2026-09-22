import Foundation
import CoreAudio
import AVFoundation

public struct AudioInputChannelOption: Identifiable, Hashable, Sendable {
    public let id: Int
    public let channelOffset: Int
    public let name: String
    public let isStereo: Bool

    public init(id: Int, channelOffset: Int, name: String, isStereo: Bool) {
        self.id = id
        self.channelOffset = channelOffset
        self.name = name
        self.isStereo = isStereo
    }
}

public struct AudioDeviceOption: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let name: String

    public init(id: AudioDeviceID, name: String) {
        self.id = id
        self.name = name
    }
}

public final class AudioDeviceManager: ObservableObject {
    @Published public var deviceName: String = "Default Audio Interface"
    @Published public var availableMonoChannels: [AudioInputChannelOption] = []
    @Published public var availableStereoChannels: [AudioInputChannelOption] = []
    @Published public var hardwareInputChannelCount: Int = 2
    @Published public var hardwareSampleRate: Double = 48000.0
    @Published public var bufferFrameSize: Int = 1024
    @Published public var inputDevices: [AudioDeviceOption] = []
    @Published public var outputDevices: [AudioDeviceOption] = []
    @Published public var selectedInputDeviceID: AudioDeviceID = 0
    @Published public var selectedOutputDeviceID: AudioDeviceID = 0

    public init() {
        refreshHardwareInfo()
    }

    public func refreshHardwareInfo() {
        let devices = allAudioDevices()
        let defaultInputDeviceID = defaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice)
        let defaultOutputDeviceID = defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
        inputDevices = devices.filter { hasChannels($0.id, scope: kAudioDevicePropertyScopeInput) }
        outputDevices = devices.filter { hasChannels($0.id, scope: kAudioDevicePropertyScopeOutput) }
        selectedInputDeviceID = defaultInputDeviceID
        selectedOutputDeviceID = defaultOutputDeviceID

        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &selectedInputDeviceID
        )

        var detectedName = "Default Input"
        var detectedChannels = 2
        var detectedSampleRate = 48000.0

        if status == noErr && defaultInputDeviceID != 0 {
            // Get Device Name
            var nameSize = UInt32(256)
            var cName = [CChar](repeating: 0, count: 256)
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectGetPropertyData(defaultInputDeviceID, &nameAddress, 0, nil, &nameSize, &cName) == noErr {
                let str = String(cString: cName)
                if !str.isEmpty {
                    detectedName = str
                }
            }

            // Get Input Stream Channel Count
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            if AudioObjectGetPropertyDataSize(defaultInputDeviceID, &streamAddress, 0, nil, &streamSize) == noErr && streamSize > 0 {
                let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(streamSize))
                defer { bufferListPtr.deallocate() }
                if AudioObjectGetPropertyData(defaultInputDeviceID, &streamAddress, 0, nil, &streamSize, bufferListPtr) == noErr {
                    let numBuffers = Int(bufferListPtr.pointee.mNumberBuffers)
                    var count = 0
                    withUnsafePointer(to: &bufferListPtr.pointee.mBuffers) { ptr in
                        for i in 0..<numBuffers {
                            count += Int(ptr.advanced(by: i).pointee.mNumberChannels)
                        }
                    }
                    if count > 0 {
                        detectedChannels = count
                    }
                }
            }

            // Get Sample Rate
            var srSize = UInt32(MemoryLayout<Float64>.size)
            var srAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var sr: Float64 = 48000.0
            if AudioObjectGetPropertyData(defaultInputDeviceID, &srAddress, 0, nil, &srSize, &sr) == noErr {
                detectedSampleRate = Double(sr)
            }
        }

        self.deviceName = detectedName
        self.hardwareInputChannelCount = detectedChannels
        self.hardwareSampleRate = detectedSampleRate
        self.bufferFrameSize = readBufferFrameSize(for: defaultInputDeviceID) ?? 1024

        // Build Mono Channel list
        var monoList: [AudioInputChannelOption] = []
        for i in 0..<detectedChannels {
            monoList.append(
                AudioInputChannelOption(
                    id: i,
                    channelOffset: i,
                    name: "Input \(i + 1)",
                    isStereo: false
                )
            )
        }
        self.availableMonoChannels = monoList

        // Build Stereo Channel list
        var stereoList: [AudioInputChannelOption] = []
        for i in stride(from: 0, to: max(1, detectedChannels - 1), by: 2) {
            stereoList.append(
                AudioInputChannelOption(
                    id: i,
                    channelOffset: i,
                    name: "Input \(i + 1)-\(i + 2)",
                    isStereo: true
                )
            )
        }
        if stereoList.isEmpty {
            stereoList.append(
                AudioInputChannelOption(
                    id: 0,
                    channelOffset: 0,
                    name: "Input 1-2",
                    isStereo: true
                )
            )
        }
        self.availableStereoChannels = stereoList
    }

    public func channels(for mode: ChannelMode) -> [AudioInputChannelOption] {
        switch mode {
        case .mono:
            return availableMonoChannels
        case .stereo:
            return availableStereoChannels
        }
    }

    public func setBufferFrameSize(_ frameCount: Int) -> Bool {
        let clampedFrameCount = max(128, min(4096, frameCount))
        let inputDevice = defaultDevice(selector: kAudioHardwarePropertyDefaultInputDevice)
        let outputDevice = defaultDevice(selector: kAudioHardwarePropertyDefaultOutputDevice)
        var succeeded = false

        for deviceID in Set([inputDevice, outputDevice]).filter({ $0 != 0 }) {
            var value = UInt32(clampedFrameCount)
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyBufferFrameSize,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectSetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<UInt32>.size),
                &value
            )
            succeeded = succeeded || status == noErr
        }

        if succeeded {
            bufferFrameSize = clampedFrameCount
        }
        return succeeded
    }

    private func defaultDevice(selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        return deviceID
    }

    private func allAudioDevices() -> [AudioDeviceOption] {
        var size: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.map { AudioDeviceOption(id: $0, name: deviceName(for: $0)) }
    }

    private func deviceName(for deviceID: AudioDeviceID) -> String {
        var nameSize = UInt32(256)
        var cName = [CChar](repeating: 0, count: 256)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &nameSize, &cName) == noErr else {
            return "Audio Device \(deviceID)"
        }
        return String(cString: cName)
    }

    private func hasChannels(_ deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let bufferListPtr = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { bufferListPtr.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferListPtr) == noErr else { return false }
        let count = Int(bufferListPtr.pointee.mNumberBuffers)
        var channels = 0
        withUnsafePointer(to: &bufferListPtr.pointee.mBuffers) { ptr in
            for index in 0..<count {
                channels += Int(ptr.advanced(by: index).pointee.mNumberChannels)
            }
        }
        return channels > 0
    }

    private func readBufferFrameSize(for deviceID: AudioDeviceID) -> Int? {
        guard deviceID != 0 else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return Int(value)
    }
}
