import SwiftUI

/// A folder's row in the track list: open / close button, colour, name, and
/// M / S for every track inside. Its height is fixed. Clicking it does not
/// make it the current track; dragging it (in `ArrangerView`) moves it with
/// its tracks.
public struct FolderHeaderView: View {
    @ObservedObject public var folder: TrackFolder
    @ObservedObject public var projectState: ProjectState

    @State private var isShowingColorPalette = false
    @State private var isEditingName = false

    public init(folder: TrackFolder, projectState: ProjectState) {
        self.folder = folder
        self.projectState = projectState
    }

    public var body: some View {
        let isEmpty = projectState.tracks(in: folder).isEmpty
        HStack(spacing: 0) {
            Rectangle()
                .fill(folder.color)
                .frame(width: 6)
                .contentShape(Rectangle())
                .onTapGesture { isShowingColorPalette = true }
                .help("Change folder color")
                .popover(isPresented: $isShowingColorPalette, arrowEdge: .trailing) {
                    TrackColorPalette(color: $folder.color) {
                        isShowingColorPalette = false
                    }
                }

            Button(action: {
                projectState.toggleFolderOpen(folder)
            }) {
                Image(systemName: folder.isOpen ? "arrowtriangle.down.fill" : "arrowtriangle.right.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.75))
                    .frame(width: ArrangerLayout.folderIndent, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .help(folder.isOpen ? "Close Folder" : "Open Folder")

            HStack(spacing: 5) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                    .foregroundColor(folder.color)

                if isEditingName {
                    TextField("Folder Name", text: $folder.name, onCommit: {
                        isEditingName = false
                    })
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 4)
                    .background(Color.black.opacity(0.3))
                    .cornerRadius(3)
                } else {
                    Text(folder.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .onTapGesture(count: 2) {
                            isEditingName = true
                        }
                }

                Spacer(minLength: 4)

                Button(action: {
                    projectState.toggleMute(for: folder)
                }) {
                    HeaderToggleLabel(title: "M", isOn: folder.isMuted, color: .cyan)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isEmpty)
                .opacity(isEmpty ? 0.4 : 1.0)
                .help("Mute every track in the folder")

                Button(action: {
                    projectState.toggleSolo(for: folder)
                }) {
                    HeaderToggleLabel(title: "S", isOn: folder.isSoloed, color: .yellow)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isEmpty)
                .opacity(isEmpty ? 0.4 : 1.0)
                .help("Solo every track in the folder")

                Button(action: {
                    projectState.confirmDeleteFolder(id: folder.id)
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.leading, 2)
                .help("Delete Folder (its tracks stay)")
            }
            .padding(.trailing, 8)
        }
        .frame(width: ArrangerLayout.headerWidth, height: TrackFolder.rowHeight)
        .background(
            ZStack {
                Color(red: 0.15, green: 0.16, blue: 0.19)
                folder.color.opacity(0.10)
            }
        )
        .overlay(
            Rectangle()
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }
}
