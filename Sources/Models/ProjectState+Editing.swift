import Foundation
import SwiftUI
import AppKit

/// A time range selected across adjacent tracks (in top-to-bottom order).
public struct TimeSelection: Equatable {
    public var start: Double
    public var end: Double
    public var trackIDs: [UUID]
}

/// One clip held on the clipboard, positioned relative to the copied block:
/// `timeOffset` from its earliest start, `trackOffset` from its top track.
public struct ClipboardClip {
    let fileURL: URL
    let sourceStartTime: Double
    let duration: Double
    let gainDB: Double
    let isMuted: Bool
    let fadeInDuration: Double
    let fadeOutDuration: Double
    let fadeInCurve: FadeCurve
    let fadeOutCurve: FadeCurve
    let timeOffset: Double
    let trackOffset: Int
}

// MARK: - Clip selection, time selection, clipboard and group moves

extension ProjectState {
    public var hasSelection: Bool {
        timeSelection != nil || tracks.contains { !$0.selectedClipIDs.isEmpty }
    }

    public var canPaste: Bool {
        !clipboard.isEmpty && !visibleTracks.isEmpty
    }

    /// Adds the clip to the selection, or removes it if already selected.
    public func toggleClipSelection(trackId: UUID, clipId: UUID) {
        guard let track = tracks.first(where: { $0.id == trackId }) else { return }
        timeSelection = nil
        if track.selectedClipIDs.contains(clipId) {
            track.selectedClipIDs.remove(clipId)
        } else {
            track.selectedClipIDs.insert(clipId)
        }
        selectedTrackId = trackId
    }

    public func selectAllClips() {
        timeSelection = nil
        for track in visibleTracks {
            track.selectedClipIDs = Set(track.clips.map(\.id))
        }
    }

    public func clearSelection() {
        timeSelection = nil
        for track in tracks where !track.selectedClipIDs.isEmpty {
            track.selectedClipIDs = []
        }
    }

    // MARK: Track geometry (in the "timelineScroll" coordinate space)

    /// Top of a row drawn in the arranger; below the last row when the row
    /// is not drawn.
    public func rowTopY(for rowID: UUID) -> CGFloat {
        var currentY: CGFloat = 0.0
        for row in visibleRows {
            if row.id == rowID {
                return currentY
            }
            currentY += rowHeight(row) + 1.0
        }
        return currentY
    }

    public func trackTopY(for trackID: UUID) -> CGFloat {
        rowTopY(for: trackID)
    }

    /// The track drawn at `y`; nil over a folder's row or outside every row.
    public func trackID(atTimelineY y: CGFloat) -> UUID? {
        var currentY: CGFloat = 0.0
        for row in visibleRows {
            let height = rowHeight(row)
            if y >= currentY && y < currentY + height {
                return row.track?.id
            }
            currentY += height + 1.0
        }
        return nil
    }

    /// Index in `visibleTracks` of the track drawn nearest to `y`.
    private func trackIndex(nearestTimelineY y: CGFloat) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        var trackIndex = 0
        var currentY: CGFloat = 0.0
        for row in visibleRows {
            let height = rowHeight(row)
            if row.track != nil {
                let distance = y < currentY ? currentY - y : max(0.0, y - (currentY + height))
                if best == nil || distance < best!.distance {
                    best = (trackIndex, distance)
                }
                trackIndex += 1
            }
            currentY += height + 1.0
        }
        return best?.index
    }

    // MARK: Marquee (rubber-band) clip selection

    /// Starts a rubber-band selection. With `additive` the clips already
    /// selected stay selected.
    public func beginMarquee(at point: CGPoint, additive: Bool) {
        timeSelection = nil
        marqueeBaseSelection = additive
            ? tracks.reduce(into: [:]) { $0[$1.id] = $1.selectedClipIDs }
            : [:]
        if let id = trackID(atTimelineY: point.y) {
            selectedTrackId = id
        }
        marqueeRect = CGRect(origin: point, size: .zero)
    }

    /// Selects every clip the rectangle between the two points touches.
    public func updateMarquee(from start: CGPoint, to current: CGPoint) {
        let rect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
        marqueeRect = rect
        let startTime = Double(rect.minX / pixelsPerSecond)
        let endTime = Double(rect.maxX / pixelsPerSecond)
        for track in visibleTracks {
            let top = trackTopY(for: track.id)
            let bottom = top + TrackHeaderView.rowHeight(for: track) * trackHeightScale
            var selected = marqueeBaseSelection[track.id] ?? []
            if rect.minY < bottom && rect.maxY > top {
                for clip in track.clips
                    where clip.startTime < endTime && clip.startTime + clip.duration > startTime {
                    selected.insert(clip.id)
                }
            }
            if track.selectedClipIDs != selected {
                track.selectedClipIDs = selected
            }
        }
    }

    public func endMarquee() {
        marqueeRect = nil
        marqueeBaseSelection = [:]
    }

    // MARK: Time selection

    public func beginTimeSelection(atTime time: Double, timelineY: CGFloat) {
        guard let index = trackIndex(nearestTimelineY: timelineY) else { return }
        for track in tracks where !track.selectedClipIDs.isEmpty {
            track.selectedClipIDs = []
        }
        timeSelectionAnchor = (snappedTimelineTime(time), index)
        timeSelection = nil
        selectedTrackId = visibleTracks[index].id
    }

    public func updateTimeSelection(toTime time: Double, timelineY: CGFloat) {
        guard let anchor = timeSelectionAnchor,
              let index = trackIndex(nearestTimelineY: timelineY) else { return }
        let current = snappedTimelineTime(time)
        let start = min(anchor.time, current)
        let end = max(anchor.time, current)
        let lanes = visibleTracks
        guard lanes.indices.contains(anchor.trackIndex), lanes.indices.contains(index) else { return }
        let trackRange = min(anchor.trackIndex, index)...max(anchor.trackIndex, index)
        timeSelection = end - start >= 0.01
            ? TimeSelection(start: start, end: end, trackIDs: trackRange.map { lanes[$0].id })
            : nil
    }

    public func endTimeSelection() {
        timeSelectionAnchor = nil
    }

    private var selectedRangeTracks: [AudioTrack] {
        guard let selection = timeSelection else { return [] }
        return tracks.filter { selection.trackIDs.contains($0.id) }
    }

    /// Runs `edit` on every track in the time selection as one undo step.
    private func editTimeSelection(_ edit: (AudioTrack, TimeSelection) -> Void) {
        guard !audioEngine.isRecording, let selection = timeSelection else { return }
        beginClipEdit()
        for track in selectedRangeTracks {
            edit(track, selection)
        }
        endClipEdit()
        audioEngine.syncAfterClipEdit(tracks, fxChannels: fxChannels)
    }

    /// Removes the audio inside the selected range (leaving silence).
    public func deleteTimeSelection() {
        editTimeSelection { track, selection in
            track.removeAudio(from: selection.start, to: selection.end)
        }
    }

    /// Keeps only the audio inside the selected range on its tracks.
    public func cropToTimeSelection() {
        editTimeSelection { track, selection in
            track.cropAudio(from: selection.start, to: selection.end)
        }
    }

    /// Splits clips at both edges of the selected range.
    public func splitAtTimeSelection() {
        editTimeSelection { track, selection in
            track.splitAudio(at: [selection.start, selection.end])
        }
    }

    // MARK: Selected clips

    public func deleteSelectedClips() {
        guard !audioEngine.isRecording, hasSelection else { return }
        beginClipEdit()
        for track in tracks {
            for id in track.selectedClipIDs {
                track.deleteClip(id: id, removeFile: false)
            }
        }
        endClipEdit()
        audioEngine.syncAfterClipEdit(tracks, fxChannels: fxChannels)
    }

    // MARK: Clipboard

    /// Copies the selected range, or else the selected clips.
    public func copySelection() {
        var copied: [(trackIndex: Int, clip: AudioClip)] = []
        let origin: Double
        let lanes = visibleTracks
        if let selection = timeSelection {
            for track in selectedRangeTracks {
                guard let index = lanes.firstIndex(where: { $0.id == track.id }) else { continue }
                copied += track.clipPieces(from: selection.start, to: selection.end).map { (index, $0) }
            }
            origin = selection.start
        } else {
            for (index, track) in lanes.enumerated() {
                copied += track.clips.filter { track.selectedClipIDs.contains($0.id) }.map { (index, $0) }
            }
            origin = copied.map(\.clip.startTime).min() ?? 0.0
        }
        guard let topIndex = copied.map(\.trackIndex).min() else { return }
        clipboard = copied.map { item in
            ClipboardClip(
                fileURL: item.clip.fileURL,
                sourceStartTime: item.clip.sourceStartTime,
                duration: item.clip.duration,
                gainDB: item.clip.gainDB,
                isMuted: item.clip.isMuted,
                fadeInDuration: item.clip.fadeInDuration,
                fadeOutDuration: item.clip.fadeOutDuration,
                fadeInCurve: item.clip.fadeInCurve,
                fadeOutCurve: item.clip.fadeOutCurve,
                timeOffset: item.clip.startTime - origin,
                trackOffset: item.trackIndex - topIndex
            )
        }
    }

    public func cutSelection() {
        guard !audioEngine.isRecording else { return }
        copySelection()
        deleteSelectedClip()
    }

    /// Index in `lanes` of the track a paste starts on: the current track, or
    /// when that is hidden in a closed folder, the first track shown below it.
    private func pasteBaseIndex(in lanes: [AudioTrack]) -> Int {
        if let index = lanes.firstIndex(where: { $0.id == selectedTrackId }) {
            return index
        }
        guard let currentRow = rows.firstIndex(where: { $0.id == selectedTrackId }) else { return 0 }
        let below = Set(rows[currentRow...].compactMap { $0.track?.id })
        return lanes.firstIndex(where: { below.contains($0.id) }) ?? max(0, lanes.count - 1)
    }

    /// Pastes at the playhead, with the copied block's top track landing on
    /// the selected track. Tracks below the last one are folded onto it.
    public func paste() {
        guard !audioEngine.isRecording, canPaste else { return }
        let lanes = visibleTracks
        let baseIndex = pasteBaseIndex(in: lanes)
        let pasteTime = audioEngine.currentTime
        beginClipEdit()
        clearSelection()
        for item in clipboard {
            let track = lanes[min(lanes.count - 1, baseIndex + item.trackOffset)]
            let startTime = pasteTime + item.timeOffset
            let clip = AudioClip(startTime: startTime, fileURL: item.fileURL)
            clip.loadMetadata()
            clip.setTrim(startTime: startTime, sourceStartTime: item.sourceStartTime, duration: item.duration)
            clip.setGainDB(item.gainDB)
            clip.isMuted = item.isMuted
            clip.setFadeInDuration(item.fadeInDuration)
            clip.setFadeOutDuration(item.fadeOutDuration)
            clip.fadeInCurve = item.fadeInCurve
            clip.fadeOutCurve = item.fadeOutCurve
            track.restoreClip(clip)
            track.selectedClipIDs.insert(clip.id)
        }
        endClipEdit()
        audioEngine.syncAfterClipEdit(tracks, fxChannels: fxChannels)
    }

    // MARK: Clip commands (right-click menu)

    /// The clips a menu opened on `clipId` acts on: the whole selection when
    /// that clip is part of it, otherwise just that clip.
    public func menuTargets(trackId: UUID, clipId: UUID) -> [(track: AudioTrack, clip: AudioClip)] {
        guard let track = tracks.first(where: { $0.id == trackId }),
              let clip = track.clips.first(where: { $0.id == clipId }) else { return [] }
        guard track.selectedClipIDs.contains(clipId) else { return [(track, clip)] }
        return tracks.flatMap { track in
            track.clips.filter { track.selectedClipIDs.contains($0.id) }.map { (track, $0) }
        }
    }

    /// Right-click on a clip: selects it, unless it is already selected (then
    /// the menu acts on the whole selection).
    public func selectForMenu(trackId: UUID, clipId: UUID) {
        guard let track = tracks.first(where: { $0.id == trackId }),
              !track.selectedClipIDs.contains(clipId) else { return }
        selectClip(trackId: trackId, clipId: clipId)
    }

    /// The menu targets the playhead is inside, i.e. those Split cuts.
    public func splittableMenuTargets(trackId: UUID, clipId: UUID) -> [(track: AudioTrack, clip: AudioClip)] {
        let time = audioEngine.currentTime
        return menuTargets(trackId: trackId, clipId: clipId).filter { target in
            let offset = time - target.clip.startTime
            return offset > 0.02 && offset < target.clip.duration - 0.02
        }
    }

    private func menuTargetClips(trackId: UUID, clipId: UUID) -> [AudioClip] {
        selectForMenu(trackId: trackId, clipId: clipId)
        return menuTargets(trackId: trackId, clipId: clipId).map(\.clip)
    }

    /// Runs `edit` on each target clip whose file exists, as one undo step.
    private func editMenuTargets(trackId: UUID, clipId: UUID, _ edit: (AudioClip) -> Void) {
        guard !audioEngine.isRecording else { return }
        let targets = menuTargetClips(trackId: trackId, clipId: clipId)
        beginClipEdit()
        for clip in targets where !clip.isFileMissing {
            edit(clip)
        }
        endClipEdit()
        audioEngine.syncAfterClipEdit(tracks, fxChannels: fxChannels)
    }

    /// Mutes every target clip, or unmutes them all when all are muted.
    public func toggleMuteMenuTargets(trackId: UUID, clipId: UUID) {
        guard !audioEngine.isRecording else { return }
        let targets = menuTargetClips(trackId: trackId, clipId: clipId)
        let mute = targets.contains { !$0.isMuted }
        for clip in targets where clip.isMuted != mute {
            clip.isMuted = mute
            audioEngine.setClipMuted(clip.id, muted: mute)
        }
    }

    /// Copies the target clips as one block whose start lands on the
    /// playhead, each on its own track; the copies become the selection.
    public func duplicateMenuTargets(trackId: UUID, clipId: UUID) {
        guard !audioEngine.isRecording else { return }
        selectForMenu(trackId: trackId, clipId: clipId)
        let targets = menuTargets(trackId: trackId, clipId: clipId)
        guard let blockStart = targets.map(\.clip.startTime).min() else { return }
        let offset = audioEngine.currentTime - blockStart
        beginClipEdit()
        clearSelection()
        for (track, clip) in targets {
            let copy = clip.duplicate(at: clip.startTime + offset)
            track.restoreClip(copy)
            track.selectedClipIDs.insert(copy.id)
        }
        endClipEdit()
        audioEngine.syncAfterClipEdit(tracks, fxChannels: fxChannels)
    }

    /// Splits the target clips at the playhead (those it is inside); both
    /// halves stay selected.
    public func splitMenuTargets(trackId: UUID, clipId: UUID) {
        guard !audioEngine.isPlaying && !audioEngine.isRecording else { return }
        selectForMenu(trackId: trackId, clipId: clipId)
        let targets = splittableMenuTargets(trackId: trackId, clipId: clipId)
        guard !targets.isEmpty else { return }
        let time = audioEngine.currentTime
        let selectedBefore = tracks.reduce(into: [UUID: Set<UUID>]()) { $0[$1.id] = $1.selectedClipIDs }
        let clipIDsBefore = Set(tracks.flatMap { $0.clips.map(\.id) })
        beginClipEdit()
        for (track, clip) in targets {
            _ = track.splitClip(id: clip.id, at: time)
        }
        for track in tracks {
            let newPieces = track.clips.map(\.id).filter { !clipIDsBefore.contains($0) }
            track.selectedClipIDs = (selectedBefore[track.id] ?? []).union(newPieces)
        }
        endClipEdit()
        audioEngine.syncAfterClipEdit(tracks, fxChannels: fxChannels)
    }

    /// Deletes the target clips (their files stay on disk) as one undo step.
    public func deleteMenuTargets(trackId: UUID, clipId: UUID) {
        guard !audioEngine.isRecording else { return }
        selectForMenu(trackId: trackId, clipId: clipId)
        let targets = menuTargets(trackId: trackId, clipId: clipId)
        beginClipEdit()
        for (track, clip) in targets {
            track.deleteClip(id: clip.id, removeFile: false)
        }
        endClipEdit()
        audioEngine.syncAfterClipEdit(tracks, fxChannels: fxChannels)
    }

    /// Sets each clip's gain so its loudest sample reaches 0 dBFS (within the
    /// ±24 dB clip gain range). The audio file is not changed.
    public func normalizeClips(trackId: UUID, clipId: UUID) {
        editMenuTargets(trackId: trackId, clipId: clipId) { clip in
            do {
                // Measure the whole recording, including parts hidden by trimming.
                let peak = try ClipAudioProcessing.peakAmplitude(
                    of: clip.fileURL,
                    sourceStartTime: 0.0,
                    duration: max(clip.originalDuration, clip.sourceStartTime + clip.duration)
                )
                guard peak > 0 else { return }
                clip.setGainDB(-20.0 * log10(Double(peak)))
            } catch {
                print("Failed to normalize \(clip.fileURL.lastPathComponent): \(error)")
            }
        }
    }

    /// Replaces each clip's audio with a reversed copy written next to the
    /// recordings. Fades swap ends with the audio. The original file is left
    /// in place, so Undo simply points the clip back at it.
    public func reverseClips(trackId: UUID, clipId: UUID) {
        editMenuTargets(trackId: trackId, clipId: clipId) { clip in
            let trackName = tracks.first { $0.clips.contains { $0 === clip } }?.name ?? ""
            let destination = RecordingFileName.nextURL(
                in: audioEngine.recordingsDirectory,
                stem: "Reverse_" + RecordingFileName.cleanTrackName(trackName)
            )
            do {
                try FileManager.default.createDirectory(
                    at: audioEngine.recordingsDirectory,
                    withIntermediateDirectories: true
                )
                try ClipAudioProcessing.writeReversed(
                    from: clip.fileURL,
                    sourceStartTime: clip.sourceStartTime,
                    duration: clip.duration,
                    to: destination
                )
            } catch {
                print("Failed to reverse \(clip.fileURL.lastPathComponent): \(error)")
                return
            }
            let fadeIn = (clip.fadeInDuration, clip.fadeInCurve)
            let fadeOut = (clip.fadeOutDuration, clip.fadeOutCurve)
            clip.setTrim(startTime: clip.startTime, sourceStartTime: 0.0, duration: clip.duration)
            clip.replaceFile(with: destination)
            clip.setFadeInDuration(fadeOut.0)
            clip.fadeInCurve = fadeOut.1
            clip.setFadeOutDuration(fadeIn.0)
            clip.fadeOutCurve = fadeIn.1
        }
    }

    /// Removes runs of silence (every sample at or below the chosen level, as
    /// in the parts of a stem the other DAW never recorded) of at least the
    /// chosen length: each clip is split around them, the silent pieces are
    /// dropped and the new edges get a short fade. The audio files are not
    /// changed.
    public func stripSilenceClips(trackId: UUID, clipId: UUID) {
        guard !audioEngine.isRecording else { return }
        selectForMenu(trackId: trackId, clipId: clipId)
        let targets = menuTargets(trackId: trackId, clipId: clipId).filter { !$0.clip.isFileMissing }
        guard !targets.isEmpty, let settings = askStripSilenceSettings() else { return }
        beginClipEdit()
        for (track, clip) in targets {
            let silences: [Range<Double>]
            do {
                silences = try ClipAudioProcessing.silenceRanges(
                    of: clip.fileURL,
                    sourceStartTime: clip.sourceStartTime,
                    duration: clip.duration,
                    thresholdDB: settings.thresholdDB,
                    minimumDuration: settings.minimumDuration
                )
            } catch {
                print("Failed to strip silence from \(clip.fileURL.lastPathComponent): \(error)")
                continue
            }
            guard !silences.isEmpty else { continue }
            // The fades lie outside the detected sound, reaching into the
            // silence. Each silence is at least the minimum length, so at most
            // half of it on each side keeps neighbouring pieces apart.
            let fade = min(settings.fadeDuration, settings.minimumDuration / 2)
            let clipEnd = clip.startTime + clip.duration
            // The sound between the silences (in seconds from the clip start),
            // then widened by the fade on edges that border a silence.
            var soundRanges: [(start: Double, end: Double)] = []
            var soundStart = 0.0
            for silence in silences {
                if silence.lowerBound > soundStart { soundRanges.append((soundStart, silence.lowerBound)) }
                soundStart = silence.upperBound
            }
            if soundStart < clip.duration { soundRanges.append((soundStart, clip.duration)) }
            let keptRanges = soundRanges.map { range in
                (start: range.start > 0 ? clip.startTime + max(0, range.start - fade) : clip.startTime,
                 end: range.end < clip.duration ? min(clipEnd, clip.startTime + range.end + fade) : clipEnd)
            }
            let pieces = keptRanges.compactMap { range -> AudioClip? in
                guard let piece = clip.piece(from: range.start, to: range.end) else { return nil }
                // Edges shared with the original clip keep its fades.
                let pieceFade = min(fade, piece.duration / 2)
                if range.start > clip.startTime { piece.setFadeInDuration(pieceFade) }
                if range.end < clipEnd { piece.setFadeOutDuration(pieceFade) }
                return piece
            }
            track.replaceClip(id: clip.id, with: pieces)
            track.selectedClipIDs.formUnion(pieces.map(\.id))
        }
        endClipEdit()
        audioEngine.syncAfterClipEdit(tracks, fxChannels: fxChannels)
    }

    private static let stripSilenceThresholdKey = "MyDAW.stripSilenceThresholdDB"
    private static let stripSilenceMinimumKey = "MyDAW.stripSilenceMinimumDuration"
    private static let stripSilenceFadeKey = "MyDAW.stripSilenceFadeMilliseconds"

    /// Asks for the silence level (dBFS), the shortest silence to remove
    /// (seconds) and the fade length (ms); the last values are remembered.
    /// Nil when cancelled.
    private func askStripSilenceSettings() -> (thresholdDB: Double, minimumDuration: Double, fadeDuration: Double)? {
        let defaults = UserDefaults.standard
        let thresholdField = NSTextField(string: Self.formatSetting(
            defaults.object(forKey: Self.stripSilenceThresholdKey) as? Double ?? -72.0))
        let minimumField = NSTextField(string: Self.formatSetting(
            defaults.object(forKey: Self.stripSilenceMinimumKey) as? Double ?? 1.0))
        let fadeField = NSTextField(string: Self.formatSetting(
            defaults.object(forKey: Self.stripSilenceFadeKey) as? Double ?? 10.0))
        for field in [thresholdField, minimumField, fadeField] {
            field.alignment = .right
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 80).isActive = true
            field.heightAnchor.constraint(equalToConstant: 22).isActive = true
        }
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: String(localized: "Silence level:")), thresholdField,
             NSTextField(labelWithString: String(localized: "dB or lower"))],
            [NSTextField(labelWithString: String(localized: "Minimum silence length:")), minimumField,
             NSTextField(labelWithString: String(localized: "seconds"))],
            [NSTextField(labelWithString: String(localized: "Fade in/out:")), fadeField,
             NSTextField(labelWithString: String(localized: "ms"))]
        ])
        grid.column(at: 0).xPlacement = .trailing
        // Without these the rows stretch unevenly and the fields differ in height.
        grid.yPlacement = .center
        grid.rowAlignment = .none
        grid.rowSpacing = 8
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)

        let alert = NSAlert()
        alert.messageText = String(localized: "Strip Silence")
        alert.informativeText = String(localized: "Removes parts where every sample stays at or below the silence level for at least the given length, such as the unrecorded parts of stems from another DAW. The clips are split there and the silent pieces are deleted.")
        alert.accessoryView = grid
        alert.addButton(withTitle: String(localized: "Strip Silence"))
        let cancelButton = alert.addButton(withTitle: String(localized: "Cancel"))
        cancelButton.keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = thresholdField

        while alert.runModal() == .alertFirstButtonReturn {
            let parse = { (field: NSTextField) in
                Double(field.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
            }
            guard let thresholdDB = parse(thresholdField), thresholdDB >= -144, thresholdDB <= 0,
                  let minimum = parse(minimumField), minimum.isFinite, minimum >= 0.01,
                  let fadeMilliseconds = parse(fadeField), fadeMilliseconds.isFinite,
                  fadeMilliseconds >= 0, fadeMilliseconds <= 10_000 else {
                NSSound.beep()
                continue
            }
            defaults.set(thresholdDB, forKey: Self.stripSilenceThresholdKey)
            defaults.set(minimum, forKey: Self.stripSilenceMinimumKey)
            defaults.set(fadeMilliseconds, forKey: Self.stripSilenceFadeKey)
            return (thresholdDB, minimum, fadeMilliseconds / 1000.0)
        }
        return nil
    }

    private static func formatSetting(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    // MARK: Group move (dragging one of several selected clips)

    /// Remembers where every selected clip starts so they can move together.
    public func beginGroupDrag() {
        groupDragStarts = [:]
        for track in tracks {
            for clip in track.clips where track.selectedClipIDs.contains(clip.id) {
                groupDragStarts[clip.id] = clip.startTime
            }
        }
    }

    /// Option-drag: leaves a copy of every selected clip at its current place,
    /// just below the original, while the originals go on being dragged.
    public func duplicateSelectedClipsInPlace() {
        for track in tracks {
            for clip in track.clips where track.selectedClipIDs.contains(clip.id) {
                track.insertClip(clip.duplicate(at: clip.startTime), below: clip.id)
            }
        }
    }

    /// Shifts every selected clip by `delta` seconds from where the drag began,
    /// limited so none moves before zero.
    public func updateGroupDrag(delta: Double) {
        let earliest = groupDragStarts.values.min() ?? 0.0
        let clampedDelta = max(-earliest, delta)
        for track in tracks {
            for clip in track.clips {
                if let start = groupDragStarts[clip.id] {
                    clip.startTime = start + clampedDelta
                }
            }
        }
    }

    /// True when every selected clip has a track `trackDelta` tracks away.
    func canMoveSelectedClips(trackDelta: Int) -> Bool {
        let lanes = visibleTracks
        return lanes.indices.allSatisfy { index in
            lanes[index].selectedClipIDs.isEmpty || lanes.indices.contains(index + trackDelta)
        }
    }

    /// The clips layered in `track`'s lane, in layer order. While clips are
    /// dragged to another track they already count there (on top, where they
    /// will land) and no longer in the track they came from.
    public func layeringClips(for track: AudioTrack) -> [AudioClip] {
        guard let preview = clipDragPreview, preview.trackDelta != 0 else { return track.clips }
        let lanes = visibleTracks
        guard let index = lanes.firstIndex(where: { $0 === track }) else { return track.clips }
        var clips = track.clips.filter { !preview.clipIDs.contains($0.id) }
        let sourceIndex = index - preview.trackDelta
        if lanes.indices.contains(sourceIndex) {
            clips += lanes[sourceIndex].clips.filter { preview.clipIDs.contains($0.id) }
        }
        return clips
    }

    /// Moves the selected clips `trackDelta` tracks down (up when negative),
    /// provided every one of them has a track to land on.
    public func endGroupDrag(trackDelta: Int) {
        defer { groupDragStarts = [:] }
        guard trackDelta != 0, canMoveSelectedClips(trackDelta: trackDelta) else { return }
        var moves: [(clipID: UUID, from: AudioTrack, to: AudioTrack)] = []
        let lanes = visibleTracks
        for (index, track) in lanes.enumerated() {
            for id in track.selectedClipIDs {
                let destination = index + trackDelta
                guard lanes.indices.contains(destination) else { return }
                moves.append((id, track, lanes[destination]))
            }
        }
        for move in moves {
            guard let clip = move.from.removeClipForTransfer(id: move.clipID) else { continue }
            move.to.restoreClip(clip)
            move.to.selectedClipIDs.insert(clip.id)
        }
        if let destination = moves.first?.to {
            selectedTrackId = destination.id
        }
    }
}
