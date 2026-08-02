import XCTest
import SceneKit
@testable import GlassyRecord

@MainActor
final class GlassesOverlayServiceTests: XCTestCase {
    func testServiceInitialization() {
        let service = GlassesOverlayService()
        XCTAssertFalse(service.isEnabled)
        XCTAssertEqual(service.frameColor, .red)
        XCTAssertEqual(service.lensTransparency, 0.85, accuracy: 0.001)
    }

    func testEnableDisableTracking() {
        let service = GlassesOverlayService()
        service.setEnabled(true)
        XCTAssertTrue(service.isEnabled)
        service.setEnabled(false)
        XCTAssertFalse(service.isEnabled)
    }

    func testFrameColorSwitch() {
        let service = GlassesOverlayService()
        service.setFrameColor(.blue)
        XCTAssertEqual(service.frameColor, .blue)
        service.setFrameColor(.red)
        XCTAssertEqual(service.frameColor, .red)
    }

    func testMonokolMK295ModelStructure() {
        let node = GlassesOverlayService.buildMonokolMK295(color: .red, brightness: 1.0)
        XCTAssertEqual(node.name, "MonokolMK295")
        XCTAssertNotNil(node.childNode(withName: "leftLens", recursively: true))
        XCTAssertNotNil(node.childNode(withName: "rightLens", recursively: true))
        XCTAssertGreaterThan(node.childNodes.count, 4)
    }

    func testLensTransparencyUpdate() {
        let service = GlassesOverlayService()
        service.setEnabled(true)
        service.lensTransparency = 0.5
        service.updateLensTransparency()
        XCTAssertEqual(service.lensTransparency, 0.5, accuracy: 0.001)
    }

    func testProcessFrameWhenDisabledReturnsOriginal() {
        let service = GlassesOverlayService()
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault, 64, 64,
            kCVPixelFormatType_32BGRA, nil, &pixelBuffer
        )
        guard let buffer = pixelBuffer else {
            XCTFail("Failed to create pixel buffer")
            return
        }
        let result = service.processFrame(buffer)
        XCTAssertEqual(CVPixelBufferGetWidth(result), 64)
    }
}

import CoreVideo
