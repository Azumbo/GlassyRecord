import ReplayKit
import Combine
import UIKit

/// Управление системной записью экрана через Broadcast Extension.
@MainActor
final class BroadcastRecordingService: ObservableObject {
    @Published private(set) var isBroadcasting = false
    @Published private(set) var duration: TimeInterval = 0

    private var timer: Timer?
    private var activeController: RPBroadcastController?

    func setActiveController(_ controller: RPBroadcastController?) {
        activeController = controller
    }

    func resolveActiveControllerIfNeeded() {
        if activeController?.isBroadcasting == true { return }
        if let found = ActiveBroadcastController.current() {
            activeController = found
        }
    }

    func refreshState() {
        resolveActiveControllerIfNeeded()
        isBroadcasting = activeController?.isBroadcasting == true || BroadcastConfigStore.state == .recording
        updateDuration()
    }

    func saveConfig(_ config: BroadcastRecordingConfig) {
        BroadcastConfigStore.saveConfig(config)
    }

    /// Останавливает broadcast и ждёт MP4 экрана из extension.
    func stopBroadcast() async throws -> URL {
        resolveActiveControllerIfNeeded()

        if let controller = activeController, controller.isBroadcasting {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                controller.finishBroadcast { error in
                    if let error {
                        continuation.resume(throwing: GlassyRecordError.screenRecordingFailed(error.localizedDescription))
                    } else {
                        continuation.resume()
                    }
                }
            }
        } else if UIScreen.main.isCaptured {
            throw GlassyRecordError.screenRecordingFailed(
                "Не удалось остановить трансляцию. Завершите запись через Пункт управления → трансляция экрана, затем откройте Glassy Record снова."
            )
        }

        activeController = nil
        return try await waitForScreenFile()
    }

    func startDurationTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateDuration() }
        }
        updateDuration()
    }

    func stopDurationTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func updateDuration() {
        let start = BroadcastConfigStore.startTimestamp
        guard start > 0, isBroadcasting || BroadcastConfigStore.state == .recording else {
            duration = 0
            return
        }
        duration = max(0, Date().timeIntervalSince1970 - start)
    }

    private func waitForScreenFile(timeout: TimeInterval = 30) async throws -> URL {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if BroadcastConfigStore.state == .failed,
               let message = BroadcastConfigStore.errorMessage {
                throw GlassyRecordError.screenRecordingFailed(message)
            }
            if let path = BroadcastConfigStore.screenOutputPath {
                let url = URL(fileURLWithPath: path)
                if FileManager.default.fileExists(atPath: path) {
                    return url
                }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw GlassyRecordError.fileNotFound
    }
}
