import Foundation

/// A MIDI clip on the clipboard, with its place relative to the copied
/// block's first clip and top track.
public struct MIDIClipboardClip {
    let lengthTicks: Int
    let contentOffsetTicks: Int
    let isMuted: Bool
    let notes: [MIDINote]
    let events: [MIDIChannelEvent]
    let tickOffset: Int
    let trackOffset: Int
}

// MARK: - MIDI clips in the arranger

extension ProjectState {
    /// Shortest MIDI clip a trim leaves: a sixteenth note.
    static let minimumMIDIClipTicks = MIDITiming.ticksPerBeat / 4

    var hasMIDISelection: Bool {
        tracks.contains { !$0.selectedMIDIClipIDs.isEmpty }
    }

    /// Timeline ticks of a time in seconds, on the beat grid while snapping.
    func snappedTick(seconds: Double) -> Int {
        MIDITiming.ticks(seconds: snappedTimelineTime(seconds), bpm: audioEngine.bpm)
    }

    // MARK: Selection

    /// Selects the clip alone (or adds it to / removes it from the
    /// selection with `toggle`), and makes its track current.
    public func selectMIDIClip(trackId: UUID, clipId: UUID, toggle: Bool = false) {
        timeSelection = nil
        for track in tracks {
            if toggle {
                if track.id == trackId {
                    if track.selectedMIDIClipIDs.contains(clipId) {
                        track.selectedMIDIClipIDs.remove(clipId)
                    } else {
                        track.selectedMIDIClipIDs.insert(clipId)
                    }
                }
            } else {
                track.selectedClipIDs = []
                track.selectedMIDIClipIDs = track.id == trackId ? [clipId] : []
            }
        }
        selectedTrackId = trackId
    }

    private var selectedMIDIClips: [(track: AudioTrack, clip: MIDIClip)] {
        tracks.flatMap { track in
            track.midiClips.filter { track.selectedMIDIClipIDs.contains($0.id) }.map { (track, $0) }
        }
    }

    // MARK: Dragging

    /// Starts moving the selected MIDI clips; with `copy` (Option-drag)
    /// copies stay where the clips were.
    public func beginMIDIClipDrag(copy: Bool) {
        beginClipEdit()
        midiDragStarts = Dictionary(selectedMIDIClips.map { ($0.clip.id, $0.clip.startTick) }, uniquingKeysWith: { first, _ in first })
        guard copy else { return }
        for (track, clip) in selectedMIDIClips {
            track.insertMIDIClip(clip.duplicate(at: clip.startTick), below: clip.id)
        }
    }

    /// Moves the selected clips `deltaTicks` from where the drag began; the
    /// earliest stops at the timeline's start.
    public func updateMIDIClipDrag(deltaTicks: Int) {
        let earliest = midiDragStarts.values.min() ?? 0
        let delta = max(-earliest, deltaTicks)
        for (_, clip) in selectedMIDIClips {
            if let start = midiDragStarts[clip.id] {
                clip.startTick = start + delta
            }
        }
    }

    /// Ends the drag, moving the clips `trackDelta` instrument tracks down
    /// (up when negative) when every one of them has one to land on.
    public func endMIDIClipDrag(trackDelta: Int) {
        defer {
            midiDragStarts = [:]
            endClipEdit()
            audioEngine.syncAfterClipEdit(tracks, fxChannels: fxChannels)
        }
        guard trackDelta != 0 else { return }
        let lanes = visibleTracks.filter { $0.kind == .instrument }
        var moves: [(clip: MIDIClip, from: AudioTrack, to: AudioTrack)] = []
        for (track, clip) in selectedMIDIClips {
            guard let index = lanes.firstIndex(where: { $0 === track }),
                  lanes.indices.contains(index + trackDelta) else { return }
            moves.append((clip, track, lanes[index + trackDelta]))
        }
        for move in moves {
            move.from.removeMIDIClip(id: move.clip.id)
            move.to.restoreMIDIClip(move.clip)
            move.to.selectedMIDIClipIDs.insert(move.clip.id)
        }
        if let destination = moves.first?.to {
            selectedTrackId = destination.id
        }
    }

    // MARK: Trimming

    /// Moves the clip's left edge to `tick`, keeping its notes in place.
    public func trimMIDIClipStart(_ clip: MIDIClip, to tick: Int) {
        let start = min(max(0, tick), clip.endTick - Self.minimumMIDIClipTicks)
        let delta = start - clip.startTick
        guard delta != 0 else { return }
        clip.contentOffsetTicks += delta
        clip.lengthTicks -= delta
        clip.startTick = start
    }

    /// Moves the clip's right edge to `tick`.
    public func trimMIDIClipEnd(_ clip: MIDIClip, to tick: Int) {
        clip.lengthTicks = max(Self.minimumMIDIClipTicks, tick - clip.startTick)
    }

    // MARK: Commands (right-click menu and keys)

    /// The clips a menu on `clipId` acts on: the selection when the clip is
    /// in it, else the clip alone (which is then selected).
    private func midiMenuTargets(trackId: UUID, clipId: UUID) -> [(track: AudioTrack, clip: MIDIClip)] {
        guard let track = tracks.first(where: { $0.id == trackId }) else { return [] }
        if !track.selectedMIDIClipIDs.contains(clipId) {
            selectMIDIClip(trackId: trackId, clipId: clipId)
        }
        return selectedMIDIClips
    }

    public func toggleMuteMIDIClips(trackId: UUID, clipId: UUID) {
        let targets = midiMenuTargets(trackId: trackId, clipId: clipId)
        guard !targets.isEmpty else { return }
        beginClipEdit()
        // All muted → unmute all; otherwise mute all.
        let mute = !targets.allSatisfy { $0.clip.isMuted }
        for (_, clip) in targets {
            clip.isMuted = mute
        }
        endClipEdit()
        audioEngine.syncAfterClipEdit(tracks, fxChannels: fxChannels)
    }

    /// Copies the clips to the playhead (the block's first clip starting
    /// there, as for audio clips); the copies become the selection.
    public func duplicateMIDIClips(trackId: UUID, clipId: UUID) {
        let targets = midiMenuTargets(trackId: trackId, clipId: clipId)
        guard let blockStart = targets.map(\.clip.startTick).min() else { return }
        let offset = MIDITiming.ticks(seconds: audioEngine.currentTime, bpm: audioEngine.bpm) - blockStart
        beginClipEdit()
        clearSelection()
        for (track, clip) in targets {
            let copy = clip.duplicate(at: max(0, clip.startTick + offset))
            track.restoreMIDIClip(copy)
            track.selectedMIDIClipIDs.insert(copy.id)
        }
        endClipEdit()
        audioEngine.syncAfterClipEdit(tracks, fxChannels: fxChannels)
    }

    /// Splits the clips the playhead crosses at the playhead.
    public func splitMIDIClips(trackId: UUID, clipId: UUID) {
        let targets = midiMenuTargets(trackId: trackId, clipId: clipId)
        splitMIDIClips(targets, at: MIDITiming.ticks(seconds: audioEngine.currentTime, bpm: audioEngine.bpm))
    }

    /// Splits the selected MIDI clips at the playhead.
    public func splitSelectedMIDIClips() {
        splitMIDIClips(selectedMIDIClips, at: MIDITiming.ticks(seconds: audioEngine.currentTime, bpm: audioEngine.bpm))
    }

    private func splitMIDIClips(_ targets: [(track: AudioTrack, clip: MIDIClip)], at tick: Int) {
        guard canChangeInstrument else { return }
        let splittable = targets.filter {
            tick - $0.clip.startTick >= Self.minimumMIDIClipTicks && $0.clip.endTick - tick >= Self.minimumMIDIClipTicks
        }
        guard !splittable.isEmpty else { return }
        beginClipEdit()
        for (track, clip) in splittable {
            let right = clip.duplicate(at: tick)
            right.contentOffsetTicks = clip.contentOffsetTicks + (tick - clip.startTick)
            right.lengthTicks = clip.endTick - tick
            clip.lengthTicks = tick - clip.startTick
            track.insertMIDIClip(right, above: clip.id)
            track.selectedMIDIClipIDs = [right.id]
        }
        endClipEdit()
        audioEngine.syncAfterClipEdit(tracks, fxChannels: fxChannels)
    }

    /// True when some track has two or more MIDI clips selected.
    public var canMergeMIDIClips: Bool {
        tracks.contains { $0.selectedMIDIClipIDs.count >= 2 }
    }

    /// Joins the selected MIDI clips of each track into one clip, from the
    /// first one's start to the last one's end. It holds what the clips play:
    /// trimmed-off notes are left out, notes cut at a clip's end keep that
    /// length, and the notes of a muted clip become muted notes.
    public func mergeSelectedMIDIClips() {
        guard !audioEngine.isRecording, canMergeMIDIClips else { return }
        beginClipEdit()
        for track in tracks where track.selectedMIDIClipIDs.count >= 2 {
            let clips = track.midiClips.filter { track.selectedMIDIClipIDs.contains($0.id) }
            guard let start = clips.map(\.startTick).min(),
                  let end = clips.map(\.endTick).max() else { continue }
            var notes: [MIDINote] = []
            var events: [MIDIChannelEvent] = []
            for clip in clips {
                for note in clip.audibleNotes {
                    let on = clip.timelineTick(ofContentTick: note.startTick)
                    let off = min(clip.timelineTick(ofContentTick: note.endTick), clip.endTick)
                    var merged = note
                    merged.startTick = on - start
                    merged.lengthTicks = max(1, off - on)
                    merged.isMuted = note.isMuted || clip.isMuted
                    notes.append(merged)
                }
                let visible = clip.contentOffsetTicks..<(clip.contentOffsetTicks + clip.lengthTicks)
                // A muted clip's controller moves are not heard; they are dropped.
                for event in clip.events where !clip.isMuted && visible.contains(event.tick) {
                    var merged = event
                    merged.tick = clip.timelineTick(ofContentTick: event.tick) - start
                    events.append(merged)
                }
            }
            notes.sort { ($0.startTick, $0.pitch) < ($1.startTick, $1.pitch) }
            events.sort { $0.tick < $1.tick }
            let merged = MIDIClip(startTick: start, lengthTicks: end - start, notes: notes, events: events)
            // The merged clip takes the place of the topmost of the clips.
            if let top = clips.last {
                track.insertMIDIClip(merged, above: top.id)
            }
            for clip in clips {
                track.removeMIDIClip(id: clip.id)
            }
            track.selectedMIDIClipIDs = [merged.id]
        }
        endClipEdit()
        audioEngine.syncAfterClipEdit(tracks, fxChannels: fxChannels)
    }

    public func deleteMIDIClips(trackId: UUID, clipId: UUID) {
        let targets = midiMenuTargets(trackId: trackId, clipId: clipId)
        guard !targets.isEmpty else { return }
        beginClipEdit()
        for (track, clip) in targets {
            track.removeMIDIClip(id: clip.id)
        }
        endClipEdit()
        audioEngine.syncAfterClipEdit(tracks, fxChannels: fxChannels)
    }

    /// Removes the selected MIDI clips (part of a clip edit already begun).
    func removeSelectedMIDIClips() {
        for (track, clip) in selectedMIDIClips {
            track.removeMIDIClip(id: clip.id)
        }
    }

    // MARK: Clipboard

    /// Puts the selected MIDI clips on the MIDI clipboard (emptied when none
    /// is selected, so a paste never brings back an older copy).
    func copySelectedMIDIClips() {
        let lanes = visibleTracks
        let copied = selectedMIDIClips.compactMap { item -> (index: Int, clip: MIDIClip)? in
            lanes.firstIndex(where: { $0 === item.track }).map { ($0, item.clip) }
        }
        let origin = copied.map(\.clip.startTick).min() ?? 0
        let topIndex = copied.map(\.index).min() ?? 0
        midiClipboard = copied.map { item in
            MIDIClipboardClip(
                lengthTicks: item.clip.lengthTicks,
                contentOffsetTicks: item.clip.contentOffsetTicks,
                isMuted: item.clip.isMuted,
                notes: item.clip.notes,
                events: item.clip.events,
                tickOffset: item.clip.startTick - origin,
                trackOffset: item.index - topIndex
            )
        }
    }

    /// Pastes the MIDI clipboard at the playhead, the block's top track on
    /// lane `baseIndex`; clips for an audio track are left out (part of a
    /// clip edit already begun).
    func pasteMIDIClipboard(lanes: [AudioTrack], baseIndex: Int) {
        guard !lanes.isEmpty else { return }
        let pasteTick = MIDITiming.ticks(seconds: audioEngine.currentTime, bpm: audioEngine.bpm)
        for item in midiClipboard {
            let track = lanes[min(lanes.count - 1, baseIndex + item.trackOffset)]
            guard track.kind == .instrument else { continue }
            let clip = MIDIClip(
                startTick: pasteTick + item.tickOffset,
                lengthTicks: item.lengthTicks,
                contentOffsetTicks: item.contentOffsetTicks,
                isMuted: item.isMuted,
                notes: item.notes,
                events: item.events
            )
            track.restoreMIDIClip(clip)
            track.selectedMIDIClipIDs.insert(clip.id)
        }
    }
}
