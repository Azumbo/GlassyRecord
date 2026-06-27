import XCTest
@testable import GlassyRecord

final class AppModelsTests: XCTestCase {
    func testRecordingQualityPresets() {
        XCTAssertEqual(RecordingQuality.hd1080p.displayName, "1080p")
        XCTAssertEqual(RecordingQuality.uhd4K.resolution.width, 3840)
        XCTAssertEqual(RecordingQuality.hd1080p.preferredFPS, 120)
    }

    func testGlassesFrameColorResources() {
        XCTAssertEqual(GlassesFrameColor.red.resourceName, "MonokolMK295_Red")
        XCTAssertEqual(GlassesFrameColor.blue.resourceName, "MonokolMK295_Blue")
    }

    func testAppSettingsDefaults() {
        let settings = AppSettings()
        XCTAssertEqual(settings.quality, .hd1080p)
        XCTAssertTrue(settings.faceCamMirrored)
        XCTAssertEqual(settings.lensTransparency, 0.85, accuracy: 0.001)
    }

    func testRecordingSessionCodable() throws {
        let session = RecordingSession(duration: 42, glassesEnabled: true, glassesColor: .blue)
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(RecordingSession.self, from: data)
        XCTAssertEqual(decoded.id, session.id)
        XCTAssertEqual(decoded.glassesColor, .blue)
    }

    func testGlassyRecordErrorDescriptions() {
        XCTAssertNotNil(GlassyRecordError.cameraUnavailable.errorDescription)
        XCTAssertNotNil(GlassyRecordError.faceTrackingUnavailable.errorDescription)
    }
}
