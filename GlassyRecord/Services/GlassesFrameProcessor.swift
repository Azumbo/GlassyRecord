import ARKit
import CoreVideo
import SceneKit
import UIKit
import Vision

/// Потокобезопасный рендер очков (Vision 2D + SceneKit для ARKit) для PiP и фоновых очередей захвата.
final class GlassesFrameProcessor: @unchecked Sendable {
    private let lock = NSLock()
    private var isEnabled = false
    private var useVisionFallback = true
    private var trackingState = FaceTrackingState()
    private var frameColor: GlassesFrameColor = .red
    private var lensTransparency: Float = 0.85
    private var frameBrightness: Float = 1.0

    private let sceneRenderer: SCNRenderer
    private let scene = SCNScene()
    private var glassesNode: SCNNode?
    private var redGlassesNode: SCNNode?
    private var blueGlassesNode: SCNNode?
    private var visionSequenceHandler = VNSequenceRequestHandler()
    private var smoothedLeftEye = CGPoint.zero
    private var smoothedRightEye = CGPoint.zero
    private var smoothedEyeDistance: CGFloat = 0
    private var hasSmoothedEyes = false

    init() {
        let device = MTLCreateSystemDefaultDevice()
        sceneRenderer = SCNRenderer(device: device, options: nil)
        sceneRenderer.scene = scene
        sceneRenderer.autoenablesDefaultLighting = true

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.position = SCNVector3(0, 0, 0)
        scene.rootNode.addChildNode(cameraNode)
        sceneRenderer.pointOfView = cameraNode

        redGlassesNode = GlassesOverlayService.buildMonokolMK295(color: .red, brightness: 1.0)
        blueGlassesNode = GlassesOverlayService.buildMonokolMK295(color: .blue, brightness: 1.0)
        swapGlassesModel(to: .red, locked: true)
    }

    func setEnabled(_ enabled: Bool) {
        lock.withLock { isEnabled = enabled }
    }

    func setVisionFallbackMode() {
        lock.withLock {
            useVisionFallback = true
            trackingState = FaceTrackingState()
            hasSmoothedEyes = false
        }
    }

    func setFrameColor(_ color: GlassesFrameColor) {
        lock.withLock {
            guard frameColor != color else { return }
            frameColor = color
            swapGlassesModel(to: color, locked: true)
        }
    }

    func setLensTransparency(_ value: Float) {
        lock.withLock {
            lensTransparency = value
            applyLensTransparency()
        }
    }

    func setFrameBrightness(_ value: Float) {
        lock.withLock {
            frameBrightness = value
            rebuildGlassesModels()
            swapGlassesModel(to: frameColor, locked: true)
        }
    }

    func updateTrackingState(_ state: FaceTrackingState) {
        lock.withLock {
            trackingState = state
            useVisionFallback = false
        }
    }

    func resetTracking() {
        lock.withLock {
            trackingState = FaceTrackingState()
            hasSmoothedEyes = false
        }
    }

    func processFrame(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer {
        let snapshot = lock.withLock {
            (
                isEnabled: isEnabled,
                useVisionFallback: useVisionFallback,
                trackingState: trackingState,
                frameColor: frameColor,
                lensTransparency: lensTransparency,
                frameBrightness: frameBrightness
            )
        }
        guard snapshot.isEnabled else { return pixelBuffer }

        if snapshot.useVisionFallback {
            // PiP / AVCapture: рисуем очки в пиксельный буфер — один кадр для превью и системного PiP.
            return drawVisionGlasses(
                onto: pixelBuffer,
                color: snapshot.frameColor,
                lensAlpha: CGFloat(snapshot.lensTransparency),
                brightness: CGFloat(snapshot.frameBrightness)
            ) ?? pixelBuffer
        }

        guard snapshot.trackingState.isTracking else { return pixelBuffer }
        return renderSceneKitGlassesOntoBuffer(pixelBuffer, tracking: snapshot.trackingState) ?? pixelBuffer
    }

    // MARK: - Vision → 2D (burn into buffer)

    private func drawVisionGlasses(
        onto pixelBuffer: CVPixelBuffer,
        color: GlassesFrameColor,
        lensAlpha: CGFloat,
        brightness: CGFloat
    ) -> CVPixelBuffer? {
        let request = VNDetectFaceLandmarksRequest()
        do {
            try visionSequenceHandler.perform([request], on: pixelBuffer)
        } catch {
            return pixelBuffer
        }

        guard let observation = request.results?.first,
              let landmarks = observation.landmarks else {
            lock.withLock { hasSmoothedEyes = false }
            return pixelBuffer
        }

        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let bbox = observation.boundingBox

        guard let leftNorm = eyeCenter(from: landmarks.leftEye, in: bbox)
            ?? eyeCenter(from: landmarks.leftPupil, in: bbox),
            let rightNorm = eyeCenter(from: landmarks.rightEye, in: bbox)
            ?? eyeCenter(from: landmarks.rightPupil, in: bbox) else {
            return pixelBuffer
        }

        // Vision: origin bottom-left. CGContext on CVPixelBuffer: same.
        var left = CGPoint(x: leftNorm.x * width, y: leftNorm.y * height)
        var right = CGPoint(x: rightNorm.x * width, y: rightNorm.y * height)
        var distance = hypot(right.x - left.x, right.y - left.y)

        lock.lock()
        if !hasSmoothedEyes {
            smoothedLeftEye = left
            smoothedRightEye = right
            smoothedEyeDistance = distance
            hasSmoothedEyes = true
        } else {
            let a: CGFloat = 0.28
            smoothedLeftEye = CGPoint(
                x: smoothedLeftEye.x + (left.x - smoothedLeftEye.x) * a,
                y: smoothedLeftEye.y + (left.y - smoothedLeftEye.y) * a
            )
            smoothedRightEye = CGPoint(
                x: smoothedRightEye.x + (right.x - smoothedRightEye.x) * a,
                y: smoothedRightEye.y + (right.y - smoothedRightEye.y) * a
            )
            smoothedEyeDistance = smoothedEyeDistance + (distance - smoothedEyeDistance) * a
            left = smoothedLeftEye
            right = smoothedRightEye
            distance = max(smoothedEyeDistance, 1)
        }
        lock.unlock()

        return compositeMonokolFrames(
            onto: pixelBuffer,
            leftEye: left,
            rightEye: right,
            eyeDistance: distance,
            color: color,
            lensAlpha: lensAlpha,
            brightness: brightness
        )
    }

    private func compositeMonokolFrames(
        onto buffer: CVPixelBuffer,
        leftEye: CGPoint,
        rightEye: CGPoint,
        eyeDistance: CGFloat,
        color: GlassesFrameColor,
        lensAlpha: CGFloat,
        brightness: CGFloat
    ) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return buffer }

        let angle = atan2(rightEye.y - leftEye.y, rightEye.x - leftEye.x)
        let lensW = eyeDistance * 0.72
        let lensH = lensW * 0.78
        let stroke = max(2.5, eyeDistance * 0.11)
        let bridgeW = eyeDistance * 0.18

        let frameUIColor: UIColor = {
            let base: UIColor = color == .red
                ? UIColor(red: 0.77, green: 0.12, blue: 0.16, alpha: 1)
                : UIColor(red: 0.10, green: 0.28, blue: 0.72, alpha: 1)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            base.getRed(&r, green: &g, blue: &b, alpha: &a)
            return UIColor(
                red: min(1, r * brightness),
                green: min(1, g * brightness),
                blue: min(1, b * brightness),
                alpha: a
            )
        }()

        context.saveGState()
        context.translateBy(x: (leftEye.x + rightEye.x) * 0.5, y: (leftEye.y + rightEye.y) * 0.5)
        context.rotate(by: angle)

        let halfGap = eyeDistance * 0.5
        let leftRect = CGRect(x: -halfGap - lensW * 0.5, y: -lensH * 0.5, width: lensW, height: lensH)
        let rightRect = CGRect(x: halfGap - lensW * 0.5, y: -lensH * 0.5, width: lensW, height: lensH)

        // Линзы
        context.setFillColor(UIColor.white.withAlphaComponent(0.08 + (1 - lensAlpha) * 0.25).cgColor)
        context.fill(leftRect)
        context.fill(rightRect)

        // Оправа MK295 — кубическая
        context.setStrokeColor(frameUIColor.cgColor)
        context.setLineWidth(stroke)
        context.setLineJoin(.miter)
        context.stroke(leftRect)
        context.stroke(rightRect)

        // Переносица
        context.setFillColor(frameUIColor.cgColor)
        context.fill(CGRect(x: -bridgeW * 0.5, y: -stroke * 0.4, width: bridgeW, height: stroke * 0.8))

        context.restoreGState()
        return buffer
    }

    private func eyeCenter(from region: VNFaceLandmarkRegion2D?, in bbox: CGRect) -> CGPoint? {
        guard let region else { return nil }
        let points = region.normalizedPoints
        guard !points.isEmpty else { return nil }

        let center = points.reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + CGFloat(point.x), y: partial.y + CGFloat(point.y))
        }
        let avg = CGPoint(x: center.x / CGFloat(points.count), y: center.y / CGFloat(points.count))
        return CGPoint(
            x: bbox.origin.x + avg.x * bbox.width,
            y: bbox.origin.y + avg.y * bbox.height
        )
    }

    // MARK: - SceneKit (ARKit path)

    private func renderSceneKitGlassesOntoBuffer(
        _ pixelBuffer: CVPixelBuffer,
        tracking: FaceTrackingState
    ) -> CVPixelBuffer? {
        let hasGlasses = lock.withLock { () -> Bool in
            guard let glassesNode else { return false }
            glassesNode.simdTransform = tracking.headTransform
            return true
        }
        guard hasGlasses else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        let image = sceneRenderer.snapshot(
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

    // MARK: - Scene

    private func rebuildGlassesModels() {
        redGlassesNode = GlassesOverlayService.buildMonokolMK295(color: .red, brightness: frameBrightness)
        blueGlassesNode = GlassesOverlayService.buildMonokolMK295(color: .blue, brightness: frameBrightness)
    }

    private func swapGlassesModel(to color: GlassesFrameColor, locked: Bool) {
        let apply = {
            self.glassesNode?.removeFromParentNode()

            let node: SCNNode?
            switch color {
            case .red: node = self.redGlassesNode?.clone()
            case .blue: node = self.blueGlassesNode?.clone()
            }

            guard let node else { return }
            node.name = "glasses"
            self.glassesNode = node
            self.scene.rootNode.addChildNode(node)
            self.applyLensTransparency()
        }

        if locked {
            apply()
        } else {
            lock.withLock { apply() }
        }
    }

    private func applyLensTransparency() {
        glassesNode?.childNode(withName: "leftLens", recursively: true)?
            .geometry?.firstMaterial?.transparent.contents = NSNumber(value: lensTransparency)
        glassesNode?.childNode(withName: "rightLens", recursively: true)?
            .geometry?.firstMaterial?.transparent.contents = NSNumber(value: lensTransparency)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
