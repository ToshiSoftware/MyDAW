import Foundation
import AppKit

/// The values the other target channels had when a group edit began, so
/// each step applies the whole change so far to them: a channel that hits
/// a limit on the way keeps its offset when the control comes back.
struct MixerGroupEdit {
    enum Control: Equatable {
        case volume
        case pan
        case send(UUID)
    }

    let control: Control
    let trackID: UUID
    /// The operated channel's starting value.
    let base: Double
    /// The other target channels' starting values.
    let others: [UUID: Double]
}

extension ProjectState {
    // MARK: Mixer channel targets

    /// Whether the mixer channel is operated with the current track: the
    /// current track itself or one ⇧/⌘-clicked to it.
    public func isMixerTarget(_ trackID: UUID) -> Bool {
        trackID == selectedTrackId || mixerGroupTrackIDs.contains(trackID)
    }

    /// A click on a mixer channel. ⇧ or ⌘ adds the channel to (or takes it
    /// out of) the channels operated with the current track; a plain click
    /// makes it current and drops the others.
    public func clickMixerChannel(_ trackID: UUID) {
        let modifiers = NSEvent.modifierFlags
        guard modifiers.contains(.shift) || modifiers.contains(.command), let current = selectedTrackId else {
            selectedTrackId = trackID
            mixerGroupTrackIDs = []
            return
        }
        guard trackID != current else { return }
        if mixerGroupTrackIDs.contains(trackID) {
            mixerGroupTrackIDs.remove(trackID)
        } else {
            mixerGroupTrackIDs.insert(trackID)
        }
    }

    /// The tracks that follow an edit of `track`: the other targets when it
    /// is one of them, none otherwise.
    private func mixerFollowers(of track: AudioTrack) -> [AudioTrack] {
        guard isMixerTarget(track.id) else { return [] }
        return tracks.filter { $0.id != track.id && isMixerTarget($0.id) }
    }

    // MARK: Group edits

    /// Ends the drag of a mixer control; the next change starts afresh.
    public func endMixerGroupEdit() {
        mixerGroupEdit = nil
    }

    /// The edit in progress for this control on this track, started with
    /// the current values when there is none.
    private func groupEdit(
        _ control: MixerGroupEdit.Control,
        on track: AudioTrack,
        value: (AudioTrack) -> Double
    ) -> MixerGroupEdit {
        if let edit = mixerGroupEdit, edit.control == control, edit.trackID == track.id {
            return edit
        }
        let edit = MixerGroupEdit(
            control: control,
            trackID: track.id,
            base: value(track),
            others: Dictionary(uniqueKeysWithValues: mixerFollowers(of: track).map { ($0.id, value($0)) })
        )
        mixerGroupEdit = edit
        return edit
    }

    /// Fader level in dB, -∞ counted as the fader's floor so a change from
    /// or to the bottom stays finite.
    private static func groupDecibels(_ gain: Float) -> Double {
        max(MixerScale.floorDecibels, MixerScale.decibels(forGain: gain))
    }

    private static func groupGain(_ decibels: Double) -> Float {
        min(MixerGain.maximum, MixerScale.gain(forDecibels: decibels))
    }

    /// A follower's new level. One at -∞ stays there unless the operated
    /// channel started at -∞ too, so a channel that was off (a send above
    /// all) is not turned on at an inaudible level.
    private static func followerGain(base: Double, delta: Double, operatedBase: Double) -> Float? {
        if base <= MixerScale.floorDecibels && operatedBase > MixerScale.floorDecibels { return nil }
        return groupGain(base + delta)
    }

    /// Sets a track's fader; the other targets move by the same number of dB.
    public func setMixerVolume(_ gain: Float, for track: AudioTrack) {
        let edit = groupEdit(.volume, on: track) { Self.groupDecibels($0.volume) }
        track.volume = gain
        let delta = Self.groupDecibels(gain) - edit.base
        for other in tracks {
            guard let base = edit.others[other.id],
                  let gain = Self.followerGain(base: base, delta: delta, operatedBase: edit.base) else { continue }
            other.volume = gain
        }
        audioEngine.updateMixerLevels(tracks: tracks, fxChannels: fxChannels)
    }

    /// Sets a track's pan; the other targets move by the same amount.
    public func setMixerPan(_ pan: Float, for track: AudioTrack) {
        let edit = groupEdit(.pan, on: track) { Double($0.pan) }
        track.pan = pan
        let delta = Double(pan) - edit.base
        for other in tracks where edit.others[other.id] != nil {
            other.pan = Float(max(-1, min(1, edit.others[other.id]! + delta)))
        }
        audioEngine.updateMixerLevels(tracks: tracks, fxChannels: fxChannels)
    }

    /// Sets a track's send; the other targets' sends to the same FX channel
    /// move by the same number of dB.
    public func setMixerSend(_ level: Float, for track: AudioTrack, fxChannelID: UUID) {
        func sendLevel(_ track: AudioTrack) -> Float {
            track.fxSends.first(where: { $0.fxChannelID == fxChannelID })?.level ?? 0
        }
        let edit = groupEdit(.send(fxChannelID), on: track) { Self.groupDecibels(sendLevel($0)) }
        setSend(trackID: track.id, fxChannelID: fxChannelID, level: level)
        let delta = Self.groupDecibels(level) - edit.base
        for other in tracks {
            guard let base = edit.others[other.id],
                  let gain = Self.followerGain(base: base, delta: delta, operatedBase: edit.base) else { continue }
            setSend(trackID: other.id, fxChannelID: fxChannelID, level: gain)
        }
    }

    /// Toggles a track's M; the other targets take the same state.
    public func toggleMixerMute(for track: AudioTrack) {
        guard !track.isMutedByFolder else { return }
        track.isMuted.toggle()
        for other in mixerFollowers(of: track) where !other.isMutedByFolder {
            other.isMuted = track.isMuted
        }
        updateMixerLevelsAfterTrackControlChange()
    }

    /// Toggles a track's S; the other targets take the same state.
    public func toggleMixerSolo(for track: AudioTrack) {
        guard !track.isSoloedByFolder else { return }
        track.isSoloed.toggle()
        for other in mixerFollowers(of: track) where !other.isSoloedByFolder {
            other.isSoloed = track.isSoloed
        }
        updateMixerLevelsAfterTrackControlChange()
    }
}
