import ReplayKit
import SwiftUI
import UIKit
struct SystemBroadcastPickerButton: UIViewRepresentable {
    var showsMicrophoneButton: Bool
    var onPrepare: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPrepare: onPrepare)
    }

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 280, height: 56))
        if let bundleID = BroadcastExtensionLocator.preferredBundleID {
            picker.preferredExtension = bundleID
        }
        picker.showsMicrophoneButton = showsMicrophoneButton
        stylePickerButton(picker, coordinator: context.coordinator)
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        if let bundleID = BroadcastExtensionLocator.preferredBundleID {
            uiView.preferredExtension = bundleID
        }
        uiView.showsMicrophoneButton = showsMicrophoneButton
        stylePickerButton(uiView, coordinator: context.coordinator)
    }

    final class Coordinator {
        let onPrepare: () -> Void
        init(onPrepare: @escaping () -> Void) { self.onPrepare = onPrepare }
    }

    private func stylePickerButton(_ picker: RPSystemBroadcastPickerView, coordinator: Coordinator) {
        guard let button = picker.subviews.compactMap({ $0 as? UIButton }).first else { return }

        var config = button.configuration ?? UIButton.Configuration.plain()
        config.title = "Системная кнопка записи"
        config.baseBackgroundColor = .secondarySystemBackground
        config.baseForegroundColor = .label
        config.cornerStyle = .medium
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .systemFont(ofSize: 15, weight: .medium)
            return outgoing
        }
        button.configuration = config

        button.removeTarget(nil, action: nil, for: .touchUpInside)
        button.addAction(UIAction { _ in coordinator.onPrepare() }, for: .touchUpInside)
    }
}

@MainActor
enum BroadcastPickerPresenter {
    private static var isPresenting = false

    static func present(
        configProvider: @escaping () -> BroadcastRecordingConfig,
        onStarted: @escaping (RPBroadcastController) -> Void,
        onCancelled: @escaping (String?) -> Void
    ) {
        guard BroadcastExtensionLocator.isExtensionEmbedded else {
            onCancelled(
                "Broadcast Extension не установлен. В Xcode: Product → Clean, удалите приложение с iPhone, Run снова. Проверьте таргет GlassyRecordBroadcastUpload."
            )
            return
        }

        guard !isPresenting else { return }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard let host = topViewController() else {
                onCancelled("Не удалось открыть окно записи")
                return
            }
            isPresenting = true

            RPScreenRecorder.shared().isMicrophoneEnabled = configProvider().microphoneEnabled

            loadBroadcastPicker(onLoaded: { vc, error in
                Task { @MainActor in
                    isPresenting = false
                    if let error {
                        onCancelled(BroadcastErrorMessages.message(for: error))
                        return
                    }
                    guard let vc else {
                        onCancelled("Не удалось загрузить окно записи")
                        return
                    }

                    let delegate = BroadcastPickerDelegate(
                        configProvider: configProvider,
                        onStarted: onStarted,
                        onCancelled: onCancelled
                    )
                    vc.delegate = delegate
                    objc_setAssociatedObject(vc, &delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

                    if UIDevice.current.userInterfaceIdiom == .pad, let popover = vc.popoverPresentationController {
                        vc.modalPresentationStyle = .popover
                        popover.sourceView = host.view
                        popover.sourceRect = CGRect(
                            x: host.view.bounds.midX - 1,
                            y: host.view.bounds.maxY - 100,
                            width: 2,
                            height: 2
                        )
                        popover.permittedArrowDirections = .down
                    }

                    host.present(vc, animated: true)
                }
            })
        }
    }

    private static func loadBroadcastPicker(
        onLoaded: @escaping (RPBroadcastActivityViewController?, Error?) -> Void
    ) {
        if let bundleID = BroadcastExtensionLocator.preferredBundleID {
            RPBroadcastActivityViewController.load(withPreferredExtension: bundleID, handler: onLoaded)
        } else {
            RPBroadcastActivityViewController.load(handler: onLoaded)
        }
    }

    private static func localizedBroadcastError(_ error: Error) -> String {
        BroadcastErrorMessages.message(for: error)
    }

    private static var delegateKey: UInt8 = 0

    private static func topViewController(base: UIViewController? = nil) -> UIViewController? {
        let base = base ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController

        if let nav = base as? UINavigationController {
            return topViewController(base: nav.visibleViewController)
        }
        if let tab = base as? UITabBarController, let selected = tab.selectedViewController {
            return topViewController(base: selected)
        }
        if let presented = base?.presentedViewController {
            return topViewController(base: presented)
        }
        return base
    }
}

private final class BroadcastPickerDelegate: NSObject, RPBroadcastActivityViewControllerDelegate, @unchecked Sendable {
    let configProvider: () -> BroadcastRecordingConfig
    let onStarted: (RPBroadcastController) -> Void
    let onCancelled: (String?) -> Void

    init(
        configProvider: @escaping () -> BroadcastRecordingConfig,
        onStarted: @escaping (RPBroadcastController) -> Void,
        onCancelled: @escaping (String?) -> Void
    ) {
        self.configProvider = configProvider
        self.onStarted = onStarted
        self.onCancelled = onCancelled
    }

    nonisolated func broadcastActivityViewController(
        _ broadcastActivityViewController: RPBroadcastActivityViewController,
        didFinishWith broadcastController: RPBroadcastController?,
        error: Error?
    ) {
        let box = BroadcastControllerBox(broadcastController)
        DispatchQueue.main.async { [self] in
            broadcastActivityViewController.dismiss(animated: true) {
                if let error {
                    if UIScreen.main.isCaptured, let controller = ActiveBroadcastController.current() {
                        self.onStarted(controller)
                        return
                    }
                    self.onCancelled(BroadcastErrorMessages.message(for: error))
                    return
                }
                guard let controller = box.controller else {
                    self.resolveBroadcastStartAfterDismiss()
                    return
                }
                BroadcastConfigStore.saveConfig(self.configProvider())
                controller.startBroadcast { error in
                    DispatchQueue.main.async {
                        if let error {
                            self.onCancelled(BroadcastErrorMessages.message(for: error))
                        } else {
                            self.onStarted(controller)
                        }
                    }
                }
            }
        }
    }

    private func resolveBroadcastStartAfterDismiss() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [self] in
            if let controller = ActiveBroadcastController.current() {
                BroadcastConfigStore.saveConfig(self.configProvider())
                self.onStarted(controller)
                return
            }
            if UIScreen.main.isCaptured || BroadcastConfigStore.state == .recording,
               let controller = ActiveBroadcastController.current() {
                self.onStarted(controller)
                return
            }
            self.onCancelled(BroadcastErrorMessages.userDeclinedMessage)
        }
    }
}

private final class BroadcastControllerBox: @unchecked Sendable {
    let controller: RPBroadcastController?
    init(_ controller: RPBroadcastController?) { self.controller = controller }
}

import ObjectiveC
