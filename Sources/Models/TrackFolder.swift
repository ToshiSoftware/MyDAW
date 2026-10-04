import Foundation
import SwiftUI

/// A folder in the track list: a header row that groups the tracks right
/// below it. Folders are one level deep and carry no audio of their own; their
/// M / S hold every track inside muted or soloed on top of the tracks' own
/// buttons (see `AudioTrack.isMutedByFolder`).
@MainActor
public final class TrackFolder: Identifiable, ObservableObject {
    public let id: UUID
    @Published public var name: String
    @Published public var color: Color
    /// Closed folders hide their tracks, which are then not drawn at all.
    @Published public internal(set) var isOpen: Bool
    @Published public internal(set) var isMuted: Bool
    @Published public internal(set) var isSoloed: Bool

    /// Height of a folder's row, just enough for its buttons. Not scaled by
    /// the track height zoom.
    public nonisolated static let rowHeight: CGFloat = 28.0

    public init(
        id: UUID = UUID(),
        name: String,
        color: Color,
        isOpen: Bool = true,
        isMuted: Bool = false,
        isSoloed: Bool = false
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.isOpen = isOpen
        self.isMuted = isMuted
        self.isSoloed = isSoloed
    }
}

/// One row of the track list: a track or a folder's header.
public enum ArrangerRow: Identifiable {
    case track(AudioTrack)
    case folder(TrackFolder)

    public var id: UUID {
        switch self {
        case .track(let track): return track.id
        case .folder(let folder): return folder.id
        }
    }

    public var track: AudioTrack? {
        if case .track(let track) = self { return track }
        return nil
    }

    public var folder: TrackFolder? {
        if case .folder(let folder) = self { return folder }
        return nil
    }
}

/// Widths of the arranger's header column.
public enum ArrangerLayout {
    /// Width of a track or folder header.
    public static let headerWidth: CGFloat = 230.0
    /// How far a track inside a folder is moved right: about the width of
    /// the folder's open / close button.
    public static let folderIndent: CGFloat = 18.0
    /// The header column always leaves room for the indent, so the timeline
    /// keeps its width whether or not there are folders.
    public static let headerColumnWidth: CGFloat = headerWidth + folderIndent
}
