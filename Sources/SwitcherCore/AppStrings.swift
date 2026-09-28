import Foundation

public enum AppStrings {
    public static func text(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: "Localizable")
    }
}
