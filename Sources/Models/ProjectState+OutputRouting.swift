import Foundation

// MARK: - Buses and where each channel's output goes

/// Every channel sends its output to MASTER or into another channel's fader.
/// A bus is a mixer channel of kind `.bus`, with no clips of its own. An
/// instrument output channel can also go to its own instrument track's fader.
/// Destinations never form a loop.
extension ProjectState {
    public var buses: [AudioTrack] {
        tracks.filter { $0.kind == .bus }
    }

    /// Routing changes need the engine stopped for a moment, so not during transport.
    public var canChangeRouting: Bool {
        !audioEngine.isPlaying && !audioEngine.isRecording
    }

    public func addBus() {
        guard canChangeRouting else { return }
        let number = buses.count + 1
        let bus = AudioTrack(
            kind: .bus,
            name: String(localized: "Bus \(number)"),
            color: defaultColors[(number - 1) % defaultColors.count]
        )
        rows.append(.track(bus))
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    /// Asks first: it cannot be undone. Channels going to it go to MASTER.
    public func confirmDeleteBus(id: UUID) {
        guard canChangeRouting, let bus = tracks.first(where: { $0.id == id && $0.kind == .bus }),
              confirmDeletion(
                  name: bus.name,
                  detail: String(localized: "The bus's plug-ins and sends will be removed, and channels going to it will go to MASTER. This cannot be undone.")
              ) else { return }
        deleteTrack(id: id)
    }

    /// What `track` can send to: buses, and for an instrument output its own
    /// instrument track; never itself or anything that comes back to it.
    public func outputDestinations(for track: AudioTrack) -> [AudioTrack] {
        var choices = buses
        if let parent = tracks.first(where: { $0.id == track.parentTrackID }) {
            choices.insert(parent, at: 0)
        }
        return choices.filter { !reaches($0, track: track) }
    }

    /// Whether `start`'s output comes (through any channels) to `track`.
    private func reaches(_ start: AudioTrack, track: AudioTrack) -> Bool {
        var current: AudioTrack? = start
        var steps = 0
        while let channel = current, steps <= tracks.count {
            if channel.id == track.id { return true }
            current = channel.outputDestinationID.flatMap { id in tracks.first { $0.id == id } }
            steps += 1
        }
        return false
    }

    /// Nil: MASTER.
    public func setOutputDestination(_ destinationID: UUID?, for track: AudioTrack) {
        guard canChangeRouting, track.outputDestinationID != destinationID else { return }
        if let destinationID {
            guard outputDestinations(for: track).contains(where: { $0.id == destinationID }) else { return }
        }
        track.outputDestinationID = destinationID
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    /// Channels whose destination is gone go to MASTER.
    func resetMissingOutputDestinations() {
        let ids = Set(tracks.map(\.id))
        for track in tracks {
            if let destination = track.outputDestinationID, !ids.contains(destination) {
                track.outputDestinationID = nil
            }
        }
    }
}
