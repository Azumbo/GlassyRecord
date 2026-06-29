import ARKit
import AVFoundation
import Combine
import SceneKit
import Vision
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
/// **Выбор подхода:** ARKit `ARFaceTrackingConfiguration` — основной путь на устройствах
/// с TrueDepth (точная 3D-геометрия лица, blend shapes). Vision `VNDetectFaceLandmarksRequest`
/// — fallback на устройствах без TrueDepth (менее точный, но работает на iOS 18+).
///
/// **Альтернатива:** RealityKit + `BodyTrackedEntity` — проще для USDZ, но тяжелее
/// для кастомного рендера в CVPixelBuffer. SceneKit + ARSCNFaceGeometry даёт
/// лучший контроль над композицией с AVFoundation.
@MainActor
final class GlassesOverlayService: NSObject, ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var frameColor: GlassesFrameColor = .red
    @Published var lensTransparency: Float = 0.85
    @Published var frameBrightness: Float = 1.0
    @Published private(set) var trackingState = FaceTrackingState()
    @Published private(set) var isARAvailable: Bool
    @Published var error: GlassyRecordError?

    private let arSession = ARSession()
    private var sceneRenderer: SCNRenderer?
    private let scene = SCNScene()
    private var glassesNode: SCNNode?
    private var faceNode: SCNNode?
    private var currentGlassesColor: GlassesFrameColor?

    // Vision fallback
    private var visionSequenceHandler = VNSequenceRequestHandler()
    private var useVisionFallback: Bool

    // Кэш процедурных моделей
    private var redGlassesNode: SCNNode?
    private var blueGlassesNode: SCNNode?

    private let renderSize = CGSize(width: 640, height: 480)

    /// Потребитель кадров для PiP (ARKit как источник камеры).
    var frameConsumer: ((CVPixelBuffer, CMTime) -> Void)?

    override init() {
        isARAvailable = ARFaceTrackingConfiguration.isSupported
        useVisionFallback = !ARFaceTrackingConfiguration.isSupported
        super.init()
        setupScene()
    }

    // MARK: - Public API

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            startTracking()
        } else {
            stopTracking()
        }
    }

    func setFrameColor(_ color: GlassesFrameColor) {
        guard frameColor != color else { return }
        frameColor = color
        swapGlassesModel(to: color)
    }

    func startTracking() {
        guard isEnabled else { return }

        if isARAvailable {
            startARTracking()
        } else {
            useVisionFallback = true
        }
    }

    func stopTracking() {
        arSession.pause()
        trackingState = FaceTrackingState()
    }

    /// Накладывает очки на кадр с камеры. Возвращает новый pixel buffer или исходный.
    func processFrame(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer {
        guard isEnabled, trackingState.isTracking else { return pixelBuffer }

        if useVisionFallback {
            processWithVision(pixelBuffer)
        }

        return renderGlassesOntoBuffer(pixelBuffer) ?? pixelBuffer
    }

    // MARK: - ARKit

    private func startARTracking() {
        guard ARFaceTrackingConfiguration.isSupported else {
            error = .faceTrackingUnavailable
            useVisionFallback = true
            return
        }

        let config = ARFaceTrackingConfiguration()
        config.isLightEstimationEnabled = true
        config.maximumNumberOfTrackedFaces = 1

        arSession.delegate = self
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    private func setupScene() {
        sceneRenderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        sceneRenderer?.scene = scene
        sceneRenderer?.autoenablesDefaultLighting = true

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.position = SCNVector3(0, 0, 0)
        scene.rootNode.addChildNode(cameraNode)
        sceneRenderer?.pointOfView = cameraNode

        // Процедурные модели Monokol MK295
        redGlassesNode = Self.buildMonokolMK295(color: .red, brightness: frameBrightness)
        blueGlassesNode = Self.buildMonokolMK295(color: .blue, brightness: frameBrightness)

        swapGlassesModel(to: frameColor)
    }

    private func swapGlassesModel(to color: GlassesFrameColor) {
        glassesNode?.removeFromParentNode()

        let node: SCNNode?
        switch color {
        case .red: node = redGlassesNode?.clone()
        case .blue: node = blueGlassesNode?.clone()
        }

        guard let node else { return }
        node.name = "glasses"
        glassesNode = node

        if let faceNode {
            faceNode.addChildNode(node)
        } else {
            scene.rootNode.addChildNode(node)
        }
        currentGlassesColor = color
        updateLensTransparency()
        updateFrameBrightness()
    }

    func updateLensTransparency() {
        glassesNode?.childNode(withName: "leftLens", recursively: true)?
            .geometry?.firstMaterial?.transparent.contents = NSNumber(value: lensTransparency)
        glassesNode?.childNode(withName: "rightLens", recursively: true)?
            .geometry?.firstMaterial?.transparent.contents = NSNumber(value: lensTransparency)
    }

    func updateFrameBrightness() {
        let multiplier = CGFloat(frameBrightness)
        glassesNode?.enumerateChildNodes { node, _ in
            guard let material = node.geometry?.firstMaterial,
                  material.name == "acetate" else { return }
            if let color = material.diffuse.contents as? UIColor {
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                color.getRed(&r, green: &g, blue: &b, alpha: &a)
                material.diffuse.contents = UIColor(
                    red: min(1, r * multiplier),
                    green: min(1, g * multiplier),
                    blue: min(1, b * multiplier),
                    alpha: a
                )
            }
        }
    }

    // MARK: - Vision Fallback

    private func processWithVision(_ pixelBuffer: CVPixelBuffer) {
        let request = VNDetectFaceLandmarksRequest()
        try? visionSequenceHandler.perform([request], on: pixelBuffer)

        guard let observation = request.results?.first as? VNFaceObservation,
              let landmarks = observation.landmarks else { return }

        trackingState.isTracking = true

        // Приблизительное позиционирование по landmarks
        let bbox = observation.boundingBox
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4<Float>(
            Float(bbox.midX - 0.5) * 2,
            Float(bbox.midY - 0.5) * 2,
            -0.3,
            1
        )

        let scale = Float(bbox.width) * 1.8
        transform.columns.0.x = scale
        transform.columns.1.y = scale
        transform.columns.2.z = scale

        trackingState.headTransform = transform

        if let leftEye = landmarks.leftEye, let rightEye = landmarks.rightEye {
            trackingState.leftEyeTransform = eyeTransform(from: leftEye, in: bbox)
            trackingState.rightEyeTransform = eyeTransform(from: rightEye, in: bbox)
        }

        glassesNode?.simdTransform = transform
    }

    private func eyeTransform(from region: VNFaceLandmarkRegion2D, in bbox: CGRect) -> simd_float4x4 {
        let points = region.normalizedPoints
        guard !points.isEmpty else { return matrix_identity_float4x4 }

        let center = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        let avg = CGPoint(x: center.x / CGFloat(points.count), y: center.y / CGFloat(points.count))

        var t = matrix_identity_float4x4
        t.columns.3 = SIMD4<Float>(Float(avg.x), Float(avg.y), 0, 1)
        return t
    }

    // MARK: - Rendering

    private func renderGlassesOntoBuffer(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard let renderer = sceneRenderer, let glassesNode else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Обновляем позицию очков по трекингу
        if !useVisionFallback {
            glassesNode.simdTransform = trackingState.headTransform
        }

        let image = renderer.snapshot(
            atTime: CACurrentMediaTime(),
            with: CGSize(width: width, height: height),
            antialiasingMode: .multisampling4X
        )

        return compositeOverlay(image.cgImage, onto: pixelBuffer)
    }

    private func compositeOverlay(_ overlay: CGImage?, onto buffer: CVPixelBuffer) -> CVPixelBuffer? {
        guard let overlay else { return buffer }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return buffer }

        context.draw(overlay, in: CGRect(
            x: 0, y: 0,
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer)
        ))

        return buffer
    }

    // MARK: - Procedural Monokol MK295 Model

    /// Создаёт кубическую геометрическую оправу Monokol MK295 из ацетата.
  nonisolated static func buildMonokolMK295(color: GlassesFrameColor, brightness: Float) -> SCNNode {
        let root = SCNNode()
        root.name = "MonokolMK295"

        let frameUIColor: UIColor = {
            let base: UIColor = color == .red
                ? UIColor(red: 0.77, green: 0.12, blue: 0.16, alpha: 1)  // c40 red
                : UIColor(red: 0.10, green: 0.28, blue: 0.72, alpha: 1)  // c40 blue
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            base.getRed(&r, green: &g, blue: &b, alpha: &a)
            let m = CGFloat(brightness)
            return UIColor(red: min(1, r * m), green: min(1, g * m), blue: min(1, b * m), alpha: a)
        }()

        let acetateMaterial = SCNMaterial()
        acetateMaterial.name = "acetate"
        acetateMaterial.diffuse.contents = frameUIColor
        acetateMaterial.metalness.contents = 0.15
        acetateMaterial.roughness.contents = 0.12  // глянцевый ацетат
        acetateMaterial.lightingModel = .physicallyBased

        let lensMaterial = SCNMaterial()
        lensMaterial.diffuse.contents = UIColor.white.withAlphaComponent(0.08)
        lensMaterial.transparent.contents = NSNumber(value: 0.85)
        lensMaterial.metalness.contents = 0.0
        lensMaterial.roughness.contents = 0.05
        lensMaterial.lightingModel = .physicallyBased
        // Антибликовое покрытие — лёгкий specular
        lensMaterial.specular.contents = UIColor.white.withAlphaComponent(0.3)

        let frameThickness: CGFloat = 0.004
        let lensWidth: CGFloat = 0.034
        let lensHeight: CGFloat = 0.028
        let bridgeWidth: CGFloat = 0.008
        let templeLength: CGFloat = 0.06

        // Левая оправа — квадратная, без скруглений (кубический дизайн)
        let leftFrame = SCNNode(geometry: SCNBox(
            width: lensWidth + frameThickness * 2,
            height: lensHeight + frameThickness * 2,
            length: frameThickness,
            chamferRadius: 0  // массивные углы
        ))
        leftFrame.geometry?.materials = [acetateMaterial]
        leftFrame.position = SCNVector3(-(lensWidth / 2 + bridgeWidth / 2 + frameThickness), 0.01, 0.02)
        root.addChildNode(leftFrame)

        // Правая оправа
        let rightFrame = SCNNode(geometry: SCNBox(
            width: lensWidth + frameThickness * 2,
            height: lensHeight + frameThickness * 2,
            length: frameThickness,
            chamferRadius: 0
        ))
        rightFrame.geometry?.materials = [acetateMaterial]
        rightFrame.position = SCNVector3(lensWidth / 2 + bridgeWidth / 2 + frameThickness, 0.01, 0.02)
        root.addChildNode(rightFrame)

        // Линзы
        let leftLens = SCNNode(geometry: SCNBox(width: lensWidth, height: lensHeight, length: 0.001, chamferRadius: 0))
        leftLens.name = "leftLens"
        leftLens.geometry?.materials = [lensMaterial]
        leftLens.position = SCNVector3(leftFrame.position.x, leftFrame.position.y, leftFrame.position.z + 0.002)
        root.addChildNode(leftLens)

        let rightLens = SCNNode(geometry: SCNBox(width: lensWidth, height: lensHeight, length: 0.001, chamferRadius: 0))
        rightLens.name = "rightLens"
        rightLens.geometry?.materials = [lensMaterial]
        rightLens.position = SCNVector3(rightFrame.position.x, rightFrame.position.y, rightFrame.position.z + 0.002)
        root.addChildNode(rightLens)

        // Переносица
        let bridge = SCNNode(geometry: SCNBox(width: bridgeWidth, height: frameThickness * 1.5, length: frameThickness, chamferRadius: 0))
        bridge.geometry?.materials = [acetateMaterial]
        bridge.position = SCNVector3(0, 0.01, 0.02)
        root.addChildNode(bridge)

        // Заушники
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

        // Масштаб под лицо
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

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.trackingState.isTracking = true
            self.trackingState.headTransform = faceAnchor.transform
            self.trackingState.blendShapes = faceAnchor.blendShapes

            if self.faceNode == nil {
                let faceGeometry = ARSCNFaceGeometry(device: MTLCreateSystemDefaultDevice()!)!
                let node = SCNNode(geometry: faceGeometry)
                node.isHidden = true  // геометрия лица только для привязки
                self.faceNode = node
                self.scene.rootNode.addChildNode(node)

                if let glasses = self.glassesNode {
                    node.addChildNode(glasses)
                }
            }

            (self.faceNode?.geometry as? ARSCNFaceGeometry)?.update(from: faceAnchor.geometry)

            // Позиционирование очков относительно глаз
            if let glasses = self.glassesNode {
                glasses.simdTransform = matrix_identity_float4x4
                glasses.position = SCNVector3(0, 0.02, 0.04)
            }
        }
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.error = .arSessionFailed(error.localizedDescription)
            self?.useVisionFallback = true
        }
    }
}
