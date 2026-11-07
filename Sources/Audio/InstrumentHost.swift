import AVFoundation
import AudioToolbox
import CoreMIDI
import os

/// What one instrument track plays, built from its MIDI clips on the main
/// thread: channel messages at timeline frames (output rate), in the order
/// they are sent. Messages are packed as status | data1 << 8 | data2 << 16 |
/// length << 24.
struct MIDIPlaybackPlan: Sendable {
    var frames: [Int64] = []
    var messages: [UInt32] = []

    static func pack(status: UInt8, data1: UInt8, data2: UInt8) -> UInt32 {
        let kind = status & 0xF0
        let length: UInt32 = kind == 0xC0 || kind == 0xD0 ? 2 : 3
        return UInt32(status) | UInt32(data1) << 8 | UInt32(data2) << 16 | length << 24
    }

    /// The unmuted notes and events of the unmuted clips. A note is cut at
    /// its clip's end; at one frame note-offs go first and note-ons last, so
    /// a repeated note is released before it sounds again.
    @MainActor
    static func make(for track: AudioTrack, bpm: Double, sampleRate: Double) -> MIDIPlaybackPlan {
        var items: [(frame: Int64, order: Int, message: UInt32)] = []
        let frame = { (tick: Int) -> Int64 in
            Int64(saturating: (MIDITiming.seconds(ticks: tick, bpm: bpm) * sampleRate).rounded())
        }
        for clip in track.midiClips where !clip.isMuted {
            let contentEnd = clip.contentOffsetTicks + clip.lengthTicks
            for note in clip.audibleNotes where !note.isMuted {
                let on = clip.timelineTick(ofContentTick: note.startTick)
                let off = min(clip.timelineTick(ofContentTick: note.endTick), clip.endTick)
                items.append((frame(on), 2, pack(status: 0x90 | note.channel, data1: note.pitch, data2: note.velocity)))
                items.append((frame(off), 0, pack(status: 0x80 | note.channel, data1: note.pitch, data2: 0)))
            }
            for event in clip.events where event.tick >= clip.contentOffsetTicks && event.tick < contentEnd {
                items.append((
                    frame(clip.timelineTick(ofContentTick: event.tick)),
                    1,
                    pack(status: event.status, data1: event.data1, data2: event.data2)
                ))
            }
        }
        items.sort { ($0.frame, $0.order) < ($1.frame, $1.order) }
        return MIDIPlaybackPlan(frames: items.map(\.frame), messages: items.map(\.message))
    }

    /// The state the events before `frame` leave each channel in (program,
    /// controllers, pitch bend, pressure), to send before playing from there.
    /// A channel whose bend is changed later starts centred.
    func chase(before frame: Int64) -> [UInt32] {
        var programs: [UInt8: UInt32] = [:]
        var controllers: [Int: UInt32] = [:]
        var bends: [UInt8: UInt32] = [:]
        var pressures: [UInt8: UInt32] = [:]
        var bentChannels: Set<UInt8> = []
        for (index, message) in messages.enumerated() {
            let status = UInt8(message & 0xFF)
            let channel = status & 0x0F
            let isBefore = frames[index] < frame
            switch status & 0xF0 {
            case 0xC0 where isBefore: programs[channel] = message
            // Channel mode messages (120 and up) are not state to restore.
            case 0xB0 where isBefore && UInt8(message >> 8 & 0x7F) < 120:
                controllers[Int(channel) << 7 | Int(message >> 8 & 0x7F)] = message
            case 0xE0:
                bentChannels.insert(channel)
                if isBefore { bends[channel] = message }
            case 0xD0 where isBefore: pressures[channel] = message
            default: break
            }
        }
        for channel in bentChannels where bends[channel] == nil {
            bends[channel] = Self.pack(status: 0xE0 | channel, data1: 0, data2: 0x40)
        }
        return programs.keys.sorted().compactMap { programs[$0] }
            + controllers.keys.sorted().compactMap { controllers[$0] }
            + bends.keys.sorted().compactMap { bends[$0] }
            + pressures.keys.sorted().compactMap { pressures[$0] }
    }
}

/// Hands MIDI to one instrument plug-in on its own render thread: the
/// keyboard's messages as they come, and the track's MIDI clips at their
/// sample positions while the transport runs. Everything is sent with the
/// unit's `scheduleMIDIEventBlock` just before it renders, so the plug-in
/// only ever sees MIDI from the thread that renders it.
///
/// The transport follows `TrackRenderer`: timeline frame `anchorFrame` is
/// heard at host time `anchorHost`, and nothing before `renderFrom` plays.
final class InstrumentMIDIFeeder: @unchecked Sendable {
    private static let capacity = 1024

    // Shared with the render thread, under `lock` (the render thread only
    // tries it, and sends a busy cycle's messages on the next one).
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    /// Messages to send at once (keyboard, chase, silence), packed as in
    /// `MIDIPlaybackPlan`.
    private let messages: UnsafeMutablePointer<UInt32>
    private var count = 0
    private var scheduleMIDI: AUScheduleMIDIEventBlock?
    private var plan = MIDIPlaybackPlan()
    private var planGeneration = 0
    private var isRunning = false
    private var stopRequested = false
    private var anchorGeneration = 0
    private var anchorHost: UInt64 = 0
    private var anchorFrame: Int64 = 0
    private var renderFrom: Int64 = 0
    private var sampleRate: Double = 48_000

    // Render thread only.
    private var lastCycleSample: Float64 = -1
    private var renderPlanGeneration = -1
    private var renderAnchorGeneration = -1
    private var renderAnchorSample: Double = 0
    private var cursor = 0
    private var needsSeek = true
    /// A new plan came while playing: sounding notes it no longer ends are
    /// released, the others play on.
    private var needsReconcile = false
    /// Notes the plan has turned on, by channel << 7 | pitch.
    private let activeNotes: UnsafeMutablePointer<UInt8>
    private let secondsPerHostTick: Double

    private var observerToken: Int?
    private weak var unit: AUAudioUnit?

    init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        messages = .allocate(capacity: Self.capacity)
        activeNotes = .allocate(capacity: 16 * 128)
        activeNotes.initialize(repeating: 0, count: 16 * 128)
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        secondsPerHostTick = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000.0
    }

    deinit {
        detach()
        messages.deallocate()
        activeNotes.deallocate()
        lock.deallocate()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return body()
    }

    // MARK: Main thread

    /// Starts feeding `unit`. Call on the main thread once the unit is
    /// connected, so its MIDI block belongs to the allocated unit.
    func attach(to unit: AUAudioUnit, sampleRate: Double) {
        detach()
        let block = unit.scheduleMIDIEventBlock
        withLock {
            scheduleMIDI = block
            self.sampleRate = sampleRate
            count = 0
            needsSeek = true
        }
        self.unit = unit
        // Before the first bus pulled in a cycle, whichever it is: an
        // out-of-process unit loses MIDI scheduled after a cycle's first pull,
        // and with separate outputs bus 0 is not always first.
        observerToken = unit.token(byAddingRenderObserver: { [weak self] flags, timestamp, frames, _ in
            guard flags.contains(.unitRenderAction_PreRender), let self,
                  timestamp.pointee.mSampleTime != self.lastCycleSample else { return }
            self.lastCycleSample = timestamp.pointee.mSampleTime
            self.render(timestamp: timestamp, frames: Int(frames))
        })
    }

    func detach() {
        if let observerToken, let unit {
            unit.removeRenderObserver(observerToken)
        }
        observerToken = nil
        unit = nil
        withLock {
            scheduleMIDI = nil
            count = 0
        }
        activeNotes.update(repeating: 0, count: 16 * 128)
    }

    /// Takes a new plan; while playing, playback goes on from the current
    /// position, and only sounding notes the new plan does not end are
    /// released.
    func setPlan(_ newPlan: MIDIPlaybackPlan) {
        withLock {
            plan = newPlan
            planGeneration += 1
        }
    }

    /// Starts playing the plan (see the type's note on the anchor), after
    /// the `chase` messages.
    func start(anchorHost: UInt64, anchorFrame: Int64, renderFrom: Int64, chase: [UInt32]) {
        withLock {
            for message in chase {
                append(message)
            }
            self.anchorHost = anchorHost
            self.anchorFrame = anchorFrame
            self.renderFrom = max(0, renderFrom)
            anchorGeneration += 1
            stopRequested = false
            isRunning = true
        }
    }

    /// Moves the timeline against the clock (a plug-in latency changed).
    func setAnchorFrame(_ anchorFrame: Int64) {
        withLock {
            self.anchorFrame = anchorFrame
            anchorGeneration += 1
        }
    }

    /// Stops the plan, releasing its notes and the sustain pedal.
    func stop() {
        withLock {
            isRunning = false
            stopRequested = true
        }
    }

    /// Queues one channel message (1 to 3 bytes). A full queue drops it.
    func enqueue(status: UInt8, data1: UInt8, data2: UInt8, length: Int) {
        let packed = UInt32(status) | UInt32(data1) << 8 | UInt32(data2) << 16 | UInt32(length) << 24
        withLock { append(packed) }
    }

    private func append(_ packed: UInt32) {
        if count < Self.capacity {
            messages[count] = packed
            count += 1
        }
    }

    /// All Notes Off and sustain off on every channel, so nothing hangs when
    /// the keyboard stops feeding this instrument.
    func silence() {
        withLock { appendSilence() }
    }

    private func appendSilence() {
        for channel in UInt32(0)..<16 {
            append(0xB0 | channel | 64 << 8 | 3 << 24)
            append(0xB0 | channel | 123 << 8 | 3 << 24)
        }
    }

    // MARK: Render thread

    private func render(timestamp: UnsafePointer<AudioTimeStamp>, frames: Int) {
        guard os_unfair_lock_trylock(lock) else { return }
        defer { os_unfair_lock_unlock(lock) }
        guard let scheduleMIDI else {
            count = 0
            return
        }
        if planGeneration != renderPlanGeneration {
            renderPlanGeneration = planGeneration
            needsSeek = true
            needsReconcile = isRunning
        }
        if stopRequested {
            stopRequested = false
            releaseActiveNotes(scheduleMIDI)
            appendSilence()
        }
        for index in 0..<count {
            send(messages[index], offset: 0, scheduleMIDI, tracksNotes: false)
        }
        count = 0
        guard isRunning else { return }

        let time = timestamp.pointee
        if anchorGeneration != renderAnchorGeneration {
            renderAnchorGeneration = anchorGeneration
            let hostNow = time.mFlags.contains(.hostTimeValid)
                ? Double(time.mHostTime)
                : Double(mach_absolute_time())
            renderAnchorSample = time.mSampleTime
                + ((Double(anchorHost) - hostNow) * secondsPerHostTick * sampleRate).rounded()
            needsSeek = true
        }
        let firstFrame = anchorFrame + Int64((time.mSampleTime - renderAnchorSample).rounded())
        let endFrame = firstFrame + Int64(frames)
        if needsSeek {
            needsSeek = false
            cursor = lowerBound(max(renderFrom, firstFrame))
        }
        if needsReconcile {
            needsReconcile = false
            reconcileActiveNotes(scheduleMIDI)
        }
        let planFrames = plan.frames
        while cursor < planFrames.count, planFrames[cursor] < endFrame {
            let frame = planFrames[cursor]
            if frame >= renderFrom {
                // A message missed by a busy cycle goes out at the start of this one.
                send(plan.messages[cursor], offset: Int(max(0, frame - firstFrame)), scheduleMIDI)
            }
            cursor += 1
        }
    }

    private func lowerBound(_ frame: Int64) -> Int {
        var low = 0
        var high = plan.frames.count
        while low < high {
            let middle = (low + high) / 2
            if plan.frames[middle] < frame { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// `tracksNotes`: counts the plan's notes (not the keyboard's, which
    /// the plan never releases).
    private func send(_ packed: UInt32, offset: Int, _ scheduleMIDI: AUScheduleMIDIEventBlock, tracksNotes: Bool = true) {
        var bytes: (UInt8, UInt8, UInt8) = (UInt8(packed & 0xFF), UInt8(packed >> 8 & 0xFF), UInt8(packed >> 16 & 0xFF))
        let length = Int(packed >> 24)
        let kind = bytes.0 & 0xF0
        let key = Int(bytes.0 & 0x0F) << 7 | Int(bytes.1 & 0x7F)
        if !tracksNotes {
            // Not counted.
        } else if kind == 0x90 && bytes.2 > 0 {
            activeNotes[key] = activeNotes[key] &+ (activeNotes[key] < 255 ? 1 : 0)
        } else if (kind == 0x80 || kind == 0x90) && activeNotes[key] > 0 {
            activeNotes[key] -= 1
        }
        withUnsafeBytes(of: &bytes) { raw in
            scheduleMIDI(AUEventSampleTimeImmediate + AUEventSampleTime(offset), 0, length,
                         raw.bindMemory(to: UInt8.self).baseAddress!)
        }
    }

    /// Keeps a sounding note when the plan still releases it before it
    /// sounds again; releases it now otherwise (deleted, moved away).
    private func reconcileActiveNotes(_ scheduleMIDI: AUScheduleMIDIEventBlock) {
        for key in 0..<(16 * 128) where activeNotes[key] > 0 {
            var isReleasedLater = false
            var index = cursor
            while index < plan.messages.count {
                let message = plan.messages[index]
                let status = UInt8(message & 0xFF)
                let kind = status & 0xF0
                if (kind == 0x80 || kind == 0x90),
                   Int(status & 0x0F) << 7 | Int(message >> 8 & 0x7F) == key {
                    isReleasedLater = kind == 0x80 || (message >> 16 & 0x7F) == 0
                    break
                }
                index += 1
            }
            guard !isReleasedLater else { continue }
            activeNotes[key] = 0
            var bytes: (UInt8, UInt8, UInt8) = (0x80 | UInt8(key >> 7), UInt8(key & 0x7F), 0)
            withUnsafeBytes(of: &bytes) { raw in
                scheduleMIDI(AUEventSampleTimeImmediate, 0, 3, raw.bindMemory(to: UInt8.self).baseAddress!)
            }
        }
    }

    private func releaseActiveNotes(_ scheduleMIDI: AUScheduleMIDIEventBlock) {
        for key in 0..<(16 * 128) where activeNotes[key] > 0 {
            activeNotes[key] = 0
            var bytes: (UInt8, UInt8, UInt8) = (0x80 | UInt8(key >> 7), UInt8(key & 0x7F), 0)
            withUnsafeBytes(of: &bytes) { raw in
                scheduleMIDI(AUEventSampleTimeImmediate, 0, 3, raw.bindMemory(to: UInt8.self).baseAddress!)
            }
        }
    }
}

/// Counts one source's messages on the CoreMIDI thread, for the main thread
/// to compare.
final class MIDIMessageCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count: UInt64 = 0

    func increment() {
        lock.lock()
        count &+= 1
        lock.unlock()
    }

    var value: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// A MIDI source being received.
struct MIDIInputSource: Equatable, @unchecked Sendable {
    /// The device's unique ID (the source's own for an app's virtual source).
    let deviceID: MIDIUniqueID
    let deviceName: String
    let portName: String
    let messages: MIDIMessageCounter

    static func == (a: MIDIInputSource, b: MIDIInputSource) -> Bool {
        a.deviceID == b.deviceID && a.deviceName == b.deviceName
            && a.portName == b.portName && a.messages === b.messages
    }
}

/// One device in the status bar; its ports share a light.
struct MIDIInputDevice: Identifiable, Equatable {
    let id: MIDIUniqueID
    let name: String
    let portNames: [String]
}

/// What the status bar shows about MIDI input, in its own object so that the
/// lights going on and off redraw only that item.
@MainActor
public final class MIDIInputStatus: ObservableObject {
    /// Each device once, in CoreMIDI's order.
    @Published private(set) var devices: [MIDIInputDevice] = []
    /// The devices a message came from just now.
    @Published private(set) var receivingDeviceIDs: Set<MIDIUniqueID> = []

    /// A message lights the mark at least this long, so a short tap shows.
    private static let holdSeconds = 0.12
    private var sources: [MIDIInputSource] = []
    private var lastCounts: [ObjectIdentifier: UInt64] = [:]
    private var lastMessageTimes: [MIDIUniqueID: Date] = [:]
    private var timer: Timer?

    init() {
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            onMainThread { self?.updateLights() }
        }
        // .common: the lights keep working while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func setSources(_ newSources: [MIDIInputSource]) {
        guard newSources != sources else { return }
        sources = newSources
        var order: [MIDIUniqueID] = []
        var names: [MIDIUniqueID: String] = [:]
        var ports: [MIDIUniqueID: [String]] = [:]
        for source in newSources {
            if names[source.deviceID] == nil {
                order.append(source.deviceID)
                names[source.deviceID] = source.deviceName
            }
            ports[source.deviceID, default: []].append(source.portName)
        }
        devices = order.map { MIDIInputDevice(id: $0, name: names[$0] ?? "?", portNames: ports[$0] ?? []) }
    }

    private func updateLights() {
        let now = Date()
        for source in sources {
            let count = source.messages.value
            let key = ObjectIdentifier(source.messages)
            guard let last = lastCounts[key] else {
                // First seen: what it counted before is not news.
                lastCounts[key] = count
                continue
            }
            if count != last {
                lastCounts[key] = count
                lastMessageTimes[source.deviceID] = now
            }
        }
        let receiving = Set(sources.map(\.deviceID).filter { id in
            lastMessageTimes[id].map { now.timeIntervalSince($0) < Self.holdSeconds } ?? false
        })
        if receiving != receivingDeviceIDs { receivingDeviceIDs = receiving }
    }
}

/// Receives every MIDI source on the Mac (MyDAW is played from one keyboard)
/// and passes channel messages on. Sources plugged in later are connected
/// as they appear.
final class MIDIInputManager: @unchecked Sendable {
    /// Called on the CoreMIDI thread for each channel message, with the host
    /// time it arrived.
    var onMessage: (@Sendable (_ status: UInt8, _ data1: UInt8, _ data2: UInt8, _ length: Int, _ hostTime: UInt64) -> Void)?
    /// Called on the main thread with the sources being received.
    var onSourcesChanged: (([MIDIInputSource]) -> Void)?

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var connectedSources: Set<MIDIUniqueID> = []
    /// Kept for good: CoreMIDI hands them back to `receive` by address.
    private var counters: [MIDIUniqueID: MIDIMessageCounter] = [:]

    func start() {
        guard client == 0 else { return }
        var status = MIDIClientCreateWithBlock("MyDAW" as CFString, &client) { [weak self] notification in
            let message = notification.pointee.messageID
            // Property changes cover a device going offline or being renamed.
            if message == .msgSetupChanged || message == .msgPropertyChanged {
                DispatchQueue.main.async { self?.connectAllSources() }
            }
        }
        guard status == noErr else {
            print("[MIDI] Could not create the MIDI client: \(status)")
            return
        }
        status = MIDIInputPortCreateWithProtocol(client, "MyDAW Input" as CFString, ._1_0, &port) { [weak self] eventList, sourceRef in
            self?.receive(eventList, sourceRef: sourceRef)
        }
        guard status == noErr else {
            print("[MIDI] Could not create the MIDI input port: \(status)")
            return
        }
        connectAllSources()
    }

    private func connectAllSources() {
        guard port != 0 else { return }
        var present: Set<MIDIUniqueID> = []
        var receiving: [MIDIInputSource] = []
        for index in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(index)
            var uniqueID: MIDIUniqueID = 0
            MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &uniqueID)
            present.insert(uniqueID)
            let portName = Self.string(kMIDIPropertyDisplayName, of: source) ?? "?"
            let counter = counters[uniqueID] ?? MIDIMessageCounter()
            counters[uniqueID] = counter
            if !connectedSources.contains(uniqueID),
               MIDIPortConnectSource(port, source, Unmanaged.passUnretained(counter).toOpaque()) == noErr {
                print("[MIDI] Connected input: \(portName)")
                connectedSources.insert(uniqueID)
            }
            var offline: Int32 = 0
            MIDIObjectGetIntegerProperty(source, kMIDIPropertyOffline, &offline)
            if connectedSources.contains(uniqueID), offline == 0 {
                let device = Self.device(of: source)
                receiving.append(MIDIInputSource(
                    deviceID: device?.id ?? uniqueID,
                    deviceName: device?.name ?? portName,
                    portName: portName,
                    messages: counter
                ))
            }
        }
        // A removed source is disconnected by CoreMIDI; forget it so it is
        // connected again when it comes back.
        connectedSources.formIntersection(present)
        onSourcesChanged?(receiving)
    }

    private static func string(_ property: CFString, of object: MIDIObjectRef) -> String? {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, property, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    /// The device a source belongs to; nil for a virtual source of an app.
    private static func device(of source: MIDIEndpointRef) -> (id: MIDIUniqueID, name: String)? {
        var entity = MIDIEntityRef()
        var device = MIDIDeviceRef()
        guard MIDIEndpointGetEntity(source, &entity) == noErr, entity != 0,
              MIDIEntityGetDevice(entity, &device) == noErr, device != 0,
              let name = string(kMIDIPropertyName, of: device) else { return nil }
        var id: MIDIUniqueID = 0
        MIDIObjectGetIntegerProperty(device, kMIDIPropertyUniqueID, &id)
        return (id, name)
    }

    /// Words per universal MIDI packet, by message type.
    private static let packetWords: [Int] = [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4]

    private func receive(_ eventList: UnsafePointer<MIDIEventList>, sourceRef: UnsafeMutableRawPointer?) {
        guard let onMessage else { return }
        let counter = sourceRef.map { Unmanaged<MIDIMessageCounter>.fromOpaque($0).takeUnretainedValue() }
        for packet in eventList.unsafeSequence() {
            let wordCount = Int(packet.pointee.wordCount)
            let stamp = packet.pointee.timeStamp
            let hostTime = stamp == 0 ? mach_absolute_time() : stamp
            withUnsafeBytes(of: packet.pointee.words) { raw in
                let words = raw.bindMemory(to: UInt32.self)
                var index = 0
                while index < min(wordCount, words.count) {
                    let word = words[index]
                    let type = Int(word >> 28)
                    // Type 2: a MIDI 1.0 channel voice message.
                    if type == 2 {
                        let status = UInt8(word >> 16 & 0xFF)
                        let data1 = UInt8(word >> 8 & 0x7F)
                        let data2 = UInt8(word & 0x7F)
                        let kind = status & 0xF0
                        counter?.increment()
                        onMessage(status, data1, data2, kind == 0xC0 || kind == 0xD0 ? 2 : 3, hostTime)
                    }
                    index += Self.packetWords[type]
                }
            }
        }
    }
}

/// What a MIDI recording does to the notes already in the recorded range.
public enum MIDIRecordMode: String, CaseIterable, Sendable {
    /// Keeps them; the new clip lies over them.
    case overdub
    /// Removes them from the track's other clips.
    case replace
}

/// One track's MIDI clip being recorded. Notes are added as their keys go
/// down and drawn growing until they are released.
@MainActor
struct MIDIRecordingTake {
    let track: AudioTrack
    let clip: MIDIClip
    let ticksPerBar: Int
    /// Held notes: index in the clip's notes by channel << 7 | pitch.
    private var held: [Int: Int] = [:]

    init(track: AudioTrack, clip: MIDIClip, ticksPerBar: Int) {
        self.track = track
        self.clip = clip
        self.ticksPerBar = ticksPerBar
    }

    /// Adds a keyboard message played at timeline `seconds`. Notes start and
    /// other messages count only inside `range`; a held note's release is
    /// always taken.
    mutating func receive(_ message: UInt32, at seconds: Double, range: Range<Double>, bpm: Double) {
        let status = UInt8(message & 0xFF)
        let data1 = UInt8(message >> 8 & 0x7F)
        let data2 = UInt8(message >> 16 & 0x7F)
        let kind = status & 0xF0
        let key = Int(status & 0x0F) << 7 | Int(data1)
        let tick = MIDITiming.ticks(seconds: max(0.0, seconds), bpm: bpm) - clip.startTick
        if kind == 0x90 && data2 > 0 {
            guard range.contains(seconds) else { return }
            if held[key] != nil {
                release(key, at: tick)
            }
            held[key] = clip.notes.count
            clip.notes.append(MIDINote(startTick: max(0, tick), lengthTicks: 1, pitch: data1, velocity: data2, channel: status & 0x0F))
        } else if kind == 0x80 || kind == 0x90 {
            release(key, at: tick)
        } else if range.contains(seconds) {
            clip.events.append(MIDIChannelEvent(tick: max(0, tick), status: status, data1: data1, data2: data2))
        }
    }

    private mutating func release(_ key: Int, at tick: Int) {
        guard let index = held.removeValue(forKey: key), clip.notes.indices.contains(index) else { return }
        clip.notes[index].lengthTicks = max(1, tick - clip.notes[index].startTick)
    }

    /// Draws held notes up to `seconds` and keeps the clip a bar past them.
    mutating func grow(to seconds: Double, bpm: Double) {
        let tick = MIDITiming.ticks(seconds: max(0.0, seconds), bpm: bpm) - clip.startTick
        if !held.isEmpty {
            var notes = clip.notes
            for index in held.values where notes.indices.contains(index) {
                notes[index].lengthTicks = max(1, tick - notes[index].startTick)
            }
            clip.notes = notes
        }
        let length = max(ticksPerBar, (tick + ticksPerBar) / ticksPerBar * ticksPerBar)
        if length > clip.lengthTicks {
            clip.lengthTicks = length
        }
    }

    mutating func closeHeldNotes(at seconds: Double, bpm: Double) {
        let tick = MIDITiming.ticks(seconds: max(0.0, seconds), bpm: bpm) - clip.startTick
        for key in Array(held.keys) {
            release(key, at: tick)
        }
    }
}
