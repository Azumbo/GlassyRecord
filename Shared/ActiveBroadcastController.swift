import Foundation
import ReplayKit

/// ReplayKit не экспортирует `+[RPBroadcastController broadcastControllers]` в Swift,
/// но метод есть в runtime — нужен для остановки записи, начатой через RPSystemBroadcastPickerView.
enum ActiveBroadcastController {
    static func current() -> RPBroadcastController? {
        all().first { $0.isBroadcasting } ?? all().first
    }

    static func all() -> [RPBroadcastController] {
        let selector = NSSelectorFromString("broadcastControllers")
        guard let method = class_getClassMethod(RPBroadcastController.self, selector) else {
            return legacyPerformFallback()
        }
        let imp = method_getImplementation(method)
        typealias ClassFn = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>?
        let fn = unsafeBitCast(imp, to: ClassFn.self)
        guard let object = fn(RPBroadcastController.self, selector)?.takeUnretainedValue() else {
            return []
        }
        if let array = object as? [RPBroadcastController] {
            return array
        }
        if let nsArray = object as? NSArray {
            return nsArray.compactMap { $0 as? RPBroadcastController }
        }
        return []
    }

    /// Старый путь через perform — на случай, если class_getClassMethod недоступен.
    private static func legacyPerformFallback() -> [RPBroadcastController] {
        let selector = NSSelectorFromString("broadcastControllers")
        guard RPBroadcastController.responds(to: selector),
              let unmanaged = (RPBroadcastController.self as AnyObject).perform(selector) else {
            return []
        }
        let value = unmanaged.takeUnretainedValue()
        if let array = value as? [RPBroadcastController] {
            return array
        }
        if let nsArray = value as? NSArray {
            return nsArray.compactMap { $0 as? RPBroadcastController }
        }
        return []
    }
}
