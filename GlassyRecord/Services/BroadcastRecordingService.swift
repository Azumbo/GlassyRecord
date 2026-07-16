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

    /// Ждёт MP4 после остановки трансляции (в т.ч. из Пункта управления).
    func waitForFinishedRecording() async throws -> URL {
        try await waitForScreenFile()
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

    private func waitForScreenFile(timeout: TimeInterval = 45) async throws -> URL {
        let deadline = Date().addingTimeInterval(timeout)
        var sawFinishedWithoutFile = false

        while Date() < deadline {
            if BroadcastConfigStore.state == .failed,
               let message = BroadcastConfigStore.errorMessage {
                throw GlassyRecordError.screenRecordingFailed(message)
            }

            if let url = BroadcastConfigStore.screenOutputURL {
                if FileManager.default.fileExists(atPath: url.path) {
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                    if size > 0 {
                        return url
                    }
                }
                if BroadcastConfigStore.state == .finished {
                    sawFinishedWithoutFile = true
                }
            }

            try await Task.sleep(for: .milliseconds(200))
        }

        if sawFinishedWithoutFile {
            throw GlassyRecordError.screenRecordingFailed(
                "Extension сообщил о завершении, но MP4 в App Group пуст или недоступен."
            )
        }
        if BroadcastConfigStore.state == .recording {
            throw GlassyRecordError.screenRecordingFailed(
                "Запись не завершилась вовремя. Остановите трансляцию экрана в Пункте управления и попробуйте снова."
            )
        }
        throw GlassyRecordError.fileNotFound
    }
}
