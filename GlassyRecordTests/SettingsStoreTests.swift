import XCTest
@testable import GlassyRecord

@MainActor
final class SettingsStoreTests: XCTestCase {
    func testSettingsUpdatePersists() {
        let persistence = PersistenceController(inMemory: true)
        let context = ModelContext(persistence.container)
        let store = SettingsStore(persistence: persistence, modelContext: context)

        store.update { $0.quality = .uhd4K }
        XCTAssertEqual(store.settings.quality, .uhd4K)

        let reloaded = persistence.loadSettings(context: context)
        XCTAssertEqual(reloaded.quality, .uhd4K)
    }

    func testGlassesSettingsPersistence() {
        let persistence = PersistenceController(inMemory: true)
        let context = ModelContext(persistence.container)
        let store = SettingsStore(persistence: persistence, modelContext: context)

        store.update {
            $0.glassesEnabledByDefault = true
            $0.glassesColor = .blue
            $0.lensTransparency = 0.6
        }

        let reloaded = persistence.loadSettings(context: context)
        XCTAssertTrue(reloaded.glassesEnabledByDefault)
        XCTAssertEqual(reloaded.glassesColor, .blue)
        XCTAssertEqual(reloaded.lensTransparency, 0.6, accuracy: 0.001)
    }
}

import SwiftData
