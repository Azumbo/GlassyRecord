import AVFoundation
import UIKit

enum CaptureConnectionSupport {
    static func currentInterfaceOrientation() -> UIInterfaceOrientation {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive })?
            .interfaceOrientation
            ?? .portrait
    }

    static func videoOrientation(from interfaceOrientation: UIInterfaceOrientation) -> AVCaptureVideoOrientation {
        switch interfaceOrientation {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        default: .portrait
        }
    }

    static func applyCurrentOrientation(to connection: AVCaptureConnection) {
        if #available(iOS 17.0, *) {
            return
        }
        guard connection.isVideoOrientationSupported else { return }
        connection.videoOrientation = videoOrientation(from: currentInterfaceOrientation())
    }
}

/// Синхронизирует поворот превью и PiP-кадров при повороте iPhone (portrait / landscape left / right).
@MainActor
final class CaptureRotationHandler {
    private let device: AVCaptureDevice
    private weak var captureConnection: AVCaptureConnection?
    private weak var previewLayer: AVCaptureVideoPreviewLayer?
    private let mirrored: Bool
    private var rotationCoordinator: Any?
    private var captureObservation: NSKeyValueObservation?
    private var previewObservation: NSKeyValueObservation?
    private var orientationObserver: NSObjectProtocol?
    var onRotationChanged: (() -> Void)?

    init(
        device: AVCaptureDevice,
        captureConnection: AVCaptureConnection?,
        previewLayer: AVCaptureVideoPreviewLayer? = nil,
        mirrored: Bool = true
    ) {
        self.device = device
        self.captureConnection = captureConnection
        self.previewLayer = previewLayer
        self.mirrored = mirrored
        applyMirroring()
        startObservingRotation()
    }

    func setPreviewLayer(_ layer: AVCaptureVideoPreviewLayer?) {
        guard previewLayer !== layer else { return }
        previewLayer = layer
        applyMirroring()
        restartCoordinator()
    }

    func refreshRotation() {
        if #available(iOS 17.0, *), let coordinator = rotationCoordinator as? AVCaptureDevice.RotationCoordinator {
            applyCaptureRotation(coordinator.videoRotationAngleForHorizonLevelCapture)
            applyPreviewRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
        } else {
            applyLegacyOrientation()
        }
    }

    private func startObservingRotation() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        restartCoordinator()
    }

    private func restartCoordinator() {
        captureObservation?.invalidate()
        previewObservation?.invalidate()
        if let orientationObserver {
            NotificationCenter.default.removeObserver(orientationObserver)
            self.orientationObserver = nil
        }
        rotationCoordinator = nil

        if #available(iOS 17.0, *) {
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            rotationCoordinator = coordinator

            captureObservation = coordinator.observe(
                \.videoRotationAngleForHorizonLevelCapture,
                options: [.initial, .new]
            ) { [weak self] coordinator, _ in
                Task { @MainActor in
                    self?.applyCaptureRotation(coordinator.videoRotationAngleForHorizonLevelCapture)
                }
            }

            previewObservation = coordinator.observe(
                \.videoRotationAngleForHorizonLevelPreview,
                options: [.initial, .new]
            ) { [weak self] coordinator, _ in
                Task { @MainActor in
                    self?.applyPreviewRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
                }
            }
        } else {
            applyLegacyOrientation()
            orientationObserver = NotificationCenter.default.addObserver(
                forName: UIDevice.orientationDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.applyLegacyOrientation() }
            }
        }
    }

    @available(iOS 17.0, *)
    private func applyCaptureRotation(_ angle: CGFloat) {
        guard let connection = captureConnection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
        onRotationChanged?()
    }

    @available(iOS 17.0, *)
    private func applyPreviewRotation(_ angle: CGFloat) {
        guard let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    private func applyLegacyOrientation() {
        let orientation = CaptureConnectionSupport.currentInterfaceOrientation()
        if let connection = captureConnection, connection.isVideoOrientationSupported {
            connection.videoOrientation = CaptureConnectionSupport.videoOrientation(from: orientation)
        }
        if let connection = previewLayer?.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = CaptureConnectionSupport.videoOrientation(from: orientation)
        }
        onRotationChanged?()
    }

    private func applyMirroring() {
        if let connection = captureConnection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
        if let connection = previewLayer?.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }
}
