import UIKit

/// Плавающий системный слой индикаторов касаний — виден поверх других приложений во время записи.
@MainActor
enum TouchIndicatorOverlayHost {
    struct Style: Equatable {
        var enabled: Bool = true
        var color: UIColor = UIColor(red: 1, green: 0.23, blue: 0.19, alpha: 1)
        var size: CGFloat = 24
        var opacity: CGFloat = 0.7
    }

    private static var overlayWindow: TouchOverlayWindow?
    private static var style = Style()
    private static var lastScreenPoint: CGPoint?
    private static var isActive = false

    static func updateStyle(_ newStyle: Style) {
        style = newStyle
    }

    static func activate() {
        guard style.enabled else {
            deactivate()
            return
        }
        isActive = true
        ensureWindow()
        overlayWindow?.isHidden = false
    }

    static func deactivate() {
        isActive = false
        lastScreenPoint = nil
        overlayWindow?.isHidden = true
        overlayWindow?.rootViewController?.view.subviews.forEach { $0.removeFromSuperview() }
    }

    /// После смены scene (foreground/background) перепривязать окно к активной сцене.
    static func refreshWindowScene() {
        guard isActive else { return }
        ensureWindow(forceNew: true)
    }

    static func show(at screenPoint: CGPoint) {
        guard isActive, style.enabled, let window = overlayWindow else { return }

        if let last = lastScreenPoint {
            let dx = screenPoint.x - last.x
            let dy = screenPoint.y - last.y
            guard (dx * dx + dy * dy) >= 400 else { return }
        }
        lastScreenPoint = screenPoint

        let hostView = window.rootViewController?.view ?? window
        let localPoint = hostView.convert(screenPoint, from: nil)

        let diameter = style.size
        let indicator = UIView(frame: CGRect(
            x: localPoint.x - diameter / 2,
            y: localPoint.y - diameter / 2,
            width: diameter,
            height: diameter
        ))
        indicator.backgroundColor = style.color.withAlphaComponent(style.opacity)
        indicator.layer.cornerRadius = diameter / 2
        indicator.isUserInteractionEnabled = false
        hostView.addSubview(indicator)

        UIView.animate(withDuration: 0.55, delay: 0, options: [.curveEaseOut]) {
            indicator.transform = CGAffineTransform(scaleX: 1.35, y: 1.35)
            indicator.alpha = 0
        } completion: { _ in
            indicator.removeFromSuperview()
        }

        UsageTracker.shared.track(.touchIndicatorShown)
    }

    @MainActor
    private static func ensureWindow(forceNew: Bool = false) {
        if forceNew {
            overlayWindow = nil
        }
        if overlayWindow != nil {
            return
        }

        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: {
            $0.activationState == .foregroundActive
                || $0.activationState == .foregroundInactive
                || $0.activationState == .background
        }) ?? scenes.first else { return }

        let window = TouchOverlayWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        // Выше обычных приложений, ниже системных алертов; касания проходят сквозь окно.
        window.windowLevel = .init(rawValue: UIWindow.Level.statusBar.rawValue + 1)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isUserInteractionEnabled = true

        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        controller.view.frame = scene.screen.bounds
        window.rootViewController = controller

        window.onTouchAtScreenPoint = { point in
            Task { @MainActor in
                show(at: point)
            }
        }

        window.isHidden = !isActive
        overlayWindow = window
    }
}

/// Окно-оверлей: фиксирует координаты касания и пропускает их приложению под ним.
final class TouchOverlayWindow: UIWindow {
    var onTouchAtScreenPoint: ((CGPoint) -> Void)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let event {
            for touch in event.allTouches ?? [] {
                switch touch.phase {
                case .began, .moved:
                    onTouchAtScreenPoint?(touch.location(in: nil))
                default:
                    break
                }
            }
        }
        return nil
    }
}
