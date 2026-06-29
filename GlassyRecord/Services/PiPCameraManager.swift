@preconcurrency import AVFoundation
import ARKit
import AVKit
import Combine
import UIKit

/// Face Cam через системный PiP: кадры (с AR-очками) → AVSampleBufferDisplayLayer → запись экрана подхватывает окно.
@MainActor
final class PiPCameraManager: NSObject, ObservableObject {
    @Published private(set) var isPrepared = false
    @Published private(set) var isStreaming = false
    @Published private(set) var isPiPActive = false

    let displayLayer: AVSampleBufferDisplayLayer = {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspectFill
        return layer
    }()

    var isPictureInPictureSupported: Bool {
        AVPictureInPictureController.isPictureInPictureSupported()
    }

    private var pipController: AVPictureInPictureController?
    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private weak var glassesService: GlassesOverlayService?
    private var usesARKitSource = false
    private var mirrored = true
    private var streamStartTime = CMTime.zero
    private var frameIndex: Int64 = 0
    private let videoQueue = DispatchQueue(label: "com.glassyrecord.pip.video", qos: .userInitiated)

    func prepare(glassesService: GlassesOverlayService, mirrored: Bool, glassesEnabled: Bool) async throws {
        if isPrepared {
            stop()
        }
        self.glassesService = glassesService
        self.mirrored = mirrored
        self.usesARKitSource = glassesEnabled && glassesService.isARAvailable

        guard await requestCameraPermission() else {
            throw GlassyRecordError.permissionDenied("камере")
        }

        if usesARKitSource {
            glassesService.frameConsumer = { [weak self] pixelBuffer, time in
                self?.enqueueFrame(pixelBuffer, presentationTime: time)
            }
        } else {
            glassesService.frameConsumer = nil
            try configureCaptureSession()
        }

        configurePictureInPicture()
        isPrepared = true
    }

    func startStreaming(startPiP: Bool = true) throws {
        guard isPrepared, !isStreaming else { return }
        guard isPictureInPictureSupported else {
            throw GlassyRecordError.screenRecordingFailed("Picture in Picture недоступен на этом устройстве")
        }

        streamStartTime = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600)
        frameIndex = 0
        isStreaming = true

        if usesARKitSource {
            glassesService?.startTracking()
        } else if let captureSession, !captureSession.isRunning {
            videoQueue.async { captureSession.startRunning() }
        }

        if startPiP, pipController?.isPictureInPictureActive != true {
            pipController?.startPictureInPicture()
        }
    }

    func activatePiP() {
        guard isStreaming, pipController?.isPictureInPictureActive != true else { return }
        pipController?.startPictureInPicture()
    }

    func stopStreaming() {
        isStreaming = false
        isPiPActive = false
        pipController?.stopPictureInPicture()
        glassesService?.frameConsumer = nil
        glassesService?.stopTracking()

        if let captureSession, captureSession.isRunning {
            videoQueue.async { captureSession.stopRunning() }
        }
    }

    func stop() {
        stopStreaming()
        captureSession = nil
        videoOutput = nil
        pipController = nil
        isPrepared = false
        displayLayer.flushAndRemoveImage()
    }

    // MARK: - Capture

    private func configureCaptureSession() throws {
        let session = AVCaptureSession()
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .vga640x480

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
            connection.isVideoMirrored = mirrored
            CaptureConnectionSupport.applyPortrait(to: connection)
        }

        captureSession = session
        videoOutput = output
    }

    private func configurePictureInPicture() {
        guard pipController == nil, isPictureInPictureSupported else { return }

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.delegate = self
        pipController = controller
    }

    fileprivate func enqueueFrame(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime? = nil) {
        guard isStreaming else { return }

        let processed: CVPixelBuffer
        if let glassesService, glassesService.isEnabled {
            processed = glassesService.processFrame(pixelBuffer)
        } else {
            processed = pixelBuffer
        }

        let pts = presentationTime ?? CMTimeAdd(
            streamStartTime,
            CMTime(value: frameIndex, timescale: 30)
        )
        frameIndex += 1

        guard let sample = PiPSampleBufferFactory.makeSampleBuffer(from: processed, presentationTime: pts) else {
            return
        }

        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sample)
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
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        Task { @MainActor [weak self] in
            self?.enqueueFrame(pixelBuffer, presentationTime: pts)
        }
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
    ) {}
}

// MARK: - AVPictureInPictureControllerDelegate

extension PiPCameraManager: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor [weak self] in
            self?.isPiPActive = true
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor [weak self] in
            self?.isPiPActive = false
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            self?.isPiPActive = false
        }
    }
}
