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
        isBroadcasting = activeController?.isBroadcasting == true
            || BroadcastConfigStore.state == .recording
            || BroadcastConfigStore.state == .finalizing
        updateDuration()
    }

    func saveConfig(_ config: BroadcastRecordingConfig) {
        BroadcastConfigStore.saveConfig(config)
    }

    /// Останавливает broadcast и ждёт MP4 экрана из extension.
    func stopBroadcast() async throws -> URL {
        resolveActiveControllerIfNeeded()

        let controller = activeController ?? ActiveBroadcastController.current()
        let hadController = controller?.isBroadcasting == true
        UsageTracker.shared.track(
            .broadcastStopRequested,
            params: [
                "controller": String(hadController),
                "captured": String(UIScreen.main.isCaptured),
                "state": BroadcastConfigStore.state.rawValue
            ]
        )

        if let controller, controller.isBroadcasting {
            activeController = controller
            do {
                try await finishBroadcastWithTimeout(controller, seconds: 20)
                UsageTracker.shared.track(.broadcastStopSucceeded, params: ["via": "controller"])
            } catch {
                UsageTracker.shared.track(
                    .broadcastStopFailed,
                    params: ["reason": String(error.localizedDescription.prefix(80))]
                )
                // Даже при ошибке finish — ждём handoff: extension мог успеть записать файл.
            }
        } else if UIScreen.main.isCaptured {
            // Контроллер не найден — ждём, пока пользователь/система снимет capture,
            // либо extension сам финализирует.
            UsageTracker.shared.track(
                .broadcastStopFailed,
                params: ["reason": "no_controller_still_captured"]
            )
        }

        activeController = nil
        return try await waitForScreenFile()
    }

    /// Ждёт MP4 после остановки трансляции (в т.ч. из Пункта управления).
    func waitForFinishedRecording() async throws -> URL {
        UsageTracker.shared.track(
            .broadcastStopRequested,
            params: [
                "via": "external",
                "captured": String(UIScreen.main.isCaptured),
                "state": BroadcastConfigStore.state.rawValue
            ]
        )
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
        guard start > 0,
              isBroadcasting
                || BroadcastConfigStore.state == .recording
                || BroadcastConfigStore.state == .finalizing else {
            duration = 0
            return
        }
        duration = max(0, Date().timeIntervalSince1970 - start)
    }

    private func finishBroadcastWithTimeout(_ controller: RPBroadcastController, seconds: TimeInterval) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    controller.finishBroadcast { error in
                        if let error {
                            continuation.resume(throwing: GlassyRecordError.screenRecordingFailed(error.localizedDescription))
                        } else {
                            continuation.resume()
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw GlassyRecordError.screenRecordingFailed(
                    String(format: L10n.t("error.broadcast_timeout"), Int(seconds))
                )
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private func waitForScreenFile(timeout: TimeInterval = 45) async throws -> URL {
        let deadline = Date().addingTimeInterval(timeout)
        var sawFinishedWithoutFile = false
        var sawFinalizing = false
        var sawExtensionAlive = BroadcastConfigStore.hasExtensionHeartbeat
        var sawRecording = BroadcastConfigStore.state == .recording

        while Date() < deadline {
            // Подтягиваем свежие значения App Group (файл + defaults).
            _ = BroadcastConfigStore.state

            if BroadcastConfigStore.hasExtensionHeartbeat {
                sawExtensionAlive = true
            }
            if BroadcastConfigStore.state == .recording {
                sawRecording = true
            }

            if BroadcastConfigStore.state == .failed,
               let message = BroadcastConfigStore.errorMessage {
                throw GlassyRecordError.screenRecordingFailed(message)
            }

            if BroadcastConfigStore.state == .finalizing {
                sawFinalizing = true
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

            // Файл уже finished по state, но path мог появиться чуть позже synchronize.
            if BroadcastConfigStore.state == .finished, BroadcastConfigStore.screenOutputURL == nil {
                sawFinishedWithoutFile = true
            }

            try await Task.sleep(for: .milliseconds(200))
        }

        let snapshot = BroadcastConfigStore.diagnosticSnapshot(isScreenCaptured: UIScreen.main.isCaptured)
        UsageTracker.shared.track(.recordingFailed, params: ["diag": String(snapshot.prefix(160))])

        if sawFinishedWithoutFile {
            throw GlassyRecordError.screenRecordingFailed(
                L10n.format("error.extension_empty_mp4", snapshot)
            )
        }
        if sawFinalizing {
            throw GlassyRecordError.screenRecordingFailed(
                L10n.format("error.extension_finalizing_stuck", snapshot)
            )
        }
        if BroadcastConfigStore.state == .recording || sawRecording {
            throw GlassyRecordError.screenRecordingFailed(
                L10n.format("error.broadcast_not_finished", snapshot)
            )
        }
        if !sawExtensionAlive {
            throw GlassyRecordError.screenRecordingFailed(
                L10n.format("error.extension_no_heartbeat", snapshot)
            )
        }
        throw GlassyRecordError.screenRecordingFailed(
            L10n.format("error.file_not_found_diag", snapshot)
        )
    }
}
