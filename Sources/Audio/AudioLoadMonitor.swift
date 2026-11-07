import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio

/// Values shared with the render thread. The render thread only writes
/// aligned 64-bit fields (no locks, no allocation); the main thread reads the
/// running totals and keeps its own previous values to take differences.
private struct RenderStats {
    var ticksPerSecond: Double = 1.0e9
    var sampleRate: Double = 48_000.0
    /// Test aid: added to every measured cycle's load (0.7 = +70%).
    var testLoadOffset: Double = 0.0

    // Render thread only.
    var cycleStart: UInt64 = 0
    var lastCycleEnd: UInt64 = 0
    var expectedSampleTime: Double = -1.0
    var warmupCycles: Int64 = 0

    // Written by the render thread, read by the main thread.
    var cycles: UInt64 = 0
    var busyTicks: UInt64 = 0
    var budgetTicks: UInt64 = 0
    /// Highest load since the main thread last cleared it.
    var peakLoad: Double = 0.0
    var overruns: UInt64 = 0
    var restartTime: UInt64 = 0
}

/// Cycles after an engine (re)start that are neither measured nor counted
/// as dropouts: the first renders after a start are often slow (plug-ins
/// warming up) without the output being audible yet.
private let warmupCycleCount: Int64 = 16

/// Pre/post render notification of the output unit. Bus 0 is one I/O cycle
/// of the whole graph; the time between the two is the processing load.
private let renderNotify: AURenderCallback = { refCon, flags, timeStamp, bus, frames, _ in
    guard bus == 0 else { return noErr }
    let stats = refCon.assumingMemoryBound(to: RenderStats.self)
    let now = mach_absolute_time()

    if flags.pointee.contains(.unitRenderAction_PreRender) {
        let time = timeStamp.pointee
        let sampleTimeValid = time.mFlags.contains(.sampleTimeValid)
        let idleSeconds = Double(now &- stats.pointee.lastCycleEnd) / stats.pointee.ticksPerSecond
        // The engine stopped and started again: the I/O sat idle, or the
        // device sample time began again from zero.
        let restarted = stats.pointee.lastCycleEnd == 0 || idleSeconds > 0.25 ||
            (sampleTimeValid && time.mSampleTime < stats.pointee.expectedSampleTime - Double(frames))
        if restarted {
            stats.pointee.warmupCycles = warmupCycleCount
            stats.pointee.restartTime = now
        } else if sampleTimeValid,
                  stats.pointee.warmupCycles == 0,
                  stats.pointee.expectedSampleTime >= 0,
                  time.mSampleTime > stats.pointee.expectedSampleTime + Double(frames) / 2 {
            // The device moved on further than one cycle: cycles were skipped.
            stats.pointee.overruns &+= 1
        }
        stats.pointee.expectedSampleTime = sampleTimeValid ? time.mSampleTime + Double(frames) : -1.0
        stats.pointee.cycleStart = now
    } else if flags.pointee.contains(.unitRenderAction_PostRender) {
        stats.pointee.lastCycleEnd = now
        guard stats.pointee.cycleStart != 0 else { return noErr }
        if stats.pointee.warmupCycles > 0 {
            stats.pointee.warmupCycles -= 1
            return noErr
        }
        let budget = UInt64(Double(frames) / stats.pointee.sampleRate * stats.pointee.ticksPerSecond)
        guard budget > 0 else { return noErr }
        let busy = (now &- stats.pointee.cycleStart) &+
            UInt64(stats.pointee.testLoadOffset * Double(budget))
        let load = Double(busy) / Double(budget)
        // Rendering one cycle took longer than the cycle lasts.
        if load > 1.0 {
            stats.pointee.overruns &+= 1
        }
        if load > stats.pointee.peakLoad {
            stats.pointee.peakLoad = load
        }
        stats.pointee.busyTicks &+= busy
        stats.pointee.budgetTicks &+= budget
        stats.pointee.cycles &+= 1
    }
    return noErr
}

/// Audio processing load and dropouts for the status bar.
///
/// - Load: time the output unit's render cycle takes ÷ the cycle's length,
///   measured with a render notification on `engine.outputNode`.
/// - Dropouts: a cycle that took longer than its length, skipped cycles
///   (the device sample time jumps), and Core Audio's own overload report
///   (`kAudioDeviceProcessorOverload`) from the devices in use.
///
/// Only `load` and `isShowingDropout` are published, at most 10 times a
/// second, so views observing the engine are not redrawn by it.
@MainActor
public final class AudioLoadMonitor: ObservableObject {
    /// How long the dropout mark stays after the last dropout.
    static let dropoutDisplaySeconds: TimeInterval = 3.0

    /// Test aid: percent added to the measured load, so the bar colours and
    /// the dropout mark (above 100%) can be checked without real overloads.
    /// For one launch: `open MyDAW.app --args -MyDAW.loadTestOffset 70`.
    /// Until removed: `defaults write com.tokada.MyDAW MyDAW.loadTestOffset -int 70`
    /// (`defaults delete com.tokada.MyDAW MyDAW.loadTestOffset` turns it off).
    static let testOffsetDefaultsKey = "MyDAW.loadTestOffset"

    /// Percent added to the load for testing (0 = off).
    public let testOffsetPercent: Int

    /// Smoothed load for the bar: 0 = idle, 1 = the whole cycle is used.
    @Published public private(set) var load: Double = 0.0
    @Published public private(set) var isShowingDropout = false

    /// For the tooltip; not published.
    public private(set) var averageLoad: Double = 0.0
    public private(set) var peakLoad: Double = 0.0
    /// CPU time of the whole MyDAW process over the last second, as a share
    /// of all cores (1 = every core busy).
    public private(set) var processCPU: Double = 0.0
    public private(set) var dropoutCount = 0
    public private(set) var lastDropoutDate: Date?

    private let stats: UnsafeMutablePointer<RenderStats>
    private weak var engine: AVAudioEngine?
    private var observedUnit: AudioUnit?
    private var overloadListeners: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]
    private var timer: Timer?
    private var hideDropoutTask: Task<Void, Never>?

    private var tickCount = 0
    private var previousCycles: UInt64 = 0
    private var previousBusy: UInt64 = 0
    private var previousBudget: UInt64 = 0
    private var previousOverruns: UInt64 = 0
    private var secondBusy: UInt64 = 0
    private var secondBudget: UInt64 = 0
    private var secondPeak: Double = 0.0
    private var previousCPUTime: TimeInterval?
    private var previousCPUSampleDate = Date()

    public init() {
        testOffsetPercent = max(0, UserDefaults.standard.integer(forKey: Self.testOffsetDefaultsKey))
        stats = UnsafeMutablePointer<RenderStats>.allocate(capacity: 1)
        stats.initialize(to: RenderStats())
        stats.pointee.testLoadOffset = Double(testOffsetPercent) / 100.0
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        stats.pointee.ticksPerSecond = 1.0e9 * Double(timebase.denom) / Double(timebase.numer)
    }

    // The render thread may still hold the stats pointer while the engine
    // winds down, so it is never freed (one per app run).

    public func start(engine: AVAudioEngine) {
        self.engine = engine
        refreshAttachments()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        hideDropoutTask?.cancel()
        if let unit = observedUnit {
            AudioUnitRemoveRenderNotify(unit, renderNotify, stats)
            observedUnit = nil
        }
        for deviceID in Array(overloadListeners.keys) {
            removeOverloadListener(deviceID)
        }
    }

    // MARK: - Sampling (10 Hz)

    private func tick() {
        tickCount += 1
        // Every second: follow engine/device changes, process CPU, tooltip values.
        if tickCount % 10 == 0 {
            refreshAttachments()
            updateProcessCPU()
        }

        let cycles = stats.pointee.cycles
        let busy = stats.pointee.busyTicks
        let budget = stats.pointee.budgetTicks
        let overruns = stats.pointee.overruns
        let windowPeak = stats.pointee.peakLoad
        stats.pointee.peakLoad = 0.0

        if overruns != previousOverruns {
            previousOverruns = overruns
            noteDropout()
        }

        // No cycles: the engine is stopped (or still warming up).
        let target = cycles == previousCycles ? 0.0 : windowPeak
        secondBusy &+= busy &- previousBusy
        secondBudget &+= budget &- previousBudget
        secondPeak = max(secondPeak, target)
        previousCycles = cycles
        previousBusy = busy
        previousBudget = budget

        if tickCount % 10 == 0 {
            averageLoad = secondBudget == 0 ? 0.0 : Double(secondBusy) / Double(secondBudget)
            peakLoad = secondPeak
            secondBusy = 0
            secondBudget = 0
            secondPeak = 0.0
        }

        // Rises at once, falls back gradually.
        var shown = target >= load ? target : load * 0.75 + target * 0.25
        shown = (shown * 200).rounded() / 200
        if shown != load {
            load = shown
        }
    }

    private func updateProcessCPU() {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return }
        func seconds(_ time: timeval) -> TimeInterval {
            TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000
        }
        let cpuTime = seconds(usage.ru_utime) + seconds(usage.ru_stime)
        let now = Date()
        if let previous = previousCPUTime {
            let elapsed = now.timeIntervalSince(previousCPUSampleDate)
            let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
            if elapsed > 0 {
                processCPU = max(0, (cpuTime - previous) / elapsed / cores)
            }
        }
        previousCPUTime = cpuTime
        previousCPUSampleDate = now
    }

    // MARK: - Dropouts

    private func noteDropout() {
        let now = Date()
        // The same dropout often arrives from more than one source.
        if let last = lastDropoutDate, now.timeIntervalSince(last) < 0.3 {
            lastDropoutDate = now
        } else {
            dropoutCount += 1
            lastDropoutDate = now
        }
        isShowingDropout = true
        hideDropoutTask?.cancel()
        hideDropoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.dropoutDisplaySeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.isShowingDropout = false
        }
    }

    private func deviceReportedOverload() {
        // Starting or reconfiguring the device can report an overload.
        let sinceRestart = Double(mach_absolute_time() &- stats.pointee.restartTime) / stats.pointee.ticksPerSecond
        guard stats.pointee.restartTime != 0, sinceRestart > 1.0 else { return }
        noteDropout()
    }

    // MARK: - Attaching to the engine and devices

    /// Hooks the current output unit and devices; the engine's devices
    /// change when the audio settings are applied.
    private func refreshAttachments() {
        guard let engine else { return }
        let sampleRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        if sampleRate.isFinite, sampleRate > 0 {
            stats.pointee.sampleRate = sampleRate
        }

        let unit = engine.outputNode.audioUnit
        if unit != observedUnit {
            if let old = observedUnit {
                AudioUnitRemoveRenderNotify(old, renderNotify, stats)
            }
            observedUnit = nil
            if let unit, AudioUnitAddRenderNotify(unit, renderNotify, stats) == noErr {
                observedUnit = unit
            }
        }

        // With input in use the engine runs on one aggregate of the input
        // and output devices, so the output unit's device covers both.
        // (Touching `engine.inputNode` here would create an input node and
        // reconfigure an engine that has none.)
        let devices = Set([unit].compactMap { $0 }.compactMap(Self.currentDevice))
        for deviceID in Set(overloadListeners.keys).subtracting(devices) {
            removeOverloadListener(deviceID)
        }
        for deviceID in devices.subtracting(overloadListeners.keys) {
            addOverloadListener(deviceID)
        }
    }

    private static func currentDevice(of unit: AudioUnit) -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        )
        return status == noErr && deviceID != 0 ? deviceID : nil
    }

    private static var overloadAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDeviceProcessorOverload,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private func addOverloadListener(_ deviceID: AudioDeviceID) {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.deviceReportedOverload() }
        }
        var address = Self.overloadAddress
        if AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, listener) == noErr {
            overloadListeners[deviceID] = listener
        }
    }

    private func removeOverloadListener(_ deviceID: AudioDeviceID) {
        guard let listener = overloadListeners.removeValue(forKey: deviceID) else { return }
        var address = Self.overloadAddress
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, listener)
    }
}
