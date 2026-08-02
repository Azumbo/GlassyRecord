import CoreMedia
import UIKit

enum PiPPixelGeometry {
    @MainActor
    static var screenScale: CGFloat {
        UIScreen.main.scale
    }

    @MainActor
    static func pixelSize(fromPoints pointSize: CGSize) -> CGSize {
        let scale = screenScale
        return CGSize(
            width: (pointSize.width * scale).rounded(.toNearestOrAwayFromZero),
            height: (pointSize.height * scale).rounded(.toNearestOrAwayFromZero)
        )
    }

    @MainActor
    static func pointSize(fromPixels pixelSize: CGSize) -> CGSize {
        let scale = screenScale
        return CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale)
    }

    static func pixelSize(from dimensions: CMVideoDimensions) -> CGSize {
        CGSize(
            width: CGFloat(max(dimensions.width, 1)),
            height: CGFloat(max(dimensions.height, 1))
        )
    }

    @MainActor
    static func pointSizeForLayer(from dimensions: CMVideoDimensions) -> CGSize {
        pointSize(fromPixels: pixelSize(from: dimensions))
    }
}
