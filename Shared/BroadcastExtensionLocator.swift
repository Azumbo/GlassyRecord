import Foundation

/// Находит bundle ID встроенного Broadcast Extension в .app/PlugIns.
/// Hardcoded ID ломается, если в Xcode другой Team / bundle prefix.
enum BroadcastExtensionLocator {
  static func embeddedBundleID() -> String? {
    guard let pluginsURL = Bundle.main.builtInPlugInsURL,
          let contents = try? FileManager.default.contentsOfDirectory(
            at: pluginsURL,
            includingPropertiesForKeys: nil
          ) else { return nil }

    for url in contents where url.pathExtension == "appex" {
      guard let bundle = Bundle(url: url),
            let bundleID = bundle.bundleIdentifier,
            bundle.object(forInfoDictionaryKey: "NSExtension") != nil else { continue }
      return bundleID
    }
    return nil
  }

  static var preferredBundleID: String? {
    if let embedded = embeddedBundleID() { return embedded }
    return AppGroup.fallbackBroadcastExtensionBundleID
  }

  static var isExtensionEmbedded: Bool { embeddedBundleID() != nil }

  static var diagnosticMessage: String {
    if let id = embeddedBundleID() {
      return "Extension найден: \(id)"
    }
    return "Extension не встроен в приложение. Переустановите из Xcode (оба таргета: GlassyRecord + GlassyRecordBroadcastUpload)."
  }
}
