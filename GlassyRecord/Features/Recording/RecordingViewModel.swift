import Combine
import SwiftUI
import PencilKit
import ReplayKit
import UIKit

enum RecordingSetupPhase: Equatable {
    case idle
    case preparing
    case recording
    case saving
    case failed(String)

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// ViewModel: broadcast (экран + звук) + Face Cam через системный PiP с AR-очками.
@MainActor
final class RecordingViewModel: ObservableObject {
    @Published var isRecording = false
    @Published var duration: TimeInterval = 0
    @Published var setupPhase: RecordingSetupPhase = .idle
    @Published var showControls = true
    @Published var showTimer = true
    @Published var faceCamPosition: CGPoint
    @Published var faceCamScale: CGFloat = 1.0
    @Published var drawingTool: DrawingTool = .pen
    @Published var canvasDrawing = PKDrawing()
    @Published var touchIndicators: [TouchIndicator] = []
    @Published var glassesEnabled = false
    @Published private(set) var usesBroadcastMode = !SimulatorSupport.isRunning
    @Published private(set) var isPiPPreviewReady = false
    @Published var lastError: GlassyRecordError?

    let broadcastService = BroadcastRecordingService()
    let pipCameraManager = PiPCameraManager()
    let cameraService = CameraService()
    let screenRecorder = ScreenRecorderService()
    let audioService = AudioService()
    let glassesService = GlassesOverlayService()

    private var sessionTask: Task<Void, Never>?
    private var controlsHideTask: Task<Void, Never>?
    private var timerHideTask: Task<Void, Never>?
    private var stateRefreshTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        self.glassesEnabled = settings.glassesEnabledByDefault
        self.faceCamScale = settings.faceCamScale
        self.faceCamPosition = settings.faceCamCorner.normalizedPosition

        if usesBroadcastMode {
            broadcastService.$duration
                .receive(on: DispatchQueue.main)
                .assign(to: &$duration)
        } else {
            screenRecorder.$duration
                .receive(on: DispatchQueue.main)
                .assign(to: &$duration)
            screenRecorder.$isRecording
                .receive(on: DispatchQueue.main)
                .assign(to: &$isRecording)
        }

        bindLowPowerMode()
        bindScreenCaptureObserver()

        pipCameraManager.$isPrepared
            .receive(on: DispatchQueue.main)
            .assign(to: &$isPiPPreviewReady)
    }

    private func bindScreenCaptureObserver() {
        guard usesBroadcastMode else { return }
        NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if UIScreen.main.isCaptured {
                    if self.setupPhase.isFailed {
                        self.setupPhase = .idle
                    }
                    if !self.isRecording {
                        if let controller = ActiveBroadcastController.current() {
                            self.broadcastService.setActiveController(controller)
                        }
                        Task { await self.beginActiveBroadcastSession() }
                    }
                } else if self.isRecording {
                    self.refreshBroadcastState()
                }
            }
            .store(in: &cancellables)
    }

    func onAppear() {
        glassesService.lensTransparency = settings.lensTransparency
        glassesService.frameBrightness = settings.frameBrightness
        glassesService.setFrameColor(settings.glassesColor)
        glassesService.setEnabled(glassesEnabled)

        if usesBroadcastMode {
            setupPhase = .idle
            refreshBroadcastState()
            if isRecording {
                setupPhase = .recording
                broadcastService.startDurationTimer()
            }
            startStateRefreshLoop()
            Task {
                await RecordingNotificationService.requestAuthorization()
                await preparePiPCamera()
            }
        } else {
            beginInAppSession()
        }
    }

    private func preparePiPCamera() async {
        do {
            try await pipCameraManager.prepare(
                glassesService: glassesService,
                mirrored: settings.faceCamMirrored,
                glassesEnabled: glassesEnabled
            )
            try pipCameraManager.startStreaming(startPiP: false)
        } catch {
            fail(with: error)
        }
    }

    func prepareBroadcastConfig() {
        guard AppGroup.isConfigured else { return }
        BroadcastConfigStore.saveConfig(makeBroadcastConfig())
        RPScreenRecorder.shared().isMicrophoneEnabled = settings.microphoneEnabled
    }

    private func beginActiveBroadcastSession() async {
        guard !isRecording || setupPhase != .recording else {
            broadcastService.startDurationTimer()
            return
        }
        broadcastService.resolveActiveControllerIfNeeded()
        broadcastService.startDurationTimer()
        isRecording = true
        setupPhase = .recording
        resetControlAutoHide()
        resetTimerAutoHide()

        if !pipCameraManager.isPrepared {
            await preparePiPCamera()
        }

        do {
            if !pipCameraManager.isStreaming {
                try pipCameraManager.startStreaming(startPiP: false)
            }
            pipCameraManager.activatePiP()
            RecordingNotificationService.showRecordingStarted()
        } catch {
            fail(with: error)
        }
    }

    func refreshBroadcastState() {
        guard usesBroadcastMode else { return }

        broadcastService.refreshState()

        let active = broadcastService.isBroadcasting || BroadcastConfigStore.state == .recording
        if active {
            if !isRecording {
                Task { await beginActiveBroadcastSession() }
            } else if setupPhase != .saving {
                setupPhase = .recording
            }
        }
    }

    private func beginInAppSession() {
        guard setupPhase == .idle || setupPhase.isFailed else { return }
        setupPhase = .preparing
        sessionTask?.cancel()
        sessionTask = Task { await prepareAndRecordInApp() }
    }

    private func prepareAndRecordInApp() async {
        do {
            glassesService.lensTransparency = settings.lensTransparency
            glassesService.frameBrightness = settings.frameBrightness
            glassesService.setFrameColor(settings.glassesColor)
            glassesService.setEnabled(glassesEnabled)

            try await cameraService.configure(
                quality: settings.quality,
                mirrored: settings.faceCamMirrored
            )
            cameraService.onFrame { [weak self] buffer in
                guard let self, self.glassesEnabled else { return }
                _ = self.glassesService.processFrame(buffer)
            }
            cameraService.start()

            guard !Task.isCancelled else { return }

            _ = try await screenRecorder.startRecording(
                quality: settings.quality,
                captureSystemAudio: settings.systemAudioEnabled,
                microphoneEnabled: settings.microphoneEnabled
            )
            setupPhase = .recording
            resetControlAutoHide()
            resetTimerAutoHide()
        } catch let error as GlassyRecordError {
            lastError = error
            fail(with: error)
        } catch {
            fail(with: error)
        }
    }

    private func fail(with error: Error) {
        setupPhase = .failed(BroadcastErrorMessages.message(for: error))
    }

    private func fail(with message: String) {
        setupPhase = .failed(BroadcastErrorMessages.message(forOptionalReason: message))
    }

    func makeBroadcastConfig() -> BroadcastRecordingConfig {
        BroadcastRecordingConfig.from(
            settings: settings,
            faceCamPosition: faceCamPosition,
            faceCamScale: faceCamScale,
            glassesEnabled: glassesEnabled
        )
    }

    var isPreparing: Bool { setupPhase == .preparing }
    var isFailed: Bool { setupPhase.isFailed }
    var isSaving: Bool { setupPhase == .saving }
    var isAwaitingBroadcast: Bool { usesBroadcastMode && setupPhase == .idle }

    func stopRecordingAndSave() async -> URL? {
        setupPhase = .saving

        if usesBroadcastMode {
            broadcastService.stopDurationTimer()
            RecordingNotificationService.clearRecordingNotification()
            pipCameraManager.stopStreaming()

            do {
                let screenURL = try await broadcastService.stopBroadcast()
                try await ExportService().saveToPhotoLibrary(url: screenURL)
                BroadcastConfigStore.reset()
                pipCameraManager.stop()
                isRecording = false
                setupPhase = .idle
                return screenURL
            } catch let error as GlassyRecordError {
                lastError = error
                fail(with: error)
                return nil
            } catch {
                lastError = .exportFailed(error.localizedDescription)
                fail(with: error)
                return nil
            }
        }

        cameraService.stop()
        audioService.stopLevelMonitoring()
        glassesService.stopTracking()

        do {
            let url = try await screenRecorder.stopRecording()
            try await ExportService().saveToPhotoLibrary(url: url)
            isRecording = false
            setupPhase = .idle
            return url
        } catch let error as GlassyRecordError {
            lastError = error
            fail(with: error)
            return nil
        } catch {
            lastError = .exportFailed(error.localizedDescription)
            fail(with: error)
            return nil
        }
    }

    func stopRecording() async -> RecordingSession? {
        guard let url = await stopRecordingAndSave() else { return nil }
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
    }

    func toggleGlasses() {
        glassesEnabled.toggle()
        glassesService.setEnabled(glassesEnabled)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if usesBroadcastMode, pipCameraManager.isPrepared {
            Task {
                pipCameraManager.stop()
                await preparePiPCamera()
            }
        }
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
        guard settings.touchIndicatorEnabled, !usesBroadcastMode else { return }
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

    private func startStateRefreshLoop() {
        stateRefreshTask?.cancel()
        stateRefreshTask = Task {
            while !Task.isCancelled {
                refreshBroadcastState()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func cleanup() {
        sessionTask?.cancel()
        stateRefreshTask?.cancel()
        broadcastService.stopDurationTimer()
        RecordingNotificationService.clearRecordingNotification()
        if !isRecording {
            cameraService.stop()
            pipCameraManager.stop()
        }
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
