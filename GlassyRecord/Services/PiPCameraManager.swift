@preconcurrency import AVFoundation
import AVKit
import Combine
import SwiftUI
import UIKit

/// Face Cam через системный PiP: кадры → AVSampleBufferDisplayLayer (фикс. окно) → PiP.
@MainActor
final class PiPCameraManager: NSObject, ObservableObject {
    @Published private(set) var isPrepared = false
    @Published private(set) var isStreaming = false
    @Published private(set) var isPiPActive = false

    let displayLayer: AVSampleBufferDisplayLayer = {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspectFill
        layer.backgroundColor = UIColor.black.cgColor
        layer.isOpaque = true
        return layer
    }()

    let previewDisplayLayer: AVSampleBufferDisplayLayer = {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspectFill
        layer.backgroundColor = UIColor.black.cgColor
        layer.isOpaque = true
        return layer
    }()

    private let rotationPreviewLayer = AVCaptureVideoPreviewLayer()

    var isPictureInPictureSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    private var pipController: AVPictureInPictureController?
    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private weak var glassesService: GlassesOverlayService?
    private var mirrored = true
    private var glassesEnabled = false
    private var contentScale: CGFloat = 1.0
    private let videoQueue = DispatchQueue(label: "com.glassyrecord.pip.video", qos: .userInitiated)
    private let sessionQueue = DispatchQueue(label: "com.glassyrecord.pip.session")
    private let framePipeline = PiPFramePipeline()
    private var interruptionObserver: NSObjectProtocol?
    private var interruptionEndedObserver: NSObjectProtocol?
    private var captureDevice: AVCaptureDevice?
    private var rotationHandler: CaptureRotationHandler?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var pendingPiPActivation = false
    private var pendingPiPRestartForScaleChange = false
  /// Кратко блокируем sync после смены пресета «Крупность», чтобы iOS не откатила зум.
    private var systemRenderSizeSyncSuppressedUntil: Date?
    private var wantsPiPActive = false
    private let audioKeepAlive = PiPAudioKeepAlive()
    /// Пока идёт broadcast, keep-alive не держит AVAudioSession — иначе ReplayKit не получает mic.
    private var suppressAudioKeepAliveForBroadcast = false

    var previewSession: AVCaptureSession? { captureSession }
    var previewDevice: AVCaptureDevice? { captureDevice }

    override init() {
        super.init()
        framePipeline.bind(displayLayer: displayLayer)
        framePipeline.bindPreview(displayLayer: previewDisplayLayer)
        framePipeline.onFirstFrame = { [weak self] in
            Task { @MainActor in self?.activatePiPIfPending() }
        }
    }

    @MainActor
    private func applyPresetRenderSizes(restartPiPIfActive: Bool = false, resetWindowToMinimum: Bool = false) {
        // Крупность = цифровой зум. Стартовый размер окна — только до первого sync с системой.
        // Не блокируем didTransitionToRenderSize надолго: иначе iOS оставляет широкий shell с чёрными полями.
        if resetWindowToMinimum, pipController?.isPictureInPictureActive != true {
            suppressSystemRenderSizeSync(for: 0.15)
            PiPDisplayLayerHost.resetToMinimumSize(displayLayer: displayLayer)
        } else {
            suppressSystemRenderSizeSync(for: 0.2)
        }
        let pointSize = PiPDisplayLayerHost.currentRenderSize
        let pixelSize = PiPPixelGeometry.pixelSize(fromPoints: pointSize)
        framePipeline.setTargetRenderSize(pixelSize)

        displayLayer.flush()
        if #available(iOS 14.0, *), displayLayer.requiresFlushToResumeDecoding {
            displayLayer.flush()
        }
        previewDisplayLayer.flush()
        PiPSampleBufferFactory.reset()
        framePipeline.configure(
            contentScale: contentScale,
            glassesEnabled: glassesEnabled,
            glassesService: glassesEnabled ? glassesService : nil
        )

        if restartPiPIfActive {
            pipController?.invalidatePlaybackState()
        }
    }

    private func suppressSystemRenderSizeSync(for duration: TimeInterval = 0.75) {
        systemRenderSizeSyncSuppressedUntil = Date().addingTimeInterval(duration)
    }

    private var shouldSuppressSystemRenderSizeSync: Bool {
        guard let until = systemRenderSizeSyncSuppressedUntil else { return false }
        if Date() < until { return true }
        systemRenderSizeSyncSuppressedUntil = nil
        return false
    }

    func setGlassesEnabled(_ enabled: Bool) {
        glassesEnabled = enabled
        framePipeline.configure(
            contentScale: contentScale,
            glassesEnabled: glassesEnabled,
            glassesService: glassesEnabled ? glassesService : nil
        )
        if enabled {
            glassesService?.startTrackingForPiP()
        } else {
            glassesService?.stopTracking()
        }
    }

    func setContentScale(_ scale: CGFloat, invalidatePiP: Bool = true) {
        contentScale = min(max(scale, GlassyTheme.pipScaleMinimum), GlassyTheme.pipScaleMaximum)
        applyPresetRenderSizes(restartPiPIfActive: invalidatePiP)
    }

    func setAspectRatio(_ aspect: PiPAspectRatio, invalidatePiP: Bool = true) {
        PiPDisplayLayerHost.setPreferredAspect(aspect)
        applyPresetRenderSizes(restartPiPIfActive: invalidatePiP, resetWindowToMinimum: true)
    }

    private func syncDisplayLayerFrame() {
        PiPDisplayLayerHost.updateScale(contentScale, displayLayer: displayLayer)
    }

    /// Ждём первый кадр в PiP-слое перед стартом (нельзя запустить PiP из фона).
    func waitForFirstFrame(timeout: TimeInterval = 3) async {
        if framePipeline.hasDeliveredFrame { return }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if framePipeline.hasDeliveredFrame { return }
            try? await Task.sleep(for: .milliseconds(33))
        }
    }

    func prepare(
        glassesService: GlassesOverlayService,
        mirrored: Bool,
        glassesEnabled: Bool,
        contentScale: CGFloat
    ) async throws {
        if isPrepared {
            stop()
        }
        self.glassesService = glassesService
        self.mirrored = mirrored
        self.glassesEnabled = glassesEnabled
        self.contentScale = min(max(contentScale, GlassyTheme.pipScaleMinimum), GlassyTheme.pipScaleMaximum)

        guard await requestCameraPermission() else {
            throw GlassyRecordError.permissionDenied("камере")
        }

        glassesService.stopTracking()
        glassesService.frameConsumer = nil
        try configureCaptureSession()
        configureAudioSession()
        installDisplayLayer()
        configurePictureInPicture()
        framePipeline.configure(
            contentScale: self.contentScale,
            glassesEnabled: glassesEnabled,
            glassesService: glassesEnabled ? glassesService : nil
        )
        applyPresetRenderSizes(resetWindowToMinimum: true)
        isPrepared = true
    }

    func startStreaming(startPiP: Bool = true) throws {
        guard isPrepared, !isStreaming else { return }
        guard isPictureInPictureSupported else {
            throw GlassyRecordError.screenRecordingFailed("Picture in Picture недоступен на этом устройстве")
        }

        isStreaming = true
        wantsPiPActive = startPiP
        pendingPiPActivation = startPiP
        beginBackgroundKeepAlive()
        startAudioKeepAliveIfAllowed()
        applyPresetRenderSizes(resetWindowToMinimum: true)
        installDisplayLayer()
        framePipeline.start()

        if glassesEnabled {
            glassesService?.startTrackingForPiP()
        }

        startCaptureSessionIfNeeded()

        if startPiP, framePipeline.hasDeliveredFrame {
            activatePiP()
        }
    }

    private func installDisplayLayer() {
        PiPDisplayLayerHost.install(displayLayer)
    }

    private func startCaptureSessionIfNeeded() {
        guard let captureSession, !captureSession.isRunning else { return }
        sessionQueue.async {
            captureSession.startRunning()
        }
    }

    func activatePiP() {
        guard isStreaming, wantsPiPActive else { return }
        guard pipController?.isPictureInPictureActive != true else { return }

        if !framePipeline.hasDeliveredFrame {
            pendingPiPActivation = true
            return
        }

        // PiP можно запустить только пока приложение ещё на экране.
        let appState = UIApplication.shared.applicationState
        guard appState == .active || appState == .inactive else {
            pendingPiPActivation = true
            return
        }

        pendingPiPActivation = false
        installDisplayLayer()
        pipController?.startPictureInPicture()
    }

    private func activatePiPIfPending() {
        guard pendingPiPActivation else { return }
        activatePiP()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        guard isStreaming else { return }
        switch phase {
        case .inactive:
            beginBackgroundKeepAlive()
            startAudioKeepAliveIfAllowed()
            installDisplayLayer()
            activatePiP()
            resumeCaptureIfNeeded()
        case .background:
            beginBackgroundKeepAlive()
            startAudioKeepAliveIfAllowed()
            installDisplayLayer()
            resumeCaptureIfNeeded()
        case .active:
            installDisplayLayer()
            rotationHandler?.refreshRotation()
            if wantsPiPActive, pipController?.isPictureInPictureActive != true {
                activatePiP()
            }
            resumeCaptureIfNeeded()
        @unknown default:
            break
        }
    }

    /// Освобождает аудиосессию main app, чтобы Control Center / ReplayKit сразу писали микрофон.
    func releaseAudioSessionForBroadcast() {
        suppressAudioKeepAliveForBroadcast = true
        audioKeepAlive.stop()
    }

    func restoreAudioSessionAfterBroadcast() {
        suppressAudioKeepAliveForBroadcast = false
        guard isStreaming else { return }
        startAudioKeepAliveIfAllowed()
    }

    private func startAudioKeepAliveIfAllowed() {
        guard !suppressAudioKeepAliveForBroadcast else { return }
        audioKeepAlive.start()
    }

    func stopStreaming() {
        isStreaming = false
        isPiPActive = false
        wantsPiPActive = false
        pendingPiPActivation = false
        pendingPiPRestartForScaleChange = false
        framePipeline.stop()
        pipController?.stopPictureInPicture()
        glassesService?.frameConsumer = nil
        glassesService?.stopTracking()
        suppressAudioKeepAliveForBroadcast = false
        audioKeepAlive.stop()
        endBackgroundKeepAlive()

        sessionQueue.async { [captureSession] in
            captureSession?.stopRunning()
        }
    }

    func stop() {
        stopStreaming()
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
            self.interruptionObserver = nil
        }
        if let interruptionEndedObserver {
            NotificationCenter.default.removeObserver(interruptionEndedObserver)
            self.interruptionEndedObserver = nil
        }
        captureSession = nil
        videoOutput = nil
        rotationHandler = nil
        captureDevice = nil
        pipController = nil
        isPrepared = false
        PiPSampleBufferFactory.reset()
        PiPDisplayLayerHost.detach(displayLayer)
    }

    // MARK: - Capture

    private func configureCaptureSession() throws {
        let session = AVCaptureSession()
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .vga640x480
        if session.isMultitaskingCameraAccessSupported {
            session.isMultitaskingCameraAccessEnabled = true
        }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            throw GlassyRecordError.cameraUnavailable
        }

        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)

        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw GlassyRecordError.cameraUnavailable
        }

        session.addInput(input)
        session.addOutput(output)

        if let connection = output.connection(with: .video) {
            captureDevice = device
            rotationHandler = CaptureRotationHandler(
                device: device,
                captureConnection: connection,
                previewLayer: rotationPreviewLayer,
                mirrored: mirrored
            )
            rotationHandler?.onRotationChanged = { [weak self] in
                self?.pipController?.invalidatePlaybackState()
            }
        }

        captureSession = session
        videoOutput = output
        rotationPreviewLayer.session = session
        observeCaptureInterruptions()
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(
            .playback,
            mode: .moviePlayback,
            options: [.mixWithOthers]
        )
        try? session.setActive(true)
    }

    private func configurePictureInPicture(forceRecreate: Bool = false) {
        guard isPictureInPictureSupported else { return }

        if forceRecreate {
            pipController?.delegate = nil
            pipController = nil
        }
        guard pipController == nil else { return }

        displayLayer.controlTimebase = nil

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        controller.delegate = self
        applyLiveFaceCamChrome(to: controller)
        pipController = controller
    }

    /// Face Cam — живой поток, не VOD: без skip ±10с, стопа и scrubber.
    private func applyLiveFaceCamChrome(to controller: AVPictureInPictureController) {
        if #available(iOS 14.0, *) {
            controller.requiresLinearPlayback = true
        }
        // Убирает progress bar / skip / play-pause у sample-buffer PiP (live камера).
        // Публичного API нет; значение 1 оставляют close + restore.
        controller.setValue(1, forKey: "controlsStyle")
    }

    private func observeCaptureInterruptions() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionWasInterrupted,
            object: captureSession,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            if let reason = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
               reason == AVCaptureSession.InterruptionReason.videoDeviceNotAvailableInBackground.rawValue {
                Task { @MainActor in
                    self.activatePiP()
                }
            }
        }

        interruptionEndedObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionInterruptionEnded,
            object: captureSession,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.resumeCaptureIfNeeded()
            }
        }
    }

    private func resumeCaptureIfNeeded() {
        guard isStreaming else { return }
        startCaptureSessionIfNeeded()
    }

    private func beginBackgroundKeepAlive() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask { [weak self] in
            Task { @MainActor in self?.endBackgroundKeepAlive() }
        }
    }

    private func endBackgroundKeepAlive() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    func requestPiPActive() {
        wantsPiPActive = true
        pendingPiPActivation = true
        activatePiP()
    }

    private func requestCameraPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension PiPCameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        framePipeline.process(pixelBuffer: pixelBuffer)
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension PiPCameraManager: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {}

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        Task { @MainActor [weak self] in
            self?.syncSourceLayerToSystemPiP(newRenderSize)
        }
    }

    private func syncSourceLayerToSystemPiP(_ dimensions: CMVideoDimensions) {
        guard !pendingPiPRestartForScaleChange, !shouldSuppressSystemRenderSizeSync else { return }

        let pointSize = PiPPixelGeometry.pointSizeForLayer(from: dimensions)
        let minSide = PiPDisplayLayerHost.minimumSide
        guard pointSize.width >= minSide - 1, pointSize.height >= minSide - 1 else { return }

        let current = PiPDisplayLayerHost.currentRenderSize
        let deltaW = abs(current.width - pointSize.width)
        let deltaH = abs(current.height - pointSize.height)
        guard deltaW > 2 || deltaH > 2 else { return }

        let pixelSize = PiPPixelGeometry.pixelSize(fromPoints: pointSize)
        PiPDisplayLayerHost.updateRenderSize(pointSize, displayLayer: displayLayer)
        framePipeline.setTargetRenderSize(pixelSize)

        displayLayer.flush()
        if #available(iOS 14.0, *), displayLayer.requiresFlushToResumeDecoding {
            displayLayer.flush()
        }
        PiPSampleBufferFactory.reset()
        pipController?.invalidatePlaybackState()
        PiPDisplayLayerHost.setSourceHidden(true)
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PiPCameraManager: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPiPActive = true
            if let controller = self.pipController {
                self.applyLiveFaceCamChrome(to: controller)
                controller.invalidatePlaybackState()
            }
            // Сразу разрешаем sync — иначе стартовый mismatch (широкое окно + узкий кадр) держит полосы.
            self.systemRenderSizeSyncSuppressedUntil = nil
            PiPDisplayLayerHost.setSourceHidden(true)
            UsageTracker.shared.track(.pipActivated)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPiPActive = false
            PiPDisplayLayerHost.setSourceHidden(true)

            if self.pendingPiPRestartForScaleChange {
                self.pendingPiPRestartForScaleChange = false
                guard self.isStreaming, self.wantsPiPActive else { return }
                self.configurePictureInPicture(forceRecreate: true)
                self.activatePiP()
                return
            }

            guard self.isStreaming, self.wantsPiPActive else { return }
            let state = UIApplication.shared.applicationState
            guard state == .active else {
                self.pendingPiPActivation = true
                return
            }
            self.activatePiP()
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPiPActive = false
            if self.pendingPiPRestartForScaleChange {
                self.pendingPiPRestartForScaleChange = false
                self.pendingPiPActivation = true
                self.configurePictureInPicture(forceRecreate: true)
                self.activatePiP()
            }
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}
