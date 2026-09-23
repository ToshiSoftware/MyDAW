import Foundation
import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers
import AVFoundation

@MainActor
public final class ProjectState: ObservableObject {
    private struct ClipSnapshot {
        let id: UUID
        let startTime: Double
        let sourceStartTime: Double
        let duration: Double
        let originalDuration: Double
        let gainDB: Double
        let fadeInDuration: Double
        let fadeOutDuration: Double
        let fileURL: URL
    }

    private struct ClipEditSnapshot {
        let clipsByTrack: [UUID: [ClipSnapshot]]
        let selectedClipIDs: [UUID: UUID?]
    }

    @Published public var tracks: [AudioTrack] = []
    @Published public var fxChannels: [FXChannel] = []
    @Published public var masterPlugins: [TrackPluginDescriptor] = []
    @Published public var selectedTrackId: UUID?
    @Published public var pixelsPerSecond: CGFloat = 80.0 // Horizontal zoom factor
    @Published public var timelineScrollTime: Double = 0.0
    @Published public private(set) var zoomRevision: Int = 0
    @Published public private(set) var scrollRestoreRevision: Int = 0
    @Published public var isRestoringScrollPosition: Bool = false
    @Published public var showsBeats: Bool = true
    @Published public var snapToGrid: Bool = UserDefaults.standard.object(forKey: "MyDAW.snapToGrid") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(snapToGrid, forKey: "MyDAW.snapToGrid")
        }
    }
    @Published public var pluginManager: PluginManager
    @Published public private(set) var startupLog: [String] = ["MyDAWを起動しています..."]
    @Published public private(set) var isShowingStartupLog = true
    @Published public var isShowingMasterExportDialog = false
    @Published public var isExportingMasterMix = false
    @Published public var masterExportCompleted = false
    @Published public var masterExportError: String?
    public var masterExportURL: URL?
    private var masterExportTask: Task<Void, Never>?
    @Published public private(set) var canUndo = false
    @Published public private(set) var canRedo = false
    @Published public var waveformVerticalScale: CGFloat = 1.0 {
        didSet {
            let clamped = min(32.0, max(1.0, waveformVerticalScale))
            if clamped != waveformVerticalScale {
                waveformVerticalScale = clamped
            }
        }
    }
    @Published public var trackHeightScale: CGFloat = 1.0 {
        didSet {
            let clamped = min(3.0, max(0.5, trackHeightScale))
            if clamped != trackHeightScale {
                trackHeightScale = clamped
            }
        }
    }

    public var currentProjectURL: URL?

    public var audioContentEndTime: Double {
        tracks
            .flatMap { $0.clips }
            .map { $0.startTime + $0.duration }
            .max() ?? 0.0
    }

    public let audioEngine: AudioEngineManager
    public let deviceManager: AudioDeviceManager

    private let defaultColors: [Color] = [
        Color(red: 0.20, green: 0.60, blue: 1.00), // Azure
        Color(red: 0.25, green: 0.85, blue: 0.60), // Emerald
        Color(red: 1.00, green: 0.65, blue: 0.15), // Amber
        Color(red: 0.90, green: 0.35, blue: 0.45), // Coral
        Color(red: 0.70, green: 0.45, blue: 0.95), // Purple
        Color(red: 0.35, green: 0.80, blue: 0.95), // Cyan
    ]
    private var undoStack: [ClipEditSnapshot] = []
    private var redoStack: [ClipEditSnapshot] = []
    private var activeClipEditSnapshot: ClipEditSnapshot?

    public init(audioEngine: AudioEngineManager? = nil, deviceManager: AudioDeviceManager? = nil, pluginManager: PluginManager? = nil) {
        self.audioEngine = audioEngine ?? AudioEngineManager()
        self.deviceManager = deviceManager ?? AudioDeviceManager()
        self.pluginManager = pluginManager ?? PluginManager()

        if self.audioEngine.applyAudioDevices(
            inputDeviceID: self.deviceManager.selectedInputDeviceID,
            outputDeviceID: self.deviceManager.selectedOutputDeviceID
        ) {
            self.deviceManager.persistSelectedDevices()
        }

        if audioEngine == nil {
            self.audioEngine.applyInputBufferFrameSize(self.deviceManager.bufferFrameSize)
        }

        setupPeakObserver()

        // Add 2 initial tracks as default template
        addTrack(name: "Audio 1", mode: .stereo, isArmed: true)
        addTrack(name: "Audio 2", mode: .stereo, isArmed: false)
        startPluginDiscovery()
    }

    private func startPluginDiscovery() {
        pluginManager.discoverAvailablePlugins(
            onLog: { [weak self] message in
                self?.startupLog.append(message)
            },
            completion: { [weak self] in
                self?.isShowingStartupLog = false
                DispatchQueue.main.async {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first(where: { $0.title.contains("MyDAW") })?
                        .makeKeyAndOrderFront(nil)
                }
            }
        )
    }

    private func makeClipEditSnapshot() -> ClipEditSnapshot {
        ClipEditSnapshot(
            clipsByTrack: tracks.reduce(into: [:]) { result, track in
                result[track.id] = track.clips.map { clip in
                    ClipSnapshot(
                        id: clip.id,
                        startTime: clip.startTime,
                        sourceStartTime: clip.sourceStartTime,
                        duration: clip.duration,
                        originalDuration: clip.originalDuration,
                        gainDB: clip.gainDB,
                        fadeInDuration: clip.fadeInDuration,
                        fadeOutDuration: clip.fadeOutDuration,
                        fileURL: clip.fileURL
                    )
                }
            },
            selectedClipIDs: tracks.reduce(into: [:]) { result, track in
                result[track.id] = track.selectedClipId
            }
        )
    }

    public func beginClipEdit() {
        guard activeClipEditSnapshot == nil else { return }
        activeClipEditSnapshot = makeClipEditSnapshot()
    }

    public func endClipEdit() {
        guard let snapshot = activeClipEditSnapshot else { return }
        activeClipEditSnapshot = nil
        undoStack.append(snapshot)
        redoStack.removeAll()
        updateHistoryAvailability()
    }

    private func recordClipEdit() {
        undoStack.append(makeClipEditSnapshot())
        redoStack.removeAll()
        updateHistoryAvailability()
    }

    private func updateHistoryAvailability() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func restoreClipEditSnapshot(_ snapshot: ClipEditSnapshot) {
        for track in tracks {
            let restoredClips = (snapshot.clipsByTrack[track.id] ?? []).map { item in
                let clip = AudioClip(id: item.id, startTime: item.startTime, fileURL: item.fileURL)
                clip.loadMetadata()
                clip.setTrim(
                    startTime: item.startTime,
                    sourceStartTime: item.sourceStartTime,
                    duration: item.duration
                )
                clip.setGainDB(item.gainDB)
                clip.setFadeInDuration(item.fadeInDuration)
                clip.setFadeOutDuration(item.fadeOutDuration)
                return clip
            }
            track.replaceClips(restoredClips)
            track.selectedClipId = snapshot.selectedClipIDs[track.id] ?? nil
        }
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    public func undo() {
        guard !audioEngine.isPlaying && !audioEngine.isRecording,
              let snapshot = undoStack.popLast() else { return }
        redoStack.append(makeClipEditSnapshot())
        restoreClipEditSnapshot(snapshot)
        updateHistoryAvailability()
    }

    public func redo() {
        guard !audioEngine.isPlaying && !audioEngine.isRecording,
              let snapshot = redoStack.popLast() else { return }
        undoStack.append(makeClipEditSnapshot())
        restoreClipEditSnapshot(snapshot)
        updateHistoryAvailability()
    }

    private func setupPeakObserver() {
        MyDAWNotificationCenter.shared.addObserver(
            forName: .audioEngineUpdatedPeaks,
            object: nil,
            queue: nil
        ) { [weak self] notif in
            Task { @MainActor [weak self] in
                guard let self = self,
                      let userInfo = notif.userInfo,
                      let peaks = userInfo["peaks"] as? [Float] else { return }

                let liveChannelWaveforms = userInfo["liveChannelWaveforms"] as? [UUID: [[(min: Float, max: Float)]]] ?? [:]
                let outputPeaks = userInfo["outputPeaks"] as? [UUID: Float] ?? [:]

                // Update track input peak meters
                for track in self.tracks {
                    if track.isRecordArmed {
                        let ch0 = track.inputChannelIndex
                        let ch1 = ch0 + 1
                        var rawPeak: Float = 0.0
                        if ch0 < peaks.count {
                            rawPeak = peaks[ch0]
                        }
                        if track.channelMode == .stereo && ch1 < peaks.count {
                            rawPeak = max(rawPeak, peaks[ch1])
                        }
                        // Fast attack, smooth decay
                        track.currentInputPeak = max(rawPeak, track.currentInputPeak * 0.85)
                    } else {
                        track.currentInputPeak = max(0.0, track.currentInputPeak * 0.70)
                    }
                    let outputPeak = outputPeaks[track.id] ?? 0.0
                    track.currentOutputPeak = max(outputPeak, track.currentOutputPeak * 0.82)

                    // Append live waveform points if recording
                    if let channelPoints = liveChannelWaveforms[track.id], !channelPoints.isEmpty {
                        track.appendLiveChannelPeaks(channelPoints)
                    }
                }
            }
        }
    }

    public func addTrack(name: String? = nil, mode: ChannelMode = .stereo, isArmed: Bool = false) {
        let index = tracks.count + 1
        let trackName = name ?? "Audio \(index)"
        let color = defaultColors[(index - 1) % defaultColors.count]

        let newTrack = AudioTrack(
            name: trackName,
            channelMode: mode,
            inputChannelIndex: 0,
            isRecordArmed: isArmed,
            color: color
        )
        tracks.append(newTrack)
        selectedTrackId = newTrack.id
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    public func importAudioFile(_ url: URL, intoTrackId trackId: UUID) {
        guard !audioEngine.isPlaying && !audioEngine.isRecording,
              let track = tracks.first(where: { $0.id == trackId }) else { return }

        do {
            let file = try AVAudioFile(forReading: url)
            let sampleRate = file.fileFormat.sampleRate
            let expectedSampleRate = audioEngine.hardwareSampleRate
            let bitDepth = (file.fileFormat.settings[AVLinearPCMBitDepthKey] as? NSNumber)?.intValue ?? 0
            var errors: [String] = []

            if abs(sampleRate - expectedSampleRate) > 0.5 {
                errors.append("サンプルレート: \(Int(sampleRate)) Hz（必要: \(Int(expectedSampleRate)) Hz）")
            }
            if bitDepth != 24 {
                errors.append("ビット深度: \(bitDepth > 0 ? "\(bitDepth)" : "不明") bit（必要: 24 bit）")
            }
            guard errors.isEmpty else {
                presentProjectError("WAVファイルを追加できません。\n\n" + errors.joined(separator: "\n"))
                return
            }

            let managedURL = try managedRecordingURL(for: url)
            let clip = track.addClip(startTime: audioEngine.currentTime, fileURL: managedURL)
            clip.loadMetadata()
            selectClip(trackId: trackId, clipId: clip.id)
            audioEngine.syncTracks(tracks, fxChannels: fxChannels)
        } catch {
            presentProjectError("WAVファイルを読み込めませんでした。\n\n\(error.localizedDescription)")
        }
    }

    public func beginMasterExportDialog() {
        guard !audioEngine.isPlaying && !audioEngine.isRecording else { return }
        let panel = NSSavePanel()
        panel.title = "Export Master Mix"
        panel.nameFieldStringValue = "MyDAW Master Mix.wav"
        panel.directoryURL = audioEngine.recordingsDirectory
        panel.allowedContentTypes = [.wav]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        masterExportURL = url
        masterExportCompleted = false
        masterExportError = nil
        isShowingMasterExportDialog = true
    }

    public func exportMasterMix(startTime: Double, endTime: Double) {
        guard !isExportingMasterMix, let url = masterExportURL else { return }
        isExportingMasterMix = true
        masterExportCompleted = false
        masterExportError = nil

        masterExportTask = Task { @MainActor in
            do {
                try await audioEngine.exportMasterMix(
                    to: url,
                    startTime: startTime,
                    endTime: endTime,
                    tracks: tracks,
                    fxChannels: fxChannels
                )
                isExportingMasterMix = false
                masterExportCompleted = true
            } catch {
                isExportingMasterMix = false
                if !Task.isCancelled {
                    masterExportError = error.localizedDescription
                }
            }
            masterExportTask = nil
        }
    }

    public func cancelMasterExport() {
        guard isExportingMasterMix else { return }
        masterExportTask?.cancel()
        isShowingMasterExportDialog = false
    }

    private func managedRecordingURL(for sourceURL: URL) throws -> URL {
        let recordingsURL = audioEngine.recordingsDirectory.standardizedFileURL
        let sourceStandardizedURL = sourceURL.standardizedFileURL
        let recordingsPath = recordingsURL.path.hasSuffix("/")
            ? recordingsURL.path
            : recordingsURL.path + "/"

        if sourceStandardizedURL.path.hasPrefix(recordingsPath) {
            return sourceStandardizedURL
        }

        try FileManager.default.createDirectory(
            at: recordingsURL,
            withIntermediateDirectories: true
        )

        let baseName = sourceURL.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: " ", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        let safeBaseName = baseName.isEmpty ? "Imported" : baseName
        let fileName = "Import_\(safeBaseName)_\(UUID().uuidString.prefix(8)).wav"
        let destinationURL = recordingsURL.appendingPathComponent(fileName)
        try FileManager.default.copyItem(at: sourceStandardizedURL, to: destinationURL)
        return destinationURL
    }

    public func insertPlugin(_ descriptor: TrackPluginDescriptor, into trackID: UUID) {
        guard !audioEngine.isPlaying && !audioEngine.isRecording else { return }
        guard let track = tracks.first(where: { $0.id == trackID }) else { return }
        track.insertPlugin(descriptor.newInstance())
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    public func removePlugin(_ pluginID: UUID, from trackID: UUID) {
        guard !audioEngine.isPlaying && !audioEngine.isRecording else { return }
        guard let track = tracks.first(where: { $0.id == trackID }) else { return }
        track.removePlugin(id: pluginID)
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    public func addFXChannel() {
        let channel = FXChannel(name: "FX \(fxChannels.count + 1)")
        fxChannels.append(channel)
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    public func removeFXChannel(id: UUID) {
        fxChannels.removeAll { $0.id == id }
        for track in tracks {
            track.fxSends.removeAll { $0.fxChannelID == id }
        }
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    public func setSend(trackID: UUID, fxChannelID: UUID, level: Float) {
        guard let track = tracks.first(where: { $0.id == trackID }) else { return }
        if let index = track.fxSends.firstIndex(where: { $0.fxChannelID == fxChannelID }) {
            track.fxSends[index].level = level
            track.fxSends[index].enabled = level > 0
        } else if level > 0 {
            track.fxSends.append(FXSend(fxChannelID: fxChannelID, level: level))
        }
        if audioEngine.isPlaying || audioEngine.isRecording,
           let send = track.fxSends.first(where: { $0.fxChannelID == fxChannelID }),
           let fxChannel = fxChannels.first(where: { $0.id == fxChannelID }) {
            let anySolo = tracks.contains { $0.isSoloed }
            audioEngine.updateSendLevel(
                track: track,
                send: send,
                fxChannel: fxChannel,
                anySolo: anySolo
            )
        } else {
            audioEngine.syncTracks(tracks, fxChannels: fxChannels)
        }
    }

    public func insertPlugin(_ descriptor: TrackPluginDescriptor, intoFX fxChannelID: UUID) {
        guard let channel = fxChannels.first(where: { $0.id == fxChannelID }) else { return }
        channel.insertPlugin(descriptor.newInstance())
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    public func removePlugin(_ pluginID: UUID, fromFX fxChannelID: UUID) {
        guard let channel = fxChannels.first(where: { $0.id == fxChannelID }) else { return }
        channel.removePlugin(id: pluginID)
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    public func insertMasterPlugin(_ descriptor: TrackPluginDescriptor) {
        masterPlugins.append(descriptor.newInstance())
        audioEngine.syncMasterPlugins(masterPlugins)
    }

    public func removeMasterPlugin(_ pluginID: UUID) {
        masterPlugins.removeAll { $0.id == pluginID }
        audioEngine.syncMasterPlugins(masterPlugins)
    }

    public func openPluginUI(_ pluginID: UUID, on trackID: UUID) {
        guard tracks.first(where: { $0.id == trackID })?.plugins.contains(where: { $0.id == pluginID }) == true else {
            return
        }
        audioEngine.openPluginUI(pluginID: pluginID)
    }

    public func deleteTrack(id: UUID) {
        tracks.removeAll { $0.id == id }
        if selectedTrackId == id {
            selectedTrackId = tracks.first?.id
        }
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    public func toggleRecordArm(for track: AudioTrack) {
        track.isRecordArmed.toggle()
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    public func toggleMute(for track: AudioTrack) {
        track.isMuted.toggle()
        updateMixerLevelsAfterTrackControlChange()
    }

    public func toggleSolo(for track: AudioTrack) {
        track.isSoloed.toggle()
        updateMixerLevelsAfterTrackControlChange()
    }

    private func updateMixerLevelsAfterTrackControlChange() {
        if audioEngine.isPlaying || audioEngine.isRecording {
            audioEngine.updateMixerLevels(tracks: tracks, fxChannels: fxChannels)
        } else {
            audioEngine.syncTracks(tracks, fxChannels: fxChannels)
        }
    }

    public func selectClip(trackId: UUID, clipId: UUID) {
        for track in tracks {
            track.selectedClipId = track.id == trackId ? clipId : nil
        }
        selectedTrackId = trackId
    }

    public func deleteSelectedClip() {
        guard !audioEngine.isRecording,
              let track = tracks.first(where: { $0.selectedClipId != nil }),
              let clipId = track.selectedClipId else { return }
          deleteClip(trackId: track.id, clipId: clipId)
    }

    public func deleteClip(trackId: UUID, clipId: UUID) {
        guard !audioEngine.isRecording,
              let track = tracks.first(where: { $0.id == trackId }) else { return }
        guard track.clips.contains(where: { $0.id == clipId }) else { return }
        recordClipEdit()
        track.deleteClip(id: clipId, removeFile: false)
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    public func duplicateClip(trackId: UUID, clipId: UUID) {
        guard !audioEngine.isRecording,
              let track = tracks.first(where: { $0.id == trackId }) else { return }
          guard track.clips.contains(where: { $0.id == clipId }) else { return }
          recordClipEdit()
        _ = track.duplicateClip(id: clipId)
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    public func splitSelectedClip() {
        guard !audioEngine.isPlaying && !audioEngine.isRecording,
              let track = tracks.first(where: { $0.selectedClipId != nil }),
              let clipId = track.selectedClipId else { return }
        splitClip(trackId: track.id, clipId: clipId)
    }

    public func splitClip(trackId: UUID, clipId: UUID) {
        guard !audioEngine.isPlaying && !audioEngine.isRecording,
              let track = tracks.first(where: { $0.id == trackId }) else { return }
        let beforeEdit = makeClipEditSnapshot()
        track.selectedClipId = clipId
        if track.splitClip(id: clipId, at: audioEngine.currentTime) {
            undoStack.append(beforeEdit)
            redoStack.removeAll()
            updateHistoryAvailability()
            audioEngine.syncTracks(tracks, fxChannels: fxChannels)
        }
    }

    @discardableResult
    public func saveProject() -> Bool {
        guard !audioEngine.isPlaying && !audioEngine.isRecording else { return false }
        let panel = NSSavePanel()
        panel.title = "Save MyDAW Project"
        let defaultName = currentProjectURL?.deletingPathExtension().lastPathComponent ?? "MyDAW Project"
        panel.nameFieldStringValue = defaultName
        panel.directoryURL = currentProjectURL?.deletingLastPathComponent()
        panel.allowedContentTypes = [UTType(filenameExtension: "mydaw") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return false }

        currentProjectURL = url

        let document = ProjectDocument(
            pixelsPerSecond: Double(pixelsPerSecond),
            selectedTrackId: selectedTrackId,
            currentTime: audioEngine.currentTime,
            timelineScrollTime: timelineScrollTime,
            showsBeats: showsBeats,
            bpm: audioEngine.bpm,
            metronomeEnabled: audioEngine.metronomeEnabled,
            metronomeTimingOffsetMs: audioEngine.metronomeTimingOffsetMs,
            metronomeVolume: audioEngine.metronomeVolume,
            masterVolume: audioEngine.masterVolume,
            manualRecordingCompensationMs: audioEngine.manualRecordingCompensationMs,
            waveformVerticalScale: Double(waveformVerticalScale),
            trackHeightScale: Double(trackHeightScale),
            tracks: tracks.map { track in
                TrackDocument(
                    id: track.id,
                    name: track.name,
                    channelMode: track.channelMode,
                    inputChannelIndex: track.inputChannelIndex,
                    isRecordArmed: track.isRecordArmed,
                    isMuted: track.isMuted,
                    isSoloed: track.isSoloed,
                    volume: track.volume,
                    pan: track.pan,
                    trackHeight: Double(track.trackHeight),
                    color: ColorDocument(color: track.color),
                    selectedClipId: track.selectedClipId,
                    clips: track.clips.map { clip in
                        ClipDocument(
                            id: clip.id,
                            startTime: clip.startTime,
                            sourceStartTime: clip.sourceStartTime,
                            duration: clip.duration,
                            originalDuration: clip.originalDuration,
                            gainDB: clip.gainDB,
                            fadeInDuration: clip.fadeInDuration,
                            fadeOutDuration: clip.fadeOutDuration,
                            filePath: clip.fileURL.path
                        )
                    },
                    plugins: track.plugins,
                    fxSends: track.fxSends
                )
            },
            fxChannels: fxChannels.map { FXChannelDocument(channel: $0) },
            masterPlugins: masterPlugins,
            pluginStates: audioEngine.capturePluginStates()
        )

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(document).write(to: url, options: .atomic)
            return true
        } catch {
            presentProjectError("Could not save project: \(error.localizedDescription)")
            return false
        }
    }

    public func loadProject() {
        guard !audioEngine.isPlaying && !audioEngine.isRecording else { return }
        let panel = NSOpenPanel()
        panel.title = "Open MyDAW Project"
        panel.allowedContentTypes = [UTType(filenameExtension: "mydaw") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let document = try JSONDecoder().decode(ProjectDocument.self, from: Data(contentsOf: url))
            var restoredPluginIDs = Set<UUID>()
            func uniquePluginInstances(_ plugins: [TrackPluginDescriptor]) -> [TrackPluginDescriptor] {
                plugins.map { plugin in
                    if restoredPluginIDs.insert(plugin.id).inserted {
                        return plugin
                    }
                    return plugin.newInstance()
                }
            }
            var restoredTracks: [AudioTrack] = []
            for trackDocument in document.tracks {
                let track = AudioTrack(
                    id: trackDocument.id,
                    name: trackDocument.name,
                    channelMode: trackDocument.channelMode,
                    inputChannelIndex: trackDocument.inputChannelIndex,
                    isRecordArmed: trackDocument.isRecordArmed,
                    isMuted: trackDocument.isMuted,
                    isSoloed: trackDocument.isSoloed,
                    volume: trackDocument.volume,
                    pan: trackDocument.pan,
                    trackHeight: CGFloat(trackDocument.trackHeight),
                    color: trackDocument.color.color,
                    plugins: uniquePluginInstances(trackDocument.plugins),
                    fxSends: trackDocument.fxSends
                )
                for clipDocument in trackDocument.clips {
                    let clipURL = URL(fileURLWithPath: clipDocument.filePath)
                    let clip = AudioClip(id: clipDocument.id, startTime: clipDocument.startTime, fileURL: clipURL)
                    track.restoreClip(clip)
                    clip.setTrim(
                        startTime: clipDocument.startTime,
                        sourceStartTime: clipDocument.sourceStartTime,
                        duration: clipDocument.duration
                    )
                    clip.setGainDB(clipDocument.gainDB)
                    clip.setFadeInDuration(clipDocument.fadeInDuration)
                    clip.setFadeOutDuration(clipDocument.fadeOutDuration)
                }
                track.selectedClipId = trackDocument.selectedClipId
                restoredTracks.append(track)
            }

            tracks = restoredTracks
            fxChannels = document.fxChannels.map {
                FXChannel(
                    id: $0.id,
                    name: $0.name,
                    volume: $0.volume,
                    pan: $0.pan,
                    plugins: uniquePluginInstances($0.plugins),
                    color: $0.color.color
                )
            }
            masterPlugins = uniquePluginInstances(document.masterPlugins)
            audioEngine.setSavedPluginStates(document.pluginStates)

            // Restore waveform data after the project model is visible. The
            // cache performs file analysis off the main thread. Start this
            // before AU restoration so a slow plug-in cannot delay waveform
            // reconstruction after loading a project.
            Task { @MainActor in
                for track in self.tracks {
                    for clip in track.clips {
                        clip.loadMetadata()
                    }
                }
            }
            selectedTrackId = document.selectedTrackId
            showsBeats = document.showsBeats
            pixelsPerSecond = CGFloat(document.pixelsPerSecond)
            audioEngine.currentTime = max(0.0, document.currentTime)
            isRestoringScrollPosition = true
            timelineScrollTime = max(0.0, document.timelineScrollTime)
            scrollRestoreRevision += 1
            audioEngine.bpm = document.bpm
            audioEngine.metronomeEnabled = document.metronomeEnabled
            audioEngine.metronomeTimingOffsetMs = document.metronomeTimingOffsetMs
            audioEngine.metronomeVolume = document.metronomeVolume
            audioEngine.masterVolume = document.masterVolume
            audioEngine.manualRecordingCompensationMs = document.manualRecordingCompensationMs
            waveformVerticalScale = CGFloat(min(32.0, max(1.0, document.waveformVerticalScale)))
            trackHeightScale = CGFloat(min(3.0, max(0.5, document.trackHeightScale)))
            currentProjectURL = url

            audioEngine.prepareForPluginGraphRestore()

            Task { @MainActor in
                await Task.yield()
                guard !self.audioEngine.isPlaying && !self.audioEngine.isRecording else { return }
                self.audioEngine.syncTracks(
                    self.tracks,
                    fxChannels: self.fxChannels,
                    masterPlugins: self.masterPlugins
                )
            }
        } catch {
            presentProjectError("Could not open project: \(error.localizedDescription)")
        }
    }

    private func presentProjectError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "MyDAW Project"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // Zoom helpers
    public func zoomIn() {
        setPixelsPerSecond(pixelsPerSecond * 1.25)
    }

    public func zoomOut() {
        setPixelsPerSecond(pixelsPerSecond / 1.25)
    }

    public func setPixelsPerSecond(_ newValue: CGFloat) {
        let clampedValue = min(max(newValue, 20.0), 400.0)
        guard clampedValue != pixelsPerSecond else { return }

        let cursorOffsetPixels = max(0.0, audioEngine.currentTime - timelineScrollTime) * Double(pixelsPerSecond)
        pixelsPerSecond = clampedValue
        zoomRevision += 1
        timelineScrollTime = max(
            0.0,
            audioEngine.currentTime - cursorOffsetPixels / Double(clampedValue)
        )
    }

    public func snappedTimelineTime(_ time: Double) -> Double {
        let clampedTime = max(0.0, time)
        guard snapToGrid else { return clampedTime }
        let beatDuration = 60.0 / max(20.0, min(400.0, audioEngine.bpm))
        guard beatDuration.isFinite, beatDuration > 0.0 else { return clampedTime }
        return max(0.0, (clampedTime / beatDuration).rounded() * beatDuration)
    }
}
