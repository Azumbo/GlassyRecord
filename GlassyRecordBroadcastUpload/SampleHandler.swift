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

    override func broadcastFinished() {
        let wroteFrames = writer?.finishSync() ?? false
        if wroteFrames, let path = writer?.outputURL.path {
            BroadcastConfigStore.markScreenFinished(path: path)
        } else if writer != nil {
            BroadcastConfigStore.markFailed("Не получены кадры экрана. Держите запись хотя бы 2–3 секунды.")
        } else {
            BroadcastConfigStore.markCancelled()
        }
        writer = nil
    }

    private func ensureWriterReadyIfNeeded(firstSample: CMSampleBuffer) {
        setupLock.lock()
        let needsSetup = writer == nil && !setupStarted
        if needsSetup { setupStarted = true }
        setupLock.unlock()
        guard needsSetup, let config, let container = AppGroup.containerURLOptional else { return }

        do {
            let outputURL = container.appendingPathComponent("screen_\(UUID().uuidString).mp4")
            writer = try BroadcastVideoWriter(
                outputURL: outputURL,
                config: config,
                firstSample: firstSample
            )
            BroadcastConfigStore.markRecordingStarted()
        } catch {
            finishBroadcastWithError(error as NSError)
        }
    }

    private func makeError(_ message: String) -> NSError {
        NSError(domain: "GlassyRecord", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
