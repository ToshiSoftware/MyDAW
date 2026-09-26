import SwiftUI

struct ProjectSelectionView: View {
    let onCreate: () -> Void
    let onOpen: () -> Void

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2"
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

                Text("Choose a project folder to get started")
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
            }
            .padding(48)
        }
    }
}
