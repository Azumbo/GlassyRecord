import AVFoundation
import UIKit

/// Единственное место для `AVSampleBufferDisplayLayer` — не переносить слой в SwiftUI.
enum PiPDisplayLayerHost {
    /// Минимальная сторона, которую принимаем от системы при щипке.
    static let minimumSide: CGFloat = 68

    private static var preferredStartSize = PiPAspectRatio.portrait9x16.startSize
    private static var hostWindow: UIWindow?
    private static weak var boundDisplayLayer: AVSampleBufferDisplayLayer?
    private static var contentScale: CGFloat = 1.0
    private static var explicitRenderSize: CGSize?

    private static let hostView: UIView = {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .black
        view.clipsToBounds = true
        view.isHidden = true
        return view
    }()

    /// Стартовый буфер до ответа системы (из выбранного aspect ratio).
    static var baseRenderSize: CGSize { preferredStartSize }

    static func setPreferredAspect(_ aspect: PiPAspectRatio) {
        preferredStartSize = aspect.startSize
    }

    static func renderSize(for scale: CGFloat) -> CGSize {
        _ = scale
        return baseRenderSize
    }

    static var currentRenderSize: CGSize {
        explicitRenderSize ?? baseRenderSize
    }

    static var minimumRenderSize: CGSize { baseRenderSize }

    /// Сбрасывает source layer к стартовому размеру (до первого sync с системой).
    @MainActor
    static func resetToMinimumSize(displayLayer: AVSampleBufferDisplayLayer? = nil) {
        contentScale = 1.0
        explicitRenderSize = nil
        applyRenderSize(baseRenderSize, displayLayer: displayLayer)
    }

    @MainActor
    static func updateScale(_ scale: CGFloat, displayLayer: AVSampleBufferDisplayLayer? = nil) {
        contentScale = min(max(scale, GlassyTheme.pipScaleMinimum), GlassyTheme.pipScaleMaximum)
        // Крупность лица не меняет размер окна.
        if explicitRenderSize == nil {
            applyRenderSize(baseRenderSize, displayLayer: displayLayer)
        } else if let size = explicitRenderSize {
            applyRenderSize(size, displayLayer: displayLayer)
        }
    }

    /// Синхронизирует source layer с фактическим render size системного PiP.
    @MainActor
    static func updateRenderSize(_ size: CGSize, displayLayer: AVSampleBufferDisplayLayer? = nil) {
        guard size.width >= minimumSide - 1, size.height >= minimumSide - 1 else { return }
        explicitRenderSize = size
        applyRenderSize(size, displayLayer: displayLayer)
    }

    /// Скрывает источник в UI приложения (системный PiP остаётся видимым).
    @MainActor
    static func setSourceHidden(_ hidden: Bool) {
        hostView.isHidden = hidden
    }

    @MainActor
    static func install(_ displayLayer: AVSampleBufferDisplayLayer) {
        boundDisplayLayer = displayLayer
        ensureWindow()
        guard hostWindow?.rootViewController?.view != nil else { return }

        if displayLayer.superlayer !== hostView.layer {
            displayLayer.removeFromSuperlayer()
            hostView.layer.addSublayer(displayLayer)
        }

        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.backgroundColor = UIColor.black.cgColor
        displayLayer.isOpaque = true

        let size = currentRenderSize
        applyRenderSize(size, displayLayer: displayLayer)
        hostView.isHidden = true
    }

    @MainActor
    static func detach(_ displayLayer: AVSampleBufferDisplayLayer) {
        displayLayer.removeFromSuperlayer()
        displayLayer.flushAndRemoveImage()
        hostView.removeFromSuperview()
        hostWindow?.isHidden = true
        hostWindow = nil
        boundDisplayLayer = nil
        contentScale = 1.0
        explicitRenderSize = nil
    }

    @MainActor
    private static func applyRenderSize(_ newSize: CGSize, displayLayer: AVSampleBufferDisplayLayer?) {
        let layer = displayLayer ?? boundDisplayLayer
        if let layer, layer !== boundDisplayLayer {
            boundDisplayLayer = layer
        }

        applySize(newSize, to: layer)
        embedHostViewInWindow(size: newSize)
    }

    @MainActor
    private static func applySize(_ newSize: CGSize, to displayLayer: AVSampleBufferDisplayLayer?) {
        hostView.bounds = CGRect(origin: .zero, size: newSize)
        hostView.frame = CGRect(
            x: -newSize.width * 2,
            y: -newSize.height * 2,
            width: newSize.width,
            height: newSize.height
        )

        if let displayLayer {
            displayLayer.frame = CGRect(origin: .zero, size: newSize)
        }
    }

    @MainActor
    private static func embedHostViewInWindow(size: CGSize) {
        guard let root = hostWindow?.rootViewController?.view else { return }
        if hostView.superview !== root {
            hostView.removeFromSuperview()
            root.addSubview(hostView)
        }

        hostView.bounds = CGRect(origin: .zero, size: size)
        hostView.frame = CGRect(
            x: -size.width * 2,
            y: -size.height * 2,
            width: size.width,
            height: size.height
        )
        hostView.isHidden = true

        if let displayLayer = boundDisplayLayer {
            displayLayer.frame = CGRect(origin: .zero, size: size)
        }
    }

    @MainActor
    private static func ensureWindow() {
        if let hostWindow {
            hostWindow.isHidden = false
            configurePassThrough(on: hostWindow)
            return
        }

        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: {
            $0.activationState == .foregroundActive
                || $0.activationState == .foregroundInactive
                || $0.activationState == .background
        }) ?? scenes.first else { return }

        let window = UIWindow(windowScene: scene)
        window.frame = scene.screen.bounds
        // Ниже основного окна приложения — не перехватывает касания UI.
        window.windowLevel = .init(rawValue: UIWindow.Level.normal.rawValue - 1)
        window.backgroundColor = .clear
        window.isHidden = false

        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        controller.view.frame = scene.screen.bounds
        window.rootViewController = controller
        hostWindow = window
        configurePassThrough(on: window)
    }

    @MainActor
    private static func configurePassThrough(on window: UIWindow) {
        window.isUserInteractionEnabled = false
        window.rootViewController?.view.isUserInteractionEnabled = false
    }
}
