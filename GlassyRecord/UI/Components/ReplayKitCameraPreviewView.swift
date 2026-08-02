import ReplayKit
import SwiftUI
import UIKit

/// Face Cam через встроенную камеру ReplayKit — не конфликтует с `startCapture`.
struct ReplayKitCameraPreviewView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        attachPreview(to: container)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        attachPreview(to: uiView)
    }

    private func attachPreview(to container: UIView) {
        guard let preview = RPScreenRecorder.shared().cameraPreviewView else { return }
        if preview.superview === container { return }

        preview.removeFromSuperview()
        preview.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            preview.topAnchor.constraint(equalTo: container.topAnchor),
            preview.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}
