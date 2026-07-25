@preconcurrency import ReplayKit

/// Broadcast Upload Extension — экран + системный звук + микрофон.
/// Face Cam попадает в запись через системный PiP поверх экрана (main app).
final class SampleHandler: RPBroadcastSampleHandler {
    private var writer: BroadcastVideoWriter?
    private var config: BroadcastRecordingConfig?
    private var setupStarted = false
    private var isFinishingBroadcast = false
    private let setupLock = NSLock()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        // Сразу пишем heartbeat в App Group — иначе main app думает, что пишется «системная» запись.
        BroadcastConfigStore.markExtensionAlive(event: "broadcast_started_entry")

        guard AppGroup.isConfigured else {
            let message = "App Group не настроен. Включите group.com.azumbo.glassyrecord.shared в Xcode."
            BroadcastConfigStore.markFailed(message)
            BroadcastConfigStore.markExtensionAlive(event: "app_group_missing")
            finishBroadcastWithError(makeError(message))
            return
        }
        guard let config = BroadcastConfigStore.loadConfig() else {
            let message = "Конфигурация не найдена. Откройте Glassy Record и нажмите «Готов к записи»."
            BroadcastConfigStore.markFailed(message)
            BroadcastConfigStore.markExtensionAlive(event: "config_missing")
            finishBroadcastWithError(makeError(message))
            return
        }
        self.config = config
        BroadcastConfigStore.clearFailure()
        BroadcastConfigStore.markExtensionAlive(event: "broadcast_started")
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        if isFinishingBroadcast { return }
        autoreleasepool {
            switch sampleBufferType {
            case .video:
                ensureWriterReadyIfNeeded(firstSample: sampleBuffer)
                writer?.appendVideo(sampleBuffer)
                BroadcastConfigStore.touchExtensionHeartbeat()
            case .audioApp, .audioMic:
                writer?.appendAudio(sampleBuffer, type: sampleBufferType)
            @unknown default:
                break
            }
        }
    }

    override func broadcastFinished() {
        isFinishingBroadcast = true
        BroadcastConfigStore.markFinalizing()

        guard let writer else {
            let message = "Extension завершился без видеокадров. Убедитесь, что выбран именно Glassy Record и запись шла дольше 2 секунд."
            BroadcastConfigStore.markFailed(message)
            BroadcastConfigStore.markExtensionAlive(event: "finished_no_writer")
            return
        }

        let result = writer.finishSync()
        if result.success {
            BroadcastConfigStore.markScreenFinished(relativeFileName: result.relativeFileName)
            BroadcastConfigStore.markExtensionAlive(
                event: "finished_ok",
                extra: "size=\(result.fileSize)"
            )
        } else {
            BroadcastConfigStore.markFailed(
                result.errorMessage ?? "Не удалось сохранить запись экрана"
            )
            BroadcastConfigStore.markExtensionAlive(
                event: "finished_fail",
                extra: result.errorMessage ?? ""
            )
            if !result.wroteFrames || result.fileSize == 0 {
                try? FileManager.default.removeItem(at: result.outputURL)
            }
        }
        self.writer = nil
    }

    private func ensureWriterReadyIfNeeded(firstSample: CMSampleBuffer) {
        setupLock.lock()
        let needsSetup = writer == nil && !setupStarted
        if needsSetup { setupStarted = true }
        setupLock.unlock()
        guard needsSetup, let config, let container = AppGroup.containerURLOptional else {
            if needsSetup, AppGroup.containerURLOptional == nil {
                let message = "App Group контейнер недоступен"
                BroadcastConfigStore.markFailed(message)
                BroadcastConfigStore.markExtensionAlive(event: "container_missing")
                finishBroadcastWithError(makeError(message))
            }
            return
        }

        do {
            let recordingsDir = container.appendingPathComponent("Recordings", isDirectory: true)
            try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
            let fileName = "screen_\(UUID().uuidString).mp4"
            let outputURL = recordingsDir.appendingPathComponent(fileName)
            writer = try BroadcastVideoWriter(
                outputURL: outputURL,
                relativeFileName: "Recordings/\(fileName)",
                config: config,
                firstSample: firstSample
            )
            BroadcastConfigStore.markRecordingStarted()
            BroadcastConfigStore.markExtensionAlive(event: "writer_ready")
        } catch {
            setupStarted = false
            let message = (error as NSError).localizedDescription
            BroadcastConfigStore.markFailed(message)
            BroadcastConfigStore.markExtensionAlive(event: "writer_init_fail", extra: message)
            finishBroadcastWithError(error as NSError)
        }
    }

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "GlassyRecord", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
