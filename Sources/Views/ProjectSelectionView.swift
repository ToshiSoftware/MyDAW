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

                Text("プロジェクトフォルダを選択してください")
                    .foregroundColor(.white.opacity(0.7))

                HStack(spacing: 14) {
                    Button(action: onCreate) {
                        Label("新規プロジェクト", systemImage: "plus")
                            .frame(width: 190, height: 42)
                    }
                    .keyboardShortcut(.defaultAction)

                    Button(action: onOpen) {
                        Label("既存プロジェクトを開く", systemImage: "folder")
                            .frame(width: 190, height: 42)
                    }
                    .keyboardShortcut("o", modifiers: [.command])
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            }
            .padding(48)
        }
    }
}
