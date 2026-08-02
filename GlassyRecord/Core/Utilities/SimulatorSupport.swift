import Foundation

/// Утилиты для запуска на iOS Simulator, где нет камеры, ARKit и полноценного ReplayKit.
enum SimulatorSupport {
    #if targetEnvironment(simulator)
    static let isRunning = true
    #else
    static let isRunning = false
    #endif

    static var previewNotice: String { L10n.t("sim.preview_notice") }
}
