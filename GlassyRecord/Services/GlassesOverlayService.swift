import ARKit
import AVFoundation
import Combine
import SceneKit
import UIKit

/// Состояние трекинга лица для наложения очков.
struct FaceTrackingState: Equatable {
    var isTracking: Bool = false
    var headTransform: simd_float4x4 = matrix_identity_float4x4
    var leftEyeTransform: simd_float4x4 = matrix_identity_float4x4
    var rightEyeTransform: simd_float4x4 = matrix_identity_float4x4
    var blendShapes: [ARFaceAnchor.BlendShapeLocation: NSNumber] = [:]
}

/// Сервис наложения 3D-очков Monokol MK295 на видеопоток.
///
/// Vision + SceneKit выполняются на `renderQueue`; `@MainActor` только у UI-свойств.
final class GlassesOverlayService: NSObject, ObservableObject {
    @MainActor @Published private(set) var isEnabled = false
    @MainActor @Published private(set) var frameColor: GlassesFrameColor = .red
    @MainActor @Published var lensTransparency: Float = 0.85
    @MainActor @Published var frameBrightness: Float = 1.0
    @MainActor @Published private(set) var trackingState = FaceTrackingState()
    @MainActor @Published private(set) var isARAvailable: Bool
    @MainActor @Published var error: GlassyRecordError?

    private let renderQueue = DispatchQueue(label: "com.glassyrecord.glasses", qos: .userInitiated)
    private let frameProcessor = GlassesFrameProcessor()

    @MainActor private let arSession = ARSession()
    @MainActor private var useVisionFallback: Bool

    /// Потребитель кадров для PiP (ARKit как источник камеры).
    @MainActor var frameConsumer: ((CVPixelBuffer, CMTime) -> Void)?

    @MainActor
    override init() {
        isARAvailable = ARFaceTrackingConfiguration.isSupported
        useVisionFallback = !ARFaceTrackingConfiguration.isSupported
        super.init()
        syncProcessorConfiguration()
    }

    // MARK: - Public API

    @MainActor
    func setEnabled(_ enabled: Bool, usesPiPCapture: Bool = false) {
        isEnabled = enabled
        frameProcessor.setEnabled(enabled)
        if !enabled {
            stopTracking()
        } else if !usesPiPCapture {
            startTracking()
        }
    }

    @MainActor
    func setFrameColor(_ color: GlassesFrameColor) {
        guard frameColor != color else { return }
        frameColor = color
        frameProcessor.setFrameColor(color)
    }

    @MainActor
    func startTracking() {
        guard isEnabled else { return }

        if isARAvailable {
            startARTracking()
        } else {
            useVisionFallback = true
            frameProcessor.setVisionFallbackMode()
        }
    }

    /// PiP + AVCapture: ARKit не работает в фоне, очки накладываем через Vision на каждый кадр.
    @MainActor
    func startTrackingForPiP() {
        guard isEnabled else { return }
        arSession.pause()
        useVisionFallback = true
        trackingState = FaceTrackingState()
        frameProcessor.setVisionFallbackMode()
    }

    @MainActor
    func stopTracking() {
        arSession.pause()
        trackingState = FaceTrackingState()
        frameProcessor.resetTracking()
    }

    /// Накладывает очки на кадр. Vision + SceneKit выполняются синхронно на `renderQueue`.
    nonisolated func processFrame(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer {
        renderQueue.sync {
            frameProcessor.processFrame(pixelBuffer)
        }
    }

    // MARK: - ARKit

    @MainActor
    private func startARTracking() {
        guard ARFaceTrackingConfiguration.isSupported else {
            error = .faceTrackingUnavailable
            useVisionFallback = true
            frameProcessor.setVisionFallbackMode()
            return
        }

        useVisionFallback = false

        let config = ARFaceTrackingConfiguration()
        config.isLightEstimationEnabled = true
        config.maximumNumberOfTrackedFaces = 1

        arSession.delegate = self
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    @MainActor
    func setLensTransparency(_ value: Float) {
        lensTransparency = value
        frameProcessor.setLensTransparency(value)
    }

    @MainActor
    func setFrameBrightness(_ value: Float) {
        frameBrightness = value
        frameProcessor.setFrameBrightness(value)
    }

    @MainActor
    func updateLensTransparency() {
        frameProcessor.setLensTransparency(lensTransparency)
    }

    @MainActor
    func updateFrameBrightness() {
        frameProcessor.setFrameBrightness(frameBrightness)
    }

    @MainActor
    private func syncProcessorConfiguration() {
        frameProcessor.setEnabled(isEnabled)
        frameProcessor.setFrameColor(frameColor)
        frameProcessor.setLensTransparency(lensTransparency)
        frameProcessor.setFrameBrightness(frameBrightness)
        if useVisionFallback {
            frameProcessor.setVisionFallbackMode()
        }
    }

    // MARK: - Procedural Monokol MK295 Model

    /// Создаёт кубическую геометрическую оправу Monokol MK295 из ацетата.
    nonisolated static func buildMonokolMK295(
        color: GlassesFrameColor,
        brightness: Float,
        lensTransparency: Float = 0.85
    ) -> SCNNode {
        let root = SCNNode()
        root.name = "MonokolMK295"

        let frameUIColor: UIColor = {
            let base: UIColor = color == .red
                ? UIColor(red: 0.77, green: 0.12, blue: 0.16, alpha: 1)
                : UIColor(red: 0.10, green: 0.28, blue: 0.72, alpha: 1)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            base.getRed(&r, green: &g, blue: &b, alpha: &a)
            let m = CGFloat(brightness)
            return UIColor(red: min(1, r * m), green: min(1, g * m), blue: min(1, b * m), alpha: a)
        }()

        let acetateMaterial = SCNMaterial()
        acetateMaterial.name = "acetate"
        acetateMaterial.diffuse.contents = frameUIColor
        acetateMaterial.metalness.contents = 0.15
        acetateMaterial.roughness.contents = 0.12
        acetateMaterial.lightingModel = .physicallyBased

        let clearness = CGFloat(max(0, min(1, lensTransparency)))
        let lensMaterial = SCNMaterial()
        lensMaterial.name = "lens"
        lensMaterial.lightingModel = .constant
        lensMaterial.diffuse.contents = UIColor.black.withAlphaComponent(0.05 + (1 - clearness) * 0.55)
        lensMaterial.transparency = 1 - clearness
        lensMaterial.writesToDepthBuffer = false
        lensMaterial.readsFromDepthBuffer = false

        let rightLensMaterial = SCNMaterial()
        rightLensMaterial.name = "lens"
        rightLensMaterial.lightingModel = .constant
        rightLensMaterial.diffuse.contents = UIColor.black.withAlphaComponent(0.05 + (1 - clearness) * 0.55)
        rightLensMaterial.transparency = 1 - clearness
        rightLensMaterial.writesToDepthBuffer = false
        rightLensMaterial.readsFromDepthBuffer = false

        let frameThickness: CGFloat = 0.004
        let lensWidth: CGFloat = 0.034
        let lensHeight: CGFloat = 0.028
        let bridgeWidth: CGFloat = 0.008
        let templeLength: CGFloat = 0.06

        let leftFrame = SCNNode(geometry: SCNBox(
            width: lensWidth + frameThickness * 2,
            height: lensHeight + frameThickness * 2,
            length: frameThickness,
            chamferRadius: 0
        ))
        leftFrame.geometry?.materials = [acetateMaterial]
        leftFrame.position = SCNVector3(-(lensWidth / 2 + bridgeWidth / 2 + frameThickness), 0.01, 0.02)
        root.addChildNode(leftFrame)

        let rightFrame = SCNNode(geometry: SCNBox(
            width: lensWidth + frameThickness * 2,
            height: lensHeight + frameThickness * 2,
            length: frameThickness,
            chamferRadius: 0
        ))
        rightFrame.geometry?.materials = [acetateMaterial]
        rightFrame.position = SCNVector3(lensWidth / 2 + bridgeWidth / 2 + frameThickness, 0.01, 0.02)
        root.addChildNode(rightFrame)

        let leftLens = SCNNode(geometry: SCNBox(width: lensWidth, height: lensHeight, length: 0.001, chamferRadius: 0))
        leftLens.name = "leftLens"
        leftLens.geometry?.materials = [lensMaterial]
        leftLens.position = SCNVector3(leftFrame.position.x, leftFrame.position.y, leftFrame.position.z + 0.002)
        root.addChildNode(leftLens)

        let rightLens = SCNNode(geometry: SCNBox(width: lensWidth, height: lensHeight, length: 0.001, chamferRadius: 0))
        rightLens.name = "rightLens"
        rightLens.geometry?.materials = [rightLensMaterial]
        rightLens.position = SCNVector3(rightFrame.position.x, rightFrame.position.y, rightFrame.position.z + 0.002)
        root.addChildNode(rightLens)

        let bridge = SCNNode(geometry: SCNBox(width: bridgeWidth, height: frameThickness * 1.5, length: frameThickness, chamferRadius: 0))
        bridge.geometry?.materials = [acetateMaterial]
        bridge.position = SCNVector3(0, 0.01, 0.02)
        root.addChildNode(bridge)

        let leftTemple = SCNNode(geometry: SCNBox(width: templeLength, height: frameThickness, length: frameThickness * 0.8, chamferRadius: 0))
        leftTemple.geometry?.materials = [acetateMaterial]
        leftTemple.position = SCNVector3(-(lensWidth + bridgeWidth / 2 + frameThickness + templeLength / 2), 0.01, -0.01)
        leftTemple.eulerAngles = SCNVector3(0, Float.pi / 2.5, 0)
        root.addChildNode(leftTemple)

        let rightTemple = SCNNode(geometry: SCNBox(width: templeLength, height: frameThickness, length: frameThickness * 0.8, chamferRadius: 0))
        rightTemple.geometry?.materials = [acetateMaterial]
        rightTemple.position = SCNVector3(lensWidth + bridgeWidth / 2 + frameThickness + templeLength / 2, 0.01, -0.01)
        rightTemple.eulerAngles = SCNVector3(0, -Float.pi / 2.5, 0)
        root.addChildNode(rightTemple)

        root.scale = SCNVector3(1.1, 1.1, 1.1)
        return root
    }
}

// MARK: - ARSessionDelegate

extension GlassesOverlayService: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let pixelBuffer = frame.capturedImage
        let time = CMTime(seconds: frame.timestamp, preferredTimescale: 1_000_000_000)

        Task { @MainActor [weak self] in
            self?.frameConsumer?(pixelBuffer, time)
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let faceAnchor = anchors.compactMap({ $0 as? ARFaceAnchor }).first else { return }

        var state = FaceTrackingState()
        state.isTracking = true
        state.headTransform = faceAnchor.transform
        state.blendShapes = faceAnchor.blendShapes

        frameProcessor.updateTrackingState(state)

        Task { @MainActor [weak self] in
            self?.trackingState = state
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        frameProcessor.setVisionFallbackMode()
        Task { @MainActor [weak self] in
            self?.error = .arSessionFailed(error.localizedDescription)
            self?.useVisionFallback = true
        }
    }
}
