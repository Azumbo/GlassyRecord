import Foundation

/// Ключи String Catalog (`Localizable.xcstrings`). Язык UI = язык системы iPhone.
enum L10n {
    static func t(_ key: String.LocalizationValue) -> String {
        String(localized: key)
    }

    static func format(_ key: String.LocalizationValue, _ args: CVarArg...) -> String {
        let format = String(localized: key)
        return String(format: format, locale: .current, arguments: args)
    }
}
