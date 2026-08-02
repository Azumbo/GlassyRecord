@preconcurrency import ReplayKit
import CoreMedia

/// Broadcast Upload Extension — экран + системный звук + микрофон.
/// Face Cam попадает в запись через системный PiP поверх экрана (main app).
final class SampleHandler: RPBroadcastSampleHandler {
    private var writer: BroadcastVideoWriter?
    private var config: BroadcastRecordingConfig?
    private var setupStarted = false
    private var isFinishingBroadcast = false
    private let setupLock = NSLock()
    /// Копии аудио до первого video-кадра (иначе mic/app теряются до startSession).
    private var pendingAudio: [(CMSampleBuffer, RPSampleBufferType)] = []
    private let pendingLock = NSLock()
    private let maxPendingAudio = 90

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
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
        BroadcastConfigStore.markExtensionAlive(
            event: "broadcast_started",
            extra: "mic=\(config.microphoneEnabled);sys=\(config.systemAudioEnabled)"
        )
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        if isFinishingBroadcast { return }
        autoreleasepool {
            switch sampleBufferType {
            case .video:
                ensureWriterReadyIfNeeded(firstSample: sampleBuffer)
                writer?.appendVideo(sampleBuffer)
                flushPendingAudioIfPossible()
                BroadcastConfigStore.touchExtensionHeartbeat()
            case .audioApp, .audioMic:
                if let writer, writer.canAcceptAudio {
                    writer.appendAudio(sampleBuffer, type: sampleBufferType)
                } else if let copy = Self.copySampleBuffer(sampleBuffer) {
                    pendingLock.lock()
                    if pendingAudio.count < maxPendingAudio {
                        pendingAudio.append((copy, sampleBufferType))
                    }
                    pendingLock.unlock()
                }
            @unknown default:
                break
            }
        }
    }

    override func broadcastFinished() {
        isFinishingBroadcast = true
        BroadcastConfigStore.markFinalizing()
        flushPendingAudioIfPossible()

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
                extra: "size=\(result.fileSize);mic=\(result.micBuffers);app=\(result.appBuffers)"
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
        pendingLock.lock()
        pendingAudio.removeAll()
        pendingLock.unlock()
    }

    private func flushPendingAudioIfPossible() {
        guard let writer, writer.canAcceptAudio else { return }
        pendingLock.lock()
        let batch = pendingAudio
        pendingAudio.removeAll()
        pendingLock.unlock()
        for (buffer, type) in batch {
            writer.appendAudio(buffer, type: type)
        }
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
            flushPendingAudioIfPossible()
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

    private static func copySampleBuffer(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopy(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleBufferOut: &copy
        )
        guard status == noErr else { return nil }
        return copy
    }
}
