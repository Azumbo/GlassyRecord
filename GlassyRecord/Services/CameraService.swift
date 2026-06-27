import AVFoundation
import Combine
import SwiftUI
import UIKit

/// Захват видео с фронтальной камеры через AVFoundation.
/// На симуляторе автоматически переключается на `MockCameraFeed`.
@MainActor
final class CameraService: NSObject, ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isSimulatorMode = SimulatorSupport.isRunning
    @Published private(set) var latestPixelBuffer: CVPixelBuffer?
    @Published var error: GlassyRecordError?

    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.glassyrecord.camera", qos: .userInitiated)
    private var continuationBuffer: ((CVPixelBuffer) -> Void)?
    private let mockFeed = MockCameraFeed()

    override init() {
        super.init()
    }

    func configure(quality: RecordingQuality, mirrored: Bool) async throws {
        if SimulatorSupport.isRunning {
            isSimulatorMode = true
            return
        }

        guard await requestCameraPermission() else {
            throw GlassyRecordError.permissionDenied("камере")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                do {
                    try self.setupSession(quality: quality, mirrored: mirrored)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
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

        sessionQueue.async { [weak self] in
            guard let self, !self.session.isRunning else { return }
            self.session.startRunning()
            Task { @MainActor in self.isRunning = true }
        }
    }

    func stop() {
        if isSimulatorMode {
            mockFeed.stop()
            isRunning = false
            latestPixelBuffer = nil
            return
        }

        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            Task { @MainActor in
                self.isRunning = false
                self.latestPixelBuffer = nil
            }
        }
    }

    func onFrame(_ handler: @escaping (CVPixelBuffer) -> Void) {
        continuationBuffer = handler
    }

    private func setupSession(quality: RecordingQuality, mirrored: Bool) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        session.sessionPreset = quality == .uhd4K ? .hd4K3840x2160 : .hd1920x1080

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
        videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)

        guard session.canAddOutput(videoOutput) else { throw GlassyRecordError.cameraUnavailable }
        session.addOutput(videoOutput)

        if let connection = videoOutput.connection(with: .video) {
            connection.isVideoMirrored = mirrored
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }

        try configureFrameRate(device: device, fps: quality.preferredFPS)
    }

    private func configureFrameRate(device: AVCaptureDevice, fps: Int) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        let target = Double(min(fps, 120))
        if let range = device.activeFormat.videoSupportedFrameRateRanges.first(where: {
            $0.maxFrameRate >= target
        }) {
            let clamped = min(target, range.maxFrameRate)
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(clamped))
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(clamped))
        }
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
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.latestPixelBuffer = boxed.value
            self.continuationBuffer?(boxed.value)
        }
    }
}

/// CVPixelBuffer не Sendable в Swift 6; обёртка для передачи между потоками захвата и UI.
private struct UncheckedSendablePixelBuffer: @unchecked Sendable {
    let value: CVPixelBuffer
}

/// UIViewRepresentable для превью камеры.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
