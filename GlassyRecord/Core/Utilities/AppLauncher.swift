import UIKit

/// Открывает приложение или URL по введённой строке (схема / ссылка / имя → scheme://).
enum AppLauncher {
    @MainActor
    static func open(_ raw: String) -> Result<URL, GlassyRecordError> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(.screenRecordingFailed(L10n.t("error.app_launch_empty")))
        }

        guard let url = makeURL(from: trimmed) else {
            return .failure(.screenRecordingFailed(L10n.format("error.app_launch_bad", trimmed)))
        }

        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        UsageTracker.shared.track(
            .appLaunchRequested,
            params: ["host": url.host ?? url.scheme ?? "unknown"]
        )
        return .success(url)
    }

    static func makeURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://"), let url = URL(string: trimmed) {
            return url
        }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"), let url = URL(string: trimmed) {
            return url
        }
        // «duolingo» → duolingo://
        let schemeCandidate = trimmed
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
        guard !schemeCandidate.isEmpty else { return nil }
        return URL(string: "\(schemeCandidate)://")
    }
}
