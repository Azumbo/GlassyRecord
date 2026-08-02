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

    func makeUIView(context: Context) -> BroadcastPickerContainerView {
        let container = BroadcastPickerContainerView()
        context.coordinator.configure(container, showsMicrophoneButton: showsMicrophoneButton)
        return container
    }

    func updateUIView(_ uiView: BroadcastPickerContainerView, context: Context) {
        context.coordinator.configure(uiView, showsMicrophoneButton: showsMicrophoneButton)
    }

    final class Coordinator {
        private let onPrepare: () -> Void
        private weak var installedPicker: RPSystemBroadcastPickerView?
        private var didInstallPrepareActions = false

        init(onPrepare: @escaping () -> Void) {
            self.onPrepare = onPrepare
        }

        func configure(_ container: BroadcastPickerContainerView, showsMicrophoneButton: Bool) {
            let picker = container.picker
            if let bundleID = BroadcastExtensionLocator.preferredBundleID {
                picker.preferredExtension = bundleID
            }
            picker.showsMicrophoneButton = showsMicrophoneButton

            guard let button = picker.subviews.compactMap({ $0 as? UIButton }).first else { return }

            var config = button.configuration ?? UIButton.Configuration.filled()
            config.title = L10n.t("recording.start_screen")
            config.baseBackgroundColor = .systemRed
            config.baseForegroundColor = .white
            config.cornerStyle = .medium
            config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = .systemFont(ofSize: 17, weight: .semibold)
                return outgoing
            }
            button.configuration = config
            button.isUserInteractionEnabled = true

            // Не переустанавливаем actions при каждом updateUIView — иначе копится очередь.
            guard installedPicker !== picker || !didInstallPrepareActions else { return }
            installedPicker = picker
            didInstallPrepareActions = true
            button.addAction(UIAction { [onPrepare] _ in onPrepare() }, for: .touchDown)
            button.addAction(UIAction { [onPrepare] _ in onPrepare() }, for: .touchUpInside)
        }
    }
}

/// Контейнер растягивает системный picker на всю ширину и не даёт SwiftUI-жестам «съесть» hit-test.
final class BroadcastPickerContainerView: UIView {
    let picker = RPSystemBroadcastPickerView(frame: .zero)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true
        picker.translatesAutoresizingMaskIntoConstraints = false
        addSubview(picker)
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: trailingAnchor),
            picker.topAnchor.constraint(equalTo: topAnchor),
            picker.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let button = picker.subviews.compactMap({ $0 as? UIButton }).first {
            button.frame = picker.bounds
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard bounds.contains(point), !isHidden, alpha > 0.01, isUserInteractionEnabled else {
            return nil
        }
        let pickerPoint = convert(point, to: picker)
        if let hit = picker.hitTest(pickerPoint, with: event) {
            return hit
        }
        if let button = picker.subviews.compactMap({ $0 as? UIButton }).first {
            return button
        }
        return picker
    }
}
