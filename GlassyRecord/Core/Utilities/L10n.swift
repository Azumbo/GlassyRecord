import Foundation

/// Ключи String Catalog (`Localizable.xcstrings`).
/// Язык UI = язык системы, либо принудительный выбор в Настройках (`localeOverride`).
enum L10n {
    /// `nil` — язык iPhone; иначе `en` / `ru` из настроек приложения.
    static var localeOverride: Locale?

    static func t(_ key: String.LocalizationValue) -> String {
        if let locale = localeOverride {
            return String(localized: key, locale: locale)
        }
        return String(localized: key)
    }

    /// Динамический ключ (например usage.feature.*).
    static func key(_ key: String) -> String {
        t(String.LocalizationValue(stringLiteral: key))
    }

    static func format(_ key: String.LocalizationValue, _ args: CVarArg...) -> String {
        let format = t(key)
        return String(format: format, locale: localeOverride ?? .current, arguments: args)
    }
}
