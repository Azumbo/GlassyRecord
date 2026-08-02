@preconcurrency import AVFoundation
import Combine
import SwiftUI
import UIKit

/// Контекст захвата для работы на `sessionQueue` (вне MainActor).
private struct CameraSessionContext: @unchecked Sendable {
    let session: AVCaptureSession
    let videoOutput: AVCaptureVideoDataOutput
}

/// Конфигурация AVCaptureSession — только на sessionQueue.
private enum CameraSessionConfigurator {
    static func setup(
        context: CameraSessionContext,
        delegate: AVCaptureVideoDataOutputSampleBufferDelegate,
        queue: DispatchQueue,
        quality: RecordingQuality,
        mirrored: Bool
    ) throws -> AVCaptureDevice {
        let session = context.session
        let videoOutput = context.videoOutput

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.sessionPreset = .hd1280x720

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            throw GlassyRecordError.cameraUnavailable
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw GlassyRecordError.cameraUnavailable }
        session.addInput(input)

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(delegate, queue: queue)

        guard session.canAddOutput(videoOutput) else { throw GlassyRecordError.cameraUnavailable }
        session.addOutput(videoOutput)

        if let connection = videoOutput.connection(with: .video) {
            // Поворот задаёт CaptureRotationHandler после setup (MainActor).
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = mirrored
            }
        }

        try configureFrameRate(device: device, fps: min(quality.preferredFPS, 30))
        return device
    }

    private static func configureFrameRate(device: AVCaptureDevice, fps: Int) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        let target = Double(fps)
        if let range = device.activeFormat.videoSupportedFrameRateRanges.first(where: {
            $0.maxFrameRate >= target
        }) {
            let clamped = min(target, range.maxFrameRate)
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(clamped))
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(clamped))
        }
    }
}

/// Захват видео с фронтальной камеры через AVFoundation.
/// На симуляторе автоматически переключается на `MockCameraFeed`.
@MainActor
final class CameraService: NSObject, ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isSimulatorMode = SimulatorSupport.isRunning
    @Published private(set) var latestPixelBuffer: CVPixelBuffer?
    @Published var error: GlassyRecordError?

    nonisolated(unsafe) let session = AVCaptureSession()
    nonisolated(unsafe) private let videoOutput = AVCaptureVideoDataOutput()
    nonisolated private let sessionQueue = DispatchQueue(label: "com.glassyrecord.camera", qos: .userInitiated)
    nonisolated(unsafe) private var continuationBuffer: ((CVPixelBuffer) -> Void)?
    private let mockFeed = MockCameraFeed()
    private var rotationHandler: CaptureRotationHandler?
    private(set) var captureDevice: AVCaptureDevice?
    private var mirrored = true

    func configure(quality: RecordingQuality, mirrored: Bool) async throws {
        if SimulatorSupport.isRunning {
            isSimulatorMode = true
            return
        }

        guard await requestCameraPermission() else {
            throw GlassyRecordError.permissionDenied(L10n.t("permission.camera"))
        }

        self.mirrored = mirrored
        let ctx = CameraSessionContext(session: session, videoOutput: videoOutput)
        let queue = sessionQueue

        let device: AVCaptureDevice = try await withThrowingTaskGroup(of: AVCaptureDevice.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<AVCaptureDevice, Error>) in
                    queue.async {
                        do {
                            let configuredDevice = try CameraSessionConfigurator.setup(
                                context: ctx,
                                delegate: self,
                                queue: queue,
                                quality: quality,
                                mirrored: mirrored
                            )
                            continuation.resume(returning: configuredDevice)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw GlassyRecordError.cameraUnavailable
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        captureDevice = device
        rotationHandler = CaptureRotationHandler(
            device: device,
            captureConnection: videoOutput.connection(with: .video),
            mirrored: mirrored
        )
    }

    func bindPreviewLayer(_ layer: AVCaptureVideoPreviewLayer?) {
        rotationHandler?.setPreviewLayer(layer)
    }

    func refreshRotation() {
        rotationHandler?.refreshRotation()
    }

    func start() {
        if isSimulatorMode {
            mockFeed.onFrame { [weak self] buffer in
                guard let self else { return }
                self.latestPixelBuffer = buffer
                self.continuationBuffer?(buffer)
            }
            mockFeed.start()
            isRunning = true
            return
        }

        let ctx = CameraSessionContext(session: session, videoOutput: videoOutput)
        sessionQueue.async {
            guard !ctx.session.isRunning else { return }
            ctx.session.startRunning()
            Task { @MainActor [weak self] in self?.isRunning = true }
        }
    }

    func stop() {
        if isSimulatorMode {
            mockFeed.stop()
            isRunning = false
            latestPixelBuffer = nil
            return
        }

        let ctx = CameraSessionContext(session: session, videoOutput: videoOutput)
        sessionQueue.async {
            guard ctx.session.isRunning else { return }
            ctx.session.stopRunning()
            Task { @MainActor [weak self] in
                self?.isRunning = false
                self?.latestPixelBuffer = nil
            }
        }
        rotationHandler = nil
        captureDevice = nil
    }

    func onFrame(_ handler: @escaping (CVPixelBuffer) -> Void) {
        continuationBuffer = handler
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

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let boxed = UncheckedSendablePixelBuffer(value: pixelBuffer)
        continuationBuffer?(boxed.value)
        Task { @MainActor [weak self] in
            self?.latestPixelBuffer = boxed.value
        }
    }
}

private struct UncheckedSendablePixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    var captureDevice: AVCaptureDevice?
    var mirrored: Bool = true
    var onPreviewLayerReady: ((AVCaptureVideoPreviewLayer) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onPreviewLayerReady: onPreviewLayerReady)
    }

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        if let connection = view.previewLayer.connection {
            connection.isEnabled = true
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = mirrored
            }
        }
        context.coordinator.bind(layer: view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        if let connection = uiView.previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
        context.coordinator.onPreviewLayerReady = onPreviewLayerReady
        context.coordinator.bind(layer: uiView.previewLayer)
    }

    final class Coordinator {
        var onPreviewLayerReady: ((AVCaptureVideoPreviewLayer) -> Void)?
        private weak var boundLayer: AVCaptureVideoPreviewLayer?

        init(onPreviewLayerReady: ((AVCaptureVideoPreviewLayer) -> Void)?) {
            self.onPreviewLayerReady = onPreviewLayerReady
        }

        func bind(layer: AVCaptureVideoPreviewLayer) {
            guard boundLayer !== layer else {
                onPreviewLayerReady?(layer)
                return
            }
            boundLayer = layer
            onPreviewLayerReady?(layer)
        }
    }
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
