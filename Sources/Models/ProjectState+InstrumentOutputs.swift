import Foundation

// MARK: - Instrument outputs (para-out)

/// An instrument's output bus can have its own channel: a track of kind
/// `.instrumentOutput` that the mixer shows right after its instrument track
/// and the arranger does not show. It has what any channel has (fader, pan,
/// inserts, sends, meter, output destination). Everything else about it is the parent's: its
/// notes, and being muted or soloed along with it.
extension ProjectState {
    public func instrumentOutputs(of parent: AudioTrack) -> [AudioTrack] {
        tracks.filter { $0.parentTrackID == parent.id }
    }

    /// Hides or shows the track's output channels in the mixer; they keep
    /// sounding. A hidden channel stops being the current one or in the group.
    public func toggleOutputChannelsHidden(of parent: AudioTrack) {
        parent.areOutputChannelsHidden.toggle()
        if parent.areOutputChannelsHidden {
            let hidden = Set(instrumentOutputs(of: parent).map(\.id))
            if let current = selectedTrackId, hidden.contains(current) { selectedTrackId = parent.id }
            mixerGroupTrackIDs.subtract(hidden)
        }
        // The mixer's list of strips depends on it.
        objectWillChange.send()
    }

    /// Gives the bus its own channel, or takes it away (the bus's sound goes
    /// wherever the instrument sends it then: for a drum kit, back to the mix).
    public func setInstrumentOutput(_ bus: InstrumentOutputBus, isOn: Bool, of parent: AudioTrack) {
        guard canChangeInstrument, parent.kind == .instrument else { return }
        if isOn {
            addInstrumentOutputs([bus], of: parent)
        } else {
            rows.removeAll { $0.track?.parentTrackID == parent.id && $0.track?.outputBus == bus.index }
            selectParentIfCurrentChannelIsGone(parent)
        }
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    public func setAllInstrumentOutputs(isOn: Bool, of parent: AudioTrack) {
        guard canChangeInstrument, parent.kind == .instrument else { return }
        if isOn {
            addInstrumentOutputs(audioEngine.instrumentOutputBuses(of: parent.id), of: parent)
        } else {
            rows.removeAll { $0.track?.parentTrackID == parent.id }
            selectParentIfCurrentChannelIsGone(parent)
        }
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    private func selectParentIfCurrentChannelIsGone(_ parent: AudioTrack) {
        if !tracks.contains(where: { $0.id == selectedTrackId }) { selectedTrackId = parent.id }
    }

    private func addInstrumentOutputs(_ buses: [InstrumentOutputBus], of parent: AudioTrack) {
        var newRows = rows
        let taken = Set(instrumentOutputs(of: parent).map(\.outputBus))
        for bus in buses where !taken.contains(bus.index) {
            let channel = AudioTrack(
                kind: .instrumentOutput,
                name: bus.name,
                pan: bus.defaultPan,
                color: parent.color,
                parentTrackID: parent.id,
                outputBus: bus.index,
                // Through the instrument's own fader to wherever it goes.
                outputDestinationID: parent.id
            )
            channel.folderID = parent.folderID
            newRows.append(.track(channel))
        }
        rows = newRows
        applyFolderStates()
    }

    /// `rows` with each instrument output right after its instrument track,
    /// in bus order, in its folder; an output whose track is gone is dropped.
    /// Nil when they are in place already.
    func rowsWithInstrumentOutputsInPlace() -> [ArrangerRow]? {
        guard rows.contains(where: { $0.track?.kind == .instrumentOutput }) else { return nil }
        var outputs: [UUID: [AudioTrack]] = [:]
        var newRows: [ArrangerRow] = []
        for row in rows {
            if let track = row.track, track.kind == .instrumentOutput, let parent = track.parentTrackID {
                outputs[parent, default: []].append(track)
            } else {
                newRows.append(row)
            }
        }
        var index = 0
        while index < newRows.count {
            if let parent = newRows[index].track, let children = outputs[parent.id] {
                let sorted = children.sorted { $0.outputBus < $1.outputBus }
                for child in sorted where child.folderID != parent.folderID { child.folderID = parent.folderID }
                newRows.insert(contentsOf: sorted.map { .track($0) }, at: index + 1)
                index += sorted.count
            }
            index += 1
        }
        let same = newRows.count == rows.count && zip(newRows, rows).allSatisfy { $0.id == $1.id }
        return same ? nil : newRows
    }
}
