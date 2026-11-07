import Foundation

/// The GUI language. Until the user picks one, macOS's preferred languages
/// decide (falling back to English). A choice is stored as this app's
/// `AppleLanguages` default, which the system reads at launch, so a change
/// takes effect after MyDAW restarts.
public enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case japanese = "ja"

    public var id: String { rawValue }

    /// Shown in its own language so it can be found whichever one is active.
    public var displayName: String {
        switch self {
        case .english: return "English"
        case .japanese: return "日本語"
        }
    }

    /// The language the running app's strings were loaded in.
    public static var current: AppLanguage {
        Bundle.main.preferredLocalizations.first == AppLanguage.japanese.rawValue ? .japanese : .english
    }

    /// Makes `language` the GUI language from the next launch on.
    public static func select(_ language: AppLanguage) {
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
    }
}
