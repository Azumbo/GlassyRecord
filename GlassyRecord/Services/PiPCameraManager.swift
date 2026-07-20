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
    private var ignoresSystemRenderSizeSync = false
    private var wantsPiPActive = false
    private let audioKeepAlive = PiPAudioKeepAlive()

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
    private func applyPresetRenderSizes(restartPiPIfActive: Bool = false) {
        // Размер буфера/source layer фиксированный — iOS PiP иначе игнорирует «размер окна».
        // Крупность = цифровой зум в PiPFrameScaler (оба слоя получают один и тот же кадр).
        ignoresSystemRenderSizeSync = true
        let pointSize = PiPDisplayLayerHost.baseRenderSize
        let pixelSize = PiPPixelGeometry.pixelSize(fromPoints: pointSize)
        framePipeline.setTargetRenderSize(pixelSize)
        PiPDisplayLayerHost.updateScale(1.0, displayLayer: displayLayer)

        // Сброс очереди кадров, чтобы новый зум сразу был виден в системном PiP.
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

    func setContentScale(_ scale: CGFloat, invalidatePiP: Bool = true) {
        contentScale = min(max(scale, GlassyTheme.pipScaleMinimum), GlassyTheme.pipScaleMaximum)
        ignoresSystemRenderSizeSync = true
        applyPresetRenderSizes(restartPiPIfActive: invalidatePiP)
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
        applyPresetRenderSizes()
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
        audioKeepAlive.start()
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
            audioKeepAlive.start()
            installDisplayLayer()
            activatePiP()
            resumeCaptureIfNeeded()
        case .background:
            beginBackgroundKeepAlive()
            audioKeepAlive.start()
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
            .playAndRecord,
            mode: .videoChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers]
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
        if #available(iOS 14.0, *) {
            controller.requiresLinearPlayback = true
        }
        controller.delegate = self
        pipController = controller
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
        // Крупность = цифровой зум в фиксированном буфере. Не подстраиваем target size
        // под окно iOS — иначе превью и системный PiP снова разъедутся.
        guard !pendingPiPRestartForScaleChange, !ignoresSystemRenderSizeSync else { return }
        PiPDisplayLayerHost.setSourceHidden(true)
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension PiPCameraManager: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor [weak self] in
            self?.isPiPActive = true
            // Не сбрасываем ignoresSystemRenderSizeSync сразу — иначе iOS откатит пресет.
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
