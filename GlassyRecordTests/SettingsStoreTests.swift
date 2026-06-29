import XCTest
@testable import GlassyRecord

@MainActor
final class SettingsStoreTests: XCTestCase {
    func testDefaultSettings() {
        let store = SettingsStore()
        XCTAssertEqual(store.settings.quality, .hd1080p)
        XCTAssertTrue(store.settings.microphoneEnabled)
    }

    func testUpdatePersists() {
        let store = SettingsStore()
        store.update { $0.quality = .uhd4K }
        let reloaded = SettingsStore()
        XCTAssertEqual(reloaded.settings.quality, .uhd4K)
        store.update { $0.quality = .hd1080p }
    }
}
