import SwiftUI
import AppKit

struct ProjectSelectionView: View {
    let onCreate: () -> Void
    let onOpen: () -> Void
    let onOpenRecent: (RecentProject) -> Void

    @ObservedObject private var recentProjects = RecentProjects.shared

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0"
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.92)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Image(systemName: "waveform")
                    .font(.system(size: 42, weight: .light))
                    .foregroundColor(.orange)

                Text("MyDAW")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.white)

                Text("Version \(appVersion)")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.white.opacity(0.55))

                Text("Create a new project or open a project file")
                    .foregroundColor(.white.opacity(0.7))

                HStack(spacing: 14) {
                    Button(action: onCreate) {
                        Label("New Project", systemImage: "plus")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 150, height: 100)
                            .background(Color.orange)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help("Create a new project")
                    .keyboardShortcut(.defaultAction)

                    Button(action: onOpen) {
                        Label("Open Project", systemImage: "folder")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 150, height: 100)
                            .background(Color.orange)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .help("Open an existing project")
                    .keyboardShortcut("o", modifiers: [.command])
                }

                recentProjectsList
            }
            .padding(48)
        }
    }

    private var recentProjectsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent Projects")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))

            ScrollView {
                LazyVStack(spacing: 0) {
                    if recentProjects.entries.isEmpty {
                        Text("No recent projects")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.4))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    ForEach(recentProjects.entries) { entry in
                        RecentProjectRow(entry: entry, onOpen: { onOpenRecent(entry) })
                            .contextMenu {
                                Button("Remove from List") {
                                    recentProjects.remove(entry)
                                }
                            }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(width: 520, height: 240)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
        }
    }
}

private struct RecentProjectRow: View {
    let entry: RecentProject
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        let exists = entry.exists
        HStack(spacing: 12) {
            if exists {
                Button(action: onOpen) {
                    Text(entry.name)
                        .underline(isHovering)
                        .foregroundColor(.orange)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help(entry.path)
                .onHover { hovering in
                    isHovering = hovering
                    if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
                }
                // Opening the project removes the start screen under the cursor.
                .onDisappear {
                    if isHovering { NSCursor.pop() }
                }
            } else {
                Text(entry.name)
                    .strikethrough()
                    .foregroundColor(.white.opacity(0.35))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(String(localized: "Not found: \(entry.path)"))
            }

            Spacer(minLength: 8)

            Text(entry.lastSavedAt, format: .dateTime.year().month().day().hour().minute())
                .foregroundColor(.white.opacity(exists ? 0.55 : 0.3))
                .monospacedDigit()
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}
