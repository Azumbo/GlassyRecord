import AVFoundation
import SwiftUI
import UIKit

/// Превью того же потока кадров, что идёт в системный PiP (`AVSampleBufferDisplayLayer`).
struct PiPProcessedPreviewView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> PiPProcessedPreviewUIView {
        let view = PiPProcessedPreviewUIView()
        view.attach(displayLayer)
        return view
    }

    func updateUIView(_ uiView: PiPProcessedPreviewUIView, context: Context) {
        uiView.attach(displayLayer)
        uiView.setNeedsLayout()
    }
}

final class PiPProcessedPreviewUIView: UIView {
    private weak var attachedLayer: AVSampleBufferDisplayLayer?

    override func layoutSubviews() {
        super.layoutSubviews()
        attachedLayer?.frame = bounds
    }

    func attach(_ layer: AVSampleBufferDisplayLayer) {
        guard attachedLayer !== layer else { return }
        attachedLayer?.removeFromSuperlayer()
        attachedLayer = layer
        layer.videoGravity = .resizeAspectFill
        layer.backgroundColor = UIColor.black.cgColor
        self.layer.addSublayer(layer)
        layer.frame = bounds
    }
}
