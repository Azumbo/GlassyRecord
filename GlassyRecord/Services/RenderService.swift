import AVFoundation
import Metal
import MetalKit
import UIKit

/// Metal-композиция: экран + Face Cam + рисование + индикаторы касаний.
actor RenderService {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.textureCache = cache
    }

    func composite(
        screenBuffer: CVPixelBuffer?,
        faceCamBuffer: CVPixelBuffer?,
        faceCamFrame: CGRect,
        mirrored: Bool,
        overlayImage: CGImage?
    ) -> CVPixelBuffer? {
        guard let screenBuffer else { return faceCamBuffer }

        let width = CVPixelBufferGetWidth(screenBuffer)
        let height = CVPixelBufferGetHeight(screenBuffer)

        var outputBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &outputBuffer
        )

        guard let output = outputBuffer,
              let screenTexture = makeTexture(from: screenBuffer),
              let outputTexture = makeTexture(from: output) else {
            return screenBuffer
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            return screenBuffer
        }

        blit.copy(
            from: screenTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: screenTexture.width, height: screenTexture.height, depth: 1),
            to: outputTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()

        if let faceCamBuffer,
           let faceTexture = makeTexture(from: faceCamBuffer) {
            compositeFaceCam(
                faceTexture: faceTexture,
                onto: outputTexture,
                frame: faceCamFrame,
                mirrored: mirrored,
                commandBuffer: commandBuffer
            )
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return output
    }

    func applyFilter(_ filter: VideoFilter, to pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let filtered: CIImage?

        switch filter {
        case .none:
            return pixelBuffer
        case .vivid:
            filtered = ciImage.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.4,
                kCIInputContrastKey: 1.1
            ])
        case .mono:
            filtered = ciImage.applyingFilter("CIPhotoEffectMono")
        case .warm:
            filtered = ciImage.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 5000, y: 0)
            ])
        case .cool:
            filtered = ciImage.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 8000, y: 0)
            ])
        }

        guard let filtered else { return pixelBuffer }

        var output: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            CVPixelBufferGetWidth(pixelBuffer),
            CVPixelBufferGetHeight(pixelBuffer),
            kCVPixelFormatType_32BGRA,
            nil,
            &output
        )

        guard let out = output else { return pixelBuffer }
        CIContext().render(filtered, to: out)
        return out
    }

    private func makeTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let cache = textureCache else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }

    private func compositeFaceCam(
        faceTexture: MTLTexture,
        onto output: MTLTexture,
        frame: CGRect,
        mirrored: Bool,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }

        let destX = Int(frame.origin.x * CGFloat(output.width))
        let destY = Int(frame.origin.y * CGFloat(output.height))
        let destW = Int(frame.width * CGFloat(output.width))
        let destH = Int(frame.height * CGFloat(output.height))

        blit.copy(
            from: faceTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: faceTexture.width, height: faceTexture.height, depth: 1),
            to: output,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: destX, y: destY, z: 0)
        )
        blit.endEncoding()
        _ = mirrored // зеркалирование обрабатывается на уровне AVCaptureConnection
    }
}
