import ReplayKit
import SwiftUI
import UIKit

/// Нативная кнопка ReplayKit — сразу запускает наш Broadcast Extension без списка приложений.
struct SystemBroadcastPickerRepresentable: UIViewRepresentable {
    var showsMicrophoneButton: Bool
    var onPrepare: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPrepare: onPrepare)
    }

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 320, height: 56))
        context.coordinator.configure(picker, showsMicrophoneButton: showsMicrophoneButton)
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        context.coordinator.configure(uiView, showsMicrophoneButton: showsMicrophoneButton)
    }

    final class Coordinator {
        private let onPrepare: () -> Void
        private weak var installedPicker: RPSystemBroadcastPickerView?

        init(onPrepare: @escaping () -> Void) {
            self.onPrepare = onPrepare
        }

        func configure(_ picker: RPSystemBroadcastPickerView, showsMicrophoneButton: Bool) {
            if let bundleID = BroadcastExtensionLocator.preferredBundleID {
                picker.preferredExtension = bundleID
            }
            picker.showsMicrophoneButton = showsMicrophoneButton

            guard let button = picker.subviews.compactMap({ $0 as? UIButton }).first else { return }

            var config = button.configuration ?? UIButton.Configuration.filled()
            config.title = "Начать запись экрана"
            config.baseBackgroundColor = .systemRed
            config.baseForegroundColor = .white
            config.cornerStyle = .medium
            config.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 24, bottom: 14, trailing: 24)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = .systemFont(ofSize: 17, weight: .semibold)
                return outgoing
            }
            button.configuration = config

            guard installedPicker !== picker else { return }
            installedPicker = picker
            button.addAction(UIAction { [onPrepare] _ in onPrepare() }, for: .touchUpInside)
        }
    }
}
