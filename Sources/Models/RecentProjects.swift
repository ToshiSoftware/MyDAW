import Foundation

/// One entry of the start screen's "Recent Projects" list.
struct RecentProject: Codable, Identifiable, Equatable {
    /// Path of the .mydaw file.
    var path: String
    var lastSavedAt: Date

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// Recently opened or saved projects, most recent first, kept in UserDefaults.
final class RecentProjects: ObservableObject {
    static let shared = RecentProjects()
    static let maxCount = 50

    private static let defaultsKey = "MyDAW.recentProjects"

    @Published private(set) var entries: [RecentProject]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([RecentProject].self, from: data) {
            entries = decoded
        } else {
            entries = []
        }
    }

    /// Records a save of the project file now.
    func noteSaved(_ projectURL: URL) {
        moveToTop(projectURL, lastSavedAt: Date())
    }

    /// Records an open. The date shown stays the project's last save, read
    /// from the file itself.
    func noteOpened(_ projectURL: URL) {
        let modified = (try? projectURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        let known = entries.first { $0.path == projectURL.standardizedFileURL.path }?.lastSavedAt
        moveToTop(projectURL, lastSavedAt: modified ?? known ?? Date())
    }

    func remove(_ entry: RecentProject) {
        entries.removeAll { $0.path == entry.path }
        persist()
    }

    private func moveToTop(_ projectURL: URL, lastSavedAt: Date) {
        let path = projectURL.standardizedFileURL.path
        entries.removeAll { $0.path == path }
        entries.insert(RecentProject(path: path, lastSavedAt: lastSavedAt), at: 0)
        if entries.count > Self.maxCount {
            entries.removeLast(entries.count - Self.maxCount)
        }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
