import AVFoundation
import SwiftUI
import UIKit

/// Inline-превью кадров PiP (тот же `AVSampleBufferDisplayLayer`, что и у контроллера).
struct PiPInlinePreview: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        view.layer.addSublayer(displayLayer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        displayLayer.frame = uiView.bounds
        if displayLayer.superlayer !== uiView.layer {
            displayLayer.removeFromSuperlayer()
            uiView.layer.addSublayer(displayLayer)
        }
    }
}
