import Foundation
import SwiftUI

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
        !clipboard.isEmpty && !tracks.isEmpty
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
        for track in tracks {
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

    public func trackTopY(for trackID: UUID) -> CGFloat {
        var currentY: CGFloat = 0.0
        for candidate in tracks {
            if candidate.id == trackID {
                return currentY
            }
            currentY += TrackHeaderView.rowHeight(for: candidate) * trackHeightScale + 1.0
        }
        return currentY
    }

    public func trackID(atTimelineY y: CGFloat) -> UUID? {
        var currentY: CGFloat = 0.0
        for candidate in tracks {
            let height = TrackHeaderView.rowHeight(for: candidate) * trackHeightScale
            if y >= currentY && y < currentY + height {
                return candidate.id
            }
            currentY += height + 1.0
        }
        return nil
    }

    /// Like `trackID(atTimelineY:)`, but above the first track gives the first
    /// and below the last gives the last.
    private func trackIndex(nearestTimelineY y: CGFloat) -> Int? {
        guard !tracks.isEmpty else { return nil }
        if let id = trackID(atTimelineY: y),
           let index = tracks.firstIndex(where: { $0.id == id }) {
            return index
        }
        return y < 0 ? 0 : tracks.count - 1
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
        for track in tracks {
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
        selectedTrackId = tracks[index].id
    }

    public func updateTimeSelection(toTime time: Double, timelineY: CGFloat) {
        guard let anchor = timeSelectionAnchor,
              let index = trackIndex(nearestTimelineY: timelineY) else { return }
        let current = snappedTimelineTime(time)
        let start = min(anchor.time, current)
        let end = max(anchor.time, current)
        let trackRange = min(anchor.trackIndex, index)...max(anchor.trackIndex, index)
        timeSelection = end - start >= 0.01
            ? TimeSelection(start: start, end: end, trackIDs: trackRange.map { tracks[$0].id })
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
        if let selection = timeSelection {
            for track in selectedRangeTracks {
                guard let index = tracks.firstIndex(where: { $0.id == track.id }) else { continue }
                copied += track.clipPieces(from: selection.start, to: selection.end).map { (index, $0) }
            }
            origin = selection.start
        } else {
            for (index, track) in tracks.enumerated() {
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

    /// Pastes at the playhead, with the copied block's top track landing on
    /// the selected track. Tracks below the last one are folded onto it.
    public func paste() {
        guard !audioEngine.isRecording, canPaste else { return }
        let baseIndex = tracks.firstIndex(where: { $0.id == selectedTrackId }) ?? 0
        let pasteTime = audioEngine.currentTime
        beginClipEdit()
        clearSelection()
        for item in clipboard {
            let track = tracks[min(tracks.count - 1, baseIndex + item.trackOffset)]
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

    /// The clips a menu command on `clipId` acts on: the whole selection when
    /// that clip is part of it, otherwise just that clip (which gets selected).
    private func menuTargetClips(trackId: UUID, clipId: UUID) -> [AudioClip] {
        guard let track = tracks.first(where: { $0.id == trackId }) else { return [] }
        if !track.selectedClipIDs.contains(clipId) {
            selectClip(trackId: trackId, clipId: clipId)
        }
        return tracks.flatMap { track in
            track.clips.filter { track.selectedClipIDs.contains($0.id) }
        }
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

    /// Moves the selected clips `trackDelta` tracks down (up when negative),
    /// provided every one of them has a track to land on.
    public func endGroupDrag(trackDelta: Int) {
        defer { groupDragStarts = [:] }
        guard trackDelta != 0 else { return }
        var moves: [(clipID: UUID, from: AudioTrack, to: AudioTrack)] = []
        for (index, track) in tracks.enumerated() {
            for id in track.selectedClipIDs {
                let destination = index + trackDelta
                guard tracks.indices.contains(destination) else { return }
                moves.append((id, track, tracks[destination]))
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
