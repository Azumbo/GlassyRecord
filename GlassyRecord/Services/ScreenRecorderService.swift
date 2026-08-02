import Combine
import Foundation

/// Запись экрана на симуляторе (mock MP4). На устройстве запись — только через Broadcast Extension.
@MainActor
final class ScreenRecorderService: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isSimulatorMode = SimulatorSupport.isRunning
    @Published private(set) var duration: TimeInterval = 0
    @Published var error: GlassyRecordError?

    private var outputURL: URL?
    private var timer: Timer?
    private var startDate: Date?
    private var simulatorQuality: RecordingQuality = .hd1080p

    func startRecording(
        quality: RecordingQuality,
        captureSystemAudio: Bool,
        microphoneEnabled: Bool
    ) async throws -> URL {
        guard SimulatorSupport.isRunning else {
            throw GlassyRecordError.screenRecordingFailed(
                "На устройстве используйте системную запись экрана через Broadcast Extension."
            )
        }
        _ = captureSystemAudio
        _ = microphoneEnabled
        return try startSimulatorRecording(quality: quality)
    }

    func stopRecording() async throws -> URL {
        guard isRecording else {
            throw GlassyRecordError.screenRecordingFailed("Запись не активна")
        }
        guard SimulatorSupport.isRunning else {
            throw GlassyRecordError.screenRecordingFailed(
                "На устройстве используйте системную запись экрана через Broadcast Extension."
            )
        }
        return try await stopSimulatorRecording()
    }

    // MARK: - Simulator

    private func startSimulatorRecording(quality: RecordingQuality) throws -> URL {
        simulatorQuality = quality
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim_screen_\(UUID().uuidString).mp4")
        outputURL = url
        startDate = .now
        isRecording = true
        isSimulatorMode = true
        startTimer()
        return url
    }

    private func stopSimulatorRecording() async throws -> URL {
        let recordedDuration = max(duration, 1)
        stopTimer()
        isRecording = false
        let url = try await MockRecordingWriter.createSampleVideo(
            quality: simulatorQuality,
            duration: recordedDuration
        )
        outputURL = url
        return url
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let start = self.startDate else { return }
                self.duration = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        duration = 0
        startDate = nil
    }
}
