import Combine
import SwiftUI
import PencilKit

/// ViewModel записи — объединяет все сервисы и управляет состоянием оверлея.
@MainActor
final class RecordingViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var duration: TimeInterval = 0
    @Published var showControls = true
    @Published var showTimer = true
    @Published var faceCamPosition: CGPoint = CGPoint(x: 0.75, y: 0.75)
    @Published var faceCamScale: CGFloat = 1.0
    @Published var drawingTool: DrawingTool = .pen
    @Published var canvasDrawing = PKDrawing()
    @Published var touchIndicators: [TouchIndicator] = []
    @Published var glassesEnabled = false
    @Published var lastError: GlassyRecordError?

    let cameraService = CameraService()
    let screenRecorder = ScreenRecorderService()
    let audioService = AudioService()
    let glassesService = GlassesOverlayService()
    let renderService: RenderService?

    private var controlsHideTask: Task<Void, Never>?
    private var timerHideTask: Task<Void, Never>?
    private var outputURL: URL?
    private var cancellables = Set<AnyCancellable>()
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        self.renderService = RenderService()
        self.glassesEnabled = settings.glassesEnabledByDefault
        self.faceCamScale = settings.faceCamScale

        screenRecorder.$duration
            .receive(on: DispatchQueue.main)
            .assign(to: &$duration)

        screenRecorder.$isRecording
            .receive(on: DispatchQueue.main)
            .assign(to: &$isRecording)

        bindLowPowerMode()
    }

  func prepare() async {
        do {
            try await cameraService.configure(
                quality: settings.quality,
                mirrored: settings.faceCamMirrored
            )

            let micEnabled = settings.microphoneEnabled && !SimulatorSupport.isRunning
            if micEnabled {
                try await audioService.configure(microphoneEnabled: true)
            }

            glassesService.lensTransparency = settings.lensTransparency
            glassesService.frameBrightness = settings.frameBrightness
            glassesService.setFrameColor(settings.glassesColor)
            glassesService.setEnabled(glassesEnabled)

            cameraService.onFrame { [weak self] buffer in
                guard let self else { return }
                if self.glassesEnabled {
                    _ = self.glassesService.processFrame(buffer)
                }
            }

            cameraService.start()
            if micEnabled {
                audioService.startLevelMonitoring()
            }
        } catch let error as GlassyRecordError {
            if !SimulatorSupport.isRunning {
                lastError = error
            }
        } catch {
            if !SimulatorSupport.isRunning {
                lastError = .screenRecordingFailed(error.localizedDescription)
            }
        }
    }

    func startRecording() async {
        do {
            outputURL = try await screenRecorder.startRecording(
                quality: settings.quality,
                captureSystemAudio: settings.systemAudioEnabled,
                microphoneEnabled: settings.microphoneEnabled
            )
            resetControlAutoHide()
            resetTimerAutoHide()
        } catch let error as GlassyRecordError {
            lastError = error
        } catch {
            lastError = .screenRecordingFailed(error.localizedDescription)
        }
    }

    func stopRecording() async -> RecordingSession? {
        do {
            let url = try await screenRecorder.stopRecording()
            cameraService.stop()
            audioService.stopLevelMonitoring()
            glassesService.stopTracking()

            let thumb = await ExportService().generateThumbnail(for: url)
            return RecordingSession(
                title: "Запись \(Date.now.formatted(date: .abbreviated, time: .shortened))",
                duration: duration,
                fileURL: url,
                thumbnailData: thumb,
                quality: settings.quality,
                glassesEnabled: glassesEnabled,
                glassesColor: glassesService.frameColor
            )
        } catch let error as GlassyRecordError {
            lastError = error
            return nil
        } catch {
            lastError = .screenRecordingFailed(error.localizedDescription)
            return nil
        }
    }

    func toggleGlasses() {
        glassesEnabled.toggle()
        glassesService.setEnabled(glassesEnabled)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func setGlassesColor(_ color: GlassesFrameColor) {
        glassesService.setFrameColor(color)
    }

    func userInteraction() {
        showControls = true
        resetControlAutoHide()
    }

    func resetControlAutoHide() {
        controlsHideTask?.cancel()
        controlsHideTask = Task {
            try? await Task.sleep(for: .seconds(settings.controlPanelAutoHideSeconds))
            guard !Task.isCancelled else { return }
            showControls = false
        }
    }

    func resetTimerAutoHide() {
        showTimer = true
        timerHideTask?.cancel()
        timerHideTask = Task {
            try? await Task.sleep(for: .seconds(settings.timerAutoHideSeconds))
            guard !Task.isCancelled else { return }
            showTimer = false
        }
    }

    func addTouchIndicator(at point: CGPoint) {
        guard settings.touchIndicatorEnabled else { return }
        let indicator = TouchIndicator(
            position: point,
            color: Color(hex: settings.touchIndicatorColorHex) ?? .red,
            size: settings.touchIndicatorSize,
            opacity: settings.touchIndicatorOpacity
        )
        touchIndicators.append(indicator)
        Task {
            try? await Task.sleep(for: .seconds(0.6))
            touchIndicators.removeAll { $0.id == indicator.id }
        }
    }

    private func bindLowPowerMode() {
        guard settings.lowPowerModeAware else { return }
        NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)
            .sink { [weak self] _ in
                if ProcessInfo.processInfo.isLowPowerModeEnabled {
                    self?.faceCamScale = min(self?.faceCamScale ?? 1, 0.85)
                }
            }
            .store(in: &cancellables)
    }

    func cleanup() {
        cameraService.stop()
        audioService.stopLevelMonitoring()
        glassesService.stopTracking()
        controlsHideTask?.cancel()
        timerHideTask?.cancel()
    }
}

struct TouchIndicator: Identifiable {
    let id = UUID()
    let position: CGPoint
    let color: Color
    let size: CGFloat
    let opacity: Double
}

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        guard hexSanitized.count == 6, let int = UInt64(hexSanitized, radix: 16) else { return nil }
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
