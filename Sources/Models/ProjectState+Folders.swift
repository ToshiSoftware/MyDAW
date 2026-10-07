import Foundation
import SwiftUI

// MARK: - Track folders and the order of the track list

extension ProjectState {
    public var folders: [TrackFolder] {
        rows.compactMap(\.folder)
    }

    public func folder(withID id: UUID?) -> TrackFolder? {
        guard let id else { return nil }
        return folders.first { $0.id == id }
    }

    public func tracks(in folder: TrackFolder) -> [AudioTrack] {
        tracks.filter { $0.folderID == folder.id }
    }

    /// The rows drawn in the arranger: all but the tracks of closed folders,
    /// which are not drawn at all.
    public var visibleRows: [ArrangerRow] {
        let closed = Set(folders.filter { !$0.isOpen }.map(\.id))
        guard !closed.isEmpty else { return rows }
        return rows.filter { row in
            guard let folderID = row.track?.folderID else { return true }
            return !closed.contains(folderID)
        }
    }

    /// The tracks shown in the arranger, top to bottom. Editing that spans
    /// tracks (time selection, moving clips between tracks, pasting) works on
    /// these only.
    public var visibleTracks: [AudioTrack] {
        visibleRows.compactMap(\.track)
    }

    public func isTrackVisible(_ track: AudioTrack) -> Bool {
        folder(withID: track.folderID)?.isOpen ?? true
    }

    /// Height a row is drawn at.
    public func rowHeight(_ row: ArrangerRow) -> CGFloat {
        switch row {
        case .track(let track): return TrackHeaderView.rowHeight(for: track) * trackHeightScale
        case .folder: return TrackFolder.rowHeight
        }
    }

    // MARK: Keeping rows, tracks and folders in step

    /// Keeps `tracks` following `rows`, and takes out of its folder any track
    /// that is not in the folder's block (right below its header, among its
    /// other tracks), so a folder's tracks always stay together.
    func rowsDidChange() {
        var currentFolderID: UUID?
        for row in rows {
            switch row {
            case .folder(let folder):
                currentFolderID = folder.id
            case .track(let track):
                if let folderID = track.folderID, folderID == currentFolderID { continue }
                if track.folderID != nil { track.folderID = nil }
                currentFolderID = nil
            }
        }
        // Compared by object, not ID: reopening the same project brings new
        // track objects with the same IDs.
        let newTracks = rows.compactMap(\.track)
        if newTracks.count != tracks.count || zip(newTracks, tracks).contains(where: { $0 !== $1 }) {
            tracks = newTracks
        }
    }

    /// Sets each track's folder-held mute and solo from its folder's buttons.
    /// Returns true when any track's changed.
    @discardableResult
    func applyFolderStates() -> Bool {
        let foldersByID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        for track in tracks {
            let folder = track.folderID.flatMap { foldersByID[$0] }
            let muted = folder?.isMuted ?? false
            let soloed = folder?.isSoloed ?? false
            if track.isMutedByFolder != muted {
                track.isMutedByFolder = muted
                changed = true
            }
            if track.isSoloedByFolder != soloed {
                track.isSoloedByFolder = soloed
                changed = true
            }
        }
        return changed
    }

    /// After tracks have moved between folders: their folder's mute and solo
    /// now apply, and a track that went into a closed folder lets go of its
    /// selected clips, since edits never reach hidden tracks.
    private func folderMembershipDidChange() {
        if applyFolderStates() {
            updateMixerLevelsAfterTrackControlChange()
        }
        releaseSelection(ofHidden: tracks.filter { !isTrackVisible($0) })
    }

    private func releaseSelection(ofHidden hiddenTracks: [AudioTrack]) {
        for track in hiddenTracks where !track.selectedClipIDs.isEmpty {
            track.selectedClipIDs = []
        }
        if let selection = timeSelection,
           hiddenTracks.contains(where: { selection.trackIDs.contains($0.id) }) {
            timeSelection = nil
        }
    }

    /// Index right after the last track of `folder` (or after its header when
    /// it has none).
    private func endOfFolderIndex(_ folder: TrackFolder) -> Int {
        guard var index = rows.firstIndex(where: { $0.id == folder.id }) else { return rows.count }
        index += 1
        while index < rows.count, rows[index].track?.folderID == folder.id {
            index += 1
        }
        return index
    }

    // MARK: Adding and removing

    /// Where a new track goes: right below the current track, in its folder
    /// (at the folder's end when the folder is closed); at the end when there
    /// is no current track.
    func newTrackPlace() -> (index: Int, folder: TrackFolder?) {
        guard let current = tracks.first(where: { $0.id == selectedTrackId }),
              let index = rows.firstIndex(where: { $0.id == current.id }) else {
            return (rows.count, nil)
        }
        guard let folder = folder(withID: current.folderID) else { return (index + 1, nil) }
        return (folder.isOpen ? index + 1 : endOfFolderIndex(folder), folder)
    }

    /// Adds an empty folder right above the current track, or above the
    /// current track's folder when that track is in one (folders do not
    /// nest); at the end when there is no current track. The current track
    /// stays as it is.
    public func addFolder() {
        var index = rows.count
        if let current = tracks.first(where: { $0.id == selectedTrackId }) {
            let anchorID = current.folderID ?? current.id
            index = rows.firstIndex(where: { $0.id == anchorID }) ?? rows.count
        }
        insertNewFolder(at: index)
    }

    private func insertNewFolder(at index: Int) {
        let number = folders.count + 1
        let folder = TrackFolder(
            name: String(localized: "Folder \(number)"),
            color: defaultColors[(number - 1) % defaultColors.count]
        )
        rows.insert(.folder(folder), at: index)
    }

    /// From a header's right-click menu: adds a track right above the track
    /// `rowID` (in its folder, if any), or as the first track of the folder
    /// `rowID`.
    public func addTrack(above rowID: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        switch rows[index] {
        case .track(let track):
            insertNewTrack(at: (index, folder(withID: track.folderID)))
        case .folder(let folder):
            insertNewTrack(at: (index + 1, folder))
        }
    }

    // MARK: Duplicating

    /// Tracks and folders cannot be duplicated while their plug-ins could
    /// not be built (like inserting a plug-in).
    public var canDuplicateRows: Bool {
        !audioEngine.isPlaying && !audioEngine.isRecording
    }

    /// From a track header's right-click menu: adds a copy of the track right
    /// below it, in the same folder, and makes it current. The copy has the
    /// same settings, clips, plug-ins (with their state) and sends.
    public func duplicateTrack(id: UUID) {
        guard canDuplicateRows,
              let index = rows.firstIndex(where: { $0.id == id }),
              let track = rows[index].track else { return }
        var takenNames = Set(tracks.map(\.name))
        let copy = makeCopy(of: track, takenNames: &takenNames, folderID: track.folderID)
        rows.insert(.track(copy), at: index + 1)
        applyFolderStates()
        selectedTrackId = copy.id
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    /// From a folder header's right-click menu: adds a copy of the folder
    /// and its tracks right after the folder's last track. Names follow the
    /// same rule as for a track.
    public func duplicateFolder(id: UUID) {
        guard canDuplicateRows, let folder = folder(withID: id) else { return }
        let folderCopy = TrackFolder(
            name: Self.duplicateName(of: folder.name, taken: Set(folders.map(\.name))),
            color: folder.color,
            isOpen: folder.isOpen,
            isMuted: folder.isMuted,
            isSoloed: folder.isSoloed
        )
        var takenNames = Set(tracks.map(\.name))
        let trackCopies = tracks(in: folder).map { makeCopy(of: $0, takenNames: &takenNames, folderID: folderCopy.id) }
        rows.insert(contentsOf: [.folder(folderCopy)] + trackCopies.map { .track($0) }, at: endOfFolderIndex(folder))
        applyFolderStates()
        audioEngine.syncTracks(tracks, fxChannels: fxChannels)
    }

    private func makeCopy(of track: AudioTrack, takenNames: inout Set<String>, folderID: UUID?) -> AudioTrack {
        let name = Self.duplicateName(of: track.name, taken: takenNames)
        takenNames.insert(name)
        var pluginCopies: [UUID: UUID] = [:]
        let plugins = track.plugins.map { plugin -> TrackPluginDescriptor in
            let copy = plugin.newInstance()
            pluginCopies[plugin.id] = copy.id
            return copy
        }
        let copy = AudioTrack(
            name: name,
            channelMode: track.channelMode,
            inputChannelIndex: track.inputChannelIndex,
            isRecordArmed: track.isRecordArmed,
            isMuted: track.isMuted,
            isSoloed: track.isSoloed,
            isInputMonitoring: track.isInputMonitoring,
            volume: track.volume,
            pan: track.pan,
            trackHeight: track.trackHeight,
            color: track.color,
            plugins: plugins,
            fxSends: track.fxSends.map { FXSend(fxChannelID: $0.fxChannelID, level: $0.level, enabled: $0.enabled) }
        )
        copy.folderID = folderID
        copy.replaceClips(track.clips.map { $0.duplicate(at: $0.startTime) })
        audioEngine.copyPluginStates(pluginCopies)
        return copy
    }

    /// "Guitar" → "Guitar 2", "Guitar 2" → "Guitar 3", going on to the next
    /// number no other name in `taken` has.
    static func duplicateName(of name: String, taken: Set<String>) -> String {
        var base = name
        var number = 2
        if let space = name.lastIndex(of: " "),
           case let digits = name[name.index(after: space)...],
           !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
           let value = Int(digits), value < 1_000_000 {
            base = String(name[..<space])
            number = value + 1
        }
        while taken.contains("\(base) \(number)") {
            number += 1
        }
        return "\(base) \(number)"
    }

    /// From a header's right-click menu: adds an empty folder right above the
    /// track or folder `rowID`. Not for a track inside a folder, since
    /// folders do not nest.
    public func addFolder(above rowID: UUID) {
        guard let index = rows.firstIndex(where: { $0.id == rowID }),
              rows[index].track?.folderID == nil else { return }
        insertNewFolder(at: index)
    }

    /// Asks before removing a folder, saying that its tracks stay.
    public func confirmDeleteFolder(id: UUID) {
        guard let folder = folder(withID: id),
              confirmDeletion(
                  name: folder.name,
                  detail: String(localized: "The tracks in the folder are not deleted. They stay where they are, out of the folder.")
              ) else { return }
        deleteFolder(id: id)
    }

    /// Removes a folder; its tracks stay where they are, out of any folder.
    public func deleteFolder(id: UUID) {
        guard let folder = folder(withID: id) else { return }
        for track in tracks(in: folder) {
            track.folderID = nil
        }
        rows.removeAll { $0.id == id }
        folderMembershipDidChange()
    }

    // MARK: Folder buttons

    public func toggleFolderOpen(_ folder: TrackFolder) {
        // The arranger draws from this object, not from the folder.
        objectWillChange.send()
        folder.isOpen.toggle()
        if !folder.isOpen {
            releaseSelection(ofHidden: tracks(in: folder))
        }
    }

    /// Holds every track in the folder muted, whatever their own M; turning
    /// it off brings their own state back. Does nothing on an empty folder.
    public func toggleMute(for folder: TrackFolder) {
        guard !tracks(in: folder).isEmpty else { return }
        folder.isMuted.toggle()
        applyFolderStates()
        updateMixerLevelsAfterTrackControlChange()
    }

    /// Holds every track in the folder soloed, like `toggleMute(for:)`.
    public func toggleSolo(for folder: TrackFolder) {
        guard !tracks(in: folder).isEmpty else { return }
        folder.isSoloed.toggle()
        applyFolderStates()
        updateMixerLevelsAfterTrackControlChange()
    }

    // MARK: Reordering

    /// Moves a track to just before the row `beforeRowID` (to the end when
    /// nil), inside `folderID` or out of any folder. A place outside that
    /// folder's block leaves the track out of any folder. The audio graph is
    /// keyed by track, not by position, so nothing needs to be rewired.
    public func moveTrack(id: UUID, beforeRowID: UUID?, folderID: UUID?) {
        guard let track = tracks.first(where: { $0.id == id }), beforeRowID != id else { return }
        var newRows = rows
        newRows.removeAll { $0.id == id }
        let index = beforeRowID.flatMap { rowID in newRows.firstIndex { $0.id == rowID } } ?? newRows.count
        newRows.insert(.track(track), at: index)
        guard newRows.map(\.id) != rows.map(\.id) || track.folderID != folderID else { return }
        track.folderID = folder(withID: folderID)?.id
        rows = newRows
        // A time selection spans adjacent tracks, which these may no longer be.
        timeSelection = nil
        folderMembershipDidChange()
    }

    /// Moves a folder together with its tracks to just before the row
    /// `beforeRowID` (to the end when nil). That row must not be inside
    /// another folder, since folders do not nest.
    public func moveFolder(id: UUID, beforeRowID: UUID?) {
        guard let start = rows.firstIndex(where: { $0.id == id }),
              let folder = rows[start].folder else { return }
        let end = endOfFolderIndex(folder)
        let block = Array(rows[start..<end])
        guard !block.contains(where: { $0.id == beforeRowID }) else { return }
        var newRows = rows
        newRows.removeSubrange(start..<end)
        let index = beforeRowID.flatMap { rowID in newRows.firstIndex { $0.id == rowID } } ?? newRows.count
        if index < newRows.count, newRows[index].track?.folderID != nil { return }
        newRows.insert(contentsOf: block, at: index)
        guard newRows.map(\.id) != rows.map(\.id) else { return }
        rows = newRows
        timeSelection = nil
    }
}
