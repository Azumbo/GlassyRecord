import Combine
import SwiftUI
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
    @Published var touchIndicators: [TouchIndicator] = []
    private var lastTouchIndicatorPoint: CGPoint?
    @Published var glassesEnabled = false
    @Published private(set) var usesBroadcastMode = !SimulatorSupport.isRunning
    @Published private(set) var isPiPPreviewReady = false
    @Published private(set) var isScreenCaptured = false
    @Published private(set) var isPiPActive = false
    @Published var lastError: GlassyRecordError?
    @Published private(set) var completedSession: RecordingSession?

    let broadcastService = BroadcastRecordingService()
    let pipCameraManager = PiPCameraManager()
    let cameraService = CameraService()
    let screenRecorder = ScreenRecorderService()
    let audioService = AudioService()
    let glassesService = GlassesOverlayService()

    private var sessionTask: Task<Void, Never>?
    private var isFinalizingRecording = false
    private var controlsHideTask: Task<Void, Never>?
    private var timerHideTask: Task<Void, Never>?
    private var stateRefreshTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        self.glassesEnabled = settings.glassesEnabledByDefault
        self.faceCamScale = settings.pipContentScaleFactor
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
            .combineLatest(pipCameraManager.$isStreaming)
            .map { $0 && $1 }
            .receive(on: DispatchQueue.main)
            .assign(to: &$isPiPPreviewReady)

        pipCameraManager.$isPiPActive
            .receive(on: DispatchQueue.main)
            .assign(to: &$isPiPActive)
    }

    private var recordingStartedAt: Date?

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
                    let elapsed = self.recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                    guard elapsed > 2 else { return }
                    Task { await self.handleBroadcastEndedExternally() }
                }
            }
            .store(in: &cancellables)
    }

    func onAppear() {
        glassesService.lensTransparency = settings.lensTransparency
        glassesService.frameBrightness = settings.frameBrightness
        glassesService.setFrameColor(settings.glassesColor)
        glassesService.setEnabled(glassesEnabled, usesPiPCapture: usesBroadcastMode)
        applyFaceCamScaleFromSettings()

        if usesBroadcastMode {
            setupPhase = .idle
            prepareBroadcastConfig()
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
        applyFaceCamScaleFromSettings()
        do {
            try await pipCameraManager.prepare(
                glassesService: glassesService,
                mirrored: settings.faceCamMirrored,
                glassesEnabled: glassesEnabled,
                contentScale: faceCamScale
            )
            try pipCameraManager.startStreaming(startPiP: true)
        } catch {
            fail(with: error)
        }
    }

    func prepareBroadcastConfig() {
        guard AppGroup.isConfigured else { return }
        applyFaceCamScaleFromSettings()
        pipCameraManager.setContentScale(faceCamScale, invalidatePiP: true)
        BroadcastConfigStore.saveConfig(makeBroadcastConfig())
        RPScreenRecorder.shared().isMicrophoneEnabled = settings.microphoneEnabled
        pipCameraManager.requestPiPActive()
        UsageTracker.shared.track(
            .broadcastPrepare,
            params: [
                "mic": String(settings.microphoneEnabled),
                "system_audio": String(settings.systemAudioEnabled),
                "pip_preset": faceCamSizePreset.rawValue
            ]
        )
    }

    func handleScenePhase(_ phase: ScenePhase) {
        guard usesBroadcastMode else { return }
        pipCameraManager.handleScenePhase(phase)
    }

    private func beginActiveBroadcastSession() async {
        guard !isRecording || setupPhase != .recording else {
            broadcastService.startDurationTimer()
            return
        }
        applyFaceCamScaleFromSettings()
        broadcastService.resolveActiveControllerIfNeeded()
        broadcastService.startDurationTimer()
        isRecording = true
        setupPhase = .recording
        recordingStartedAt = Date()
        resetControlAutoHide()
        resetTimerAutoHide()
        UsageTracker.shared.track(
            .broadcastStarted,
            params: [
                "glasses": String(glassesEnabled),
                "pip_preset": faceCamSizePreset.rawValue,
                "quality": settings.quality.rawValue
            ]
        )

        if !pipCameraManager.isPrepared {
            await preparePiPCamera()
        }

        do {
            if !pipCameraManager.isStreaming {
                try pipCameraManager.startStreaming(startPiP: true)
            }
            pipCameraManager.requestPiPActive()
            await pipCameraManager.waitForFirstFrame()
            pipCameraManager.activatePiP()
            RecordingNotificationService.showRecordingStarted()
        } catch {
            fail(with: error)
        }
    }

    func refreshBroadcastState() {
        guard usesBroadcastMode else { return }

        isScreenCaptured = UIScreen.main.isCaptured
        broadcastService.refreshState()

        if BroadcastConfigStore.state == .failed,
           let message = BroadcastConfigStore.errorMessage,
           setupPhase != .saving,
           isRecording || isScreenCaptured {
            fail(with: message)
            return
        }

        if BroadcastConfigStore.state == .failed, !isRecording, !isScreenCaptured {
            BroadcastConfigStore.clearFailure()
        }

        if BroadcastConfigStore.state == .finished, isRecording {
            Task { await handleBroadcastEndedExternally() }
            return
        }

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
        let message = BroadcastErrorMessages.message(for: error)
        setupPhase = .failed(message)
        UsageTracker.shared.track(.recordingFailed, params: ["reason": String(message.prefix(120))])
    }

    private func fail(with message: String) {
        let text = BroadcastErrorMessages.message(forOptionalReason: message)
        setupPhase = .failed(text)
        UsageTracker.shared.track(.recordingFailed, params: ["reason": String(text.prefix(120))])
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
    var isAwaitingBroadcast: Bool {
        usesBroadcastMode && setupPhase == .idle && !isRecording && !isScreenCaptured
    }

    var showBroadcastSetupCard: Bool { isAwaitingBroadcast }

    var pipPreviewSession: AVCaptureSession? {
        guard usesBroadcastMode else { return nil }
        return pipCameraManager.previewSession
    }

    var pipProcessedPreviewLayer: AVSampleBufferDisplayLayer? {
        guard usesBroadcastMode, pipCameraManager.isPrepared else { return nil }
        return pipCameraManager.previewDisplayLayer
    }

    var faceCamSizePreset: PiPFaceSizePreset {
        PiPFaceSizePreset.nearest(to: faceCamScale)
    }

    /// Синхронизирует крупность из сохранённых настроек и передаёт в PiP-пайплайн (`PiPFrameScaler`).
    func applyFaceCamScaleFromSettings() {
        applyFaceCamScale(settings.pipContentScaleFactor)
    }

    func applyFaceCamScale(_ scale: CGFloat) {
        let preset = PiPFaceSizePreset.nearest(to: scale)
        guard abs(faceCamScale - preset.scaleFactor) > 0.02 else { return }
        faceCamScale = preset.scaleFactor
        pipCameraManager.setContentScale(faceCamScale, invalidatePiP: true)
    }

    func selectFaceCamSize(_ preset: PiPFaceSizePreset) {
        applyFaceCamScale(preset.scaleFactor)
        UsageTracker.shared.track(.pipSizePreset, params: ["preset": preset.rawValue, "source": "recording"])
    }

    func updateFaceCamScale(_ scale: CGFloat) {
        applyFaceCamScale(scale)
    }

    func stopRecording() async {
        _ = await finalizeRecording(stopActiveBroadcast: true)
    }

    func handleBroadcastEndedExternally() async {
        guard usesBroadcastMode, isRecording else { return }
        guard setupPhase == .recording || setupPhase == .saving else { return }
        _ = await finalizeRecording(stopActiveBroadcast: false)
    }

    func clearCompletedSession() {
        completedSession = nil
    }

    private func finalizeRecording(stopActiveBroadcast: Bool) async -> RecordingSession? {
        guard !isFinalizingRecording else { return nil }
        isFinalizingRecording = true
        defer { isFinalizingRecording = false }

        setupPhase = .saving
        let recordedDuration = duration

        if usesBroadcastMode {
            broadcastService.stopDurationTimer()
            RecordingNotificationService.clearRecordingNotification()
            pipCameraManager.stopStreaming()

            do {
                let url: URL
                if stopActiveBroadcast {
                    url = try await broadcastService.stopBroadcast()
                } else {
                    url = try await broadcastService.waitForFinishedRecording()
                }
                BroadcastConfigStore.reset()
                pipCameraManager.stop()
                isRecording = false
                setupPhase = .idle

                let session = try await makeRecordingSession(from: url, duration: recordedDuration)
                completedSession = session
                UsageTracker.shared.track(
                    .broadcastFinished,
                    params: [
                        "duration_s": String(format: "%.1f", recordedDuration),
                        "glasses": String(glassesEnabled)
                    ]
                )
                return session
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
            isRecording = false
            setupPhase = .idle

            let session = try await makeRecordingSession(from: url, duration: recordedDuration)
            completedSession = session
            UsageTracker.shared.track(
                .broadcastFinished,
                params: [
                    "duration_s": String(format: "%.1f", recordedDuration),
                    "mode": "simulator"
                ]
            )
            return session
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

    private func makeRecordingSession(from url: URL, duration: TimeInterval) async throws -> RecordingSession {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GlassyRecordError.fileNotFound
        }
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
        glassesService.setEnabled(glassesEnabled, usesPiPCapture: usesBroadcastMode)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        UsageTracker.shared.track(.glassesToggled, params: ["enabled": String(glassesEnabled)])
        if usesBroadcastMode, pipCameraManager.isPrepared {
            Task {
                pipCameraManager.stop()
                await preparePiPCamera()
            }
        }
    }

    func setGlassesColor(_ color: GlassesFrameColor) {
        glassesService.setFrameColor(color)
        UsageTracker.shared.track(.glassesColorChanged, params: ["color": color.rawValue, "source": "recording"])
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

        if let last = lastTouchIndicatorPoint {
            let dx = point.x - last.x
            let dy = point.y - last.y
            guard (dx * dx + dy * dy) >= 400 else { return } // ≥20pt между точками
        }
        lastTouchIndicatorPoint = point

        let indicator = TouchIndicator(
            position: point,
            color: Color(hex: settings.touchIndicatorColorHex) ?? .red,
            size: settings.touchIndicatorSize,
            opacity: settings.touchIndicatorOpacity
        )
        touchIndicators.append(indicator)
        UsageTracker.shared.track(.touchIndicatorShown)
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
                    self?.selectFaceCamSize(.minus25)
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

    func dismissFailure() {
        lastError = nil
        setupPhase = .idle
        isRecording = false
        recordingStartedAt = nil
        BroadcastConfigStore.clearFailure()
        broadcastService.stopDurationTimer()
    }

    func exitToHome(_ completion: () -> Void) {
        UsageTracker.shared.track(
            .exitRecording,
            params: [
                "was_recording": String(isRecording),
                "phase": String(describing: setupPhase)
            ]
        )
        dismissFailure()
        pipCameraManager.stopStreaming()
        pipCameraManager.stop()
        cleanup()
        completion()
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
