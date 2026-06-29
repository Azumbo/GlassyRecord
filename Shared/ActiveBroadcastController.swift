import Foundation
import ReplayKit

/// ReplayKit не экспортирует `+[RPBroadcastController broadcastControllers]` в Swift,
/// но метод есть в runtime — нужен для остановки записи, начатой через RPSystemBroadcastPickerView.
enum ActiveBroadcastController {
    static func current() -> RPBroadcastController? {
        let selector = NSSelectorFromString("broadcastControllers")
        guard RPBroadcastController.responds(to: selector),
              let unmanaged = (RPBroadcastController.self as AnyObject).perform(selector) else {
            return nil
        }
        let controllers = unmanaged.takeUnretainedValue() as? [RPBroadcastController] ?? []
        return controllers.first { $0.isBroadcasting }
    }
}
