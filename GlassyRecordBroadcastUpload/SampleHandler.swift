@preconcurrency import ReplayKit

/// Broadcast Upload Extension — экран + системный звук + микрофон.
/// Face Cam попадает в запись через системный PiP поверх экрана (main app).
final class SampleHandler: RPBroadcastSampleHandler {
    private var writer: BroadcastVideoWriter?
    private var config: BroadcastRecordingConfig?
    private var setupStarted = false
    private let setupLock = NSLock()

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard AppGroup.isConfigured else {
            finishBroadcastWithError(makeError(
                "App Group не настроен. Включите group.com.glassyrecord.shared в Xcode."
            ))
            return
        }
        guard let config = BroadcastConfigStore.loadConfig() else {
            finishBroadcastWithError(makeError(
                "Конфигурация не найдена. Откройте Glassy Record и нажмите «Запись»."
            ))
            return
        }
        self.config = config
        BroadcastConfigStore.clearFailure()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        autoreleasepool {
            switch sampleBufferType {
            case .video:
                ensureWriterReadyIfNeeded(firstSample: sampleBuffer)
                writer?.appendVideo(sampleBuffer)
            case .audioApp, .audioMic:
                writer?.appendAudio(sampleBuffer, type: sampleBufferType)
            @unknown default:
                break
            }
        }
    }

    override func broadcastFinished() {
        guard let writer else {
            BroadcastConfigStore.markCancelled()
            return
        }

        let result = writer.finishSync()
        if result.success {
            // Относительное имя — надёжнее абсолютного пути между процессами App Group.
            BroadcastConfigStore.markScreenFinished(relativeFileName: result.relativeFileName)
        } else {
            BroadcastConfigStore.markFailed(
                result.errorMessage ?? "Не удалось сохранить запись экрана"
            )
            try? FileManager.default.removeItem(at: result.outputURL)
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
                finishBroadcastWithError(makeError("App Group контейнер недоступен"))
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
        } catch {
            setupStarted = false
            finishBroadcastWithError(error as NSError)
        }
    }

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "GlassyRecord", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
